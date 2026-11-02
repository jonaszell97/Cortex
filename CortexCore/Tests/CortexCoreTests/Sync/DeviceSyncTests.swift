import Foundation
import GRDB
import Synchronization
import Testing
@testable import CortexCore

/// The `device` collection (plans/IOS.md, M6): each device's report through
/// the engine, two databases against one fake server.
@Suite struct DeviceSyncTests {
    let server = InMemorySyncServer()
    let key = SyncKey.generate()

    static let stats = DeviceStats(
        platform: "macOS", osVersion: "26.1", appVersion: "0.1.0", appBuild: "1",
        builtAt: Date(timeIntervalSince1970: 1_792_000_000), bootedAt: Date(timeIntervalSince1970: 1_792_100_000),
        diskFree: 100_000_000_000, diskTotal: 500_000_000_000, battery: nil,
        hostName: "mac-mini.local", userName: "jonas")

    /// Refuses pushes that hold one of `refused` (as a server answers 422).
    final class RefusingTransport: SyncTransport, Sendable {
        let wrapped: DirectTransport
        let refused = Mutex<Set<String>>([])

        init(_ wrapped: DirectTransport) { self.wrapped = wrapped }

        func health() async throws -> SyncHealth { try await wrapped.health() }
        func changes(since cursor: Int64, limit: Int) async throws -> SyncChangesPage {
            try await wrapped.changes(since: cursor, limit: limit)
        }
        func push(device: String, records: [SyncWireRecord]) async throws -> SyncPushResponse {
            let refused = refused.withLock { $0 }
            if records.contains(where: { refused.contains($0.id) }) { throw SyncTransportError.server(status: 422) }
            return try await wrapped.push(device: device, records: records)
        }
        func missingBlobs(_ ids: [String]) async throws -> SyncMissingBlobs { try await wrapped.missingBlobs(ids) }
        func putBlob(id: String, data: Data) async throws -> SyncPutBlobResult { try await wrapped.putBlob(id: id, data: data) }
        func blob(id: String) async throws -> SyncBlobDownload? { try await wrapped.blob(id: id) }
    }

    struct Device {
        let database: AppDatabase
        let transport: RefusingTransport
        var name: String
        var stats: DeviceStats

        var id: String { get throws { try database.syncState().deviceID } }

        /// One cycle with the snippet handler and a device handler made for it.
        @discardableResult
        func cycle(
            _ mode: SyncMode = .full, key: SyncKey, now: Date = .now, asleepSince: Date? = nil,
            lastFailure: SyncDevice.Failure? = nil, reportsNow: Bool = false, reportsDevice: Bool = true
        ) async throws -> SyncCycleReport {
            let snippets = SnippetTestHandler()
            var handlers: [any SyncEntityHandler] = [snippets]
            if reportsDevice {
                let stats = stats
                handlers.append(DeviceSyncHandler(
                    database: database, name: name, collections: DeviceSyncHandler.collections(of: [snippets]),
                    lastFailure: lastFailure, asleepSince: asleepSince, reportsNow: reportsNow, now: { now },
                    stats: { stats }))
            }
            return try await SyncEngine(database: database, transport: transport, key: key, handlers: handlers)
                .runCycle(mode)
        }

        func devices() throws -> [SyncDevice] { try database.syncDevices() }
    }

    func device(_ name: String, stats: DeviceStats = DeviceSyncTests.stats) throws -> Device {
        Device(
            database: try makeTestDatabase(), transport: RefusingTransport(DirectTransport(server: server)),
            name: name, stats: stats)
    }

    func serverRecord(of device: Device) throws -> InMemorySyncServer.StoredRecord? {
        server.record("device", key.recordID(.device, localKey: try device.id))
    }

    @Test func theFirstCycleReportsAndTheOtherDeviceListsIt() async throws {
        let mini = try device("Mac mini"), phone = try device("iPhone")
        let now = Date.now
        try await mini.cycle(key: key, now: now)
        let report = try await phone.cycle(key: key)

        #expect(report.changedCollections == [.device])
        let devices = try phone.devices()
        #expect(devices.map(\.name) == ["iPhone", "Mac mini"], "this device first")
        #expect(devices[0].isThisDevice && !devices[1].isThisDevice)
        let received = devices[1]
        #expect(received.id == (try mini.id))
        #expect(received.platform == "macOS" && received.osVersion == "26.1" && received.appVersion == "0.1.0")
        #expect(received.collections == [.snippet: 1, .device: 1])
        #expect(received.reportedAt.syncMilliseconds == now.syncMilliseconds)
        #expect(received.bootedAt == Self.stats.bootedAt && received.diskFree == 100_000_000_000)
        #expect(received.hostName == "mac-mini.local" && received.userName == "jonas")
        #expect(received.activity(now: now.addingTimeInterval(60)) == .active)
        #expect(received.symbol == "desktopcomputer")
    }

    @Test func aReportGoesOutAgainOnlyAfterTheHeartbeatOrAChange() async throws {
        let mini = try device("Mac mini")
        let start = Date.now
        try await mini.cycle(key: key, now: start)
        let first = try #require(try serverRecord(of: mini))

        try await mini.cycle(key: key, now: start.addingTimeInterval(60))
        #expect(try serverRecord(of: mini)?.seq == first.seq, "nothing new within the heartbeat")

        try await mini.cycle(key: key, now: start.addingTimeInterval(DeviceSyncHandler.heartbeat + 1))
        let heartbeat = try #require(try serverRecord(of: mini))
        #expect(heartbeat.seq > first.seq)

        try await mini.cycle(.pushOnly, key: key, now: start.addingTimeInterval(DeviceSyncHandler.heartbeat + 60), reportsNow: true)
        let asked = try #require(try serverRecord(of: mini))
        #expect(asked.seq > heartbeat.seq, "going to the background reports at once")

        var renamed = mini
        renamed.name = "Studio"
        try await renamed.cycle(key: key, now: start.addingTimeInterval(DeviceSyncHandler.heartbeat + 2))
        #expect(try serverRecord(of: mini)?.seq ?? 0 > asked.seq, "a new name goes out at once")
    }

    @Test func theVolatileValuesDoNotCountAsAChange() async throws {
        var mini = try device("Mac mini")
        let start = Date.now
        try await mini.cycle(key: key, now: start)
        let first = try #require(try serverRecord(of: mini))

        mini.stats.diskFree = 1
        mini.stats.battery = SyncDevice.Battery(level: 3, isCharging: false)
        try await mini.cycle(key: key, now: start.addingTimeInterval(60))
        #expect(try serverRecord(of: mini)?.seq == first.seq)
    }

    @Test func aMacGoingToSleepSaysSoAndWakingClearsIt() async throws {
        let mini = try device("Mac mini"), phone = try device("iPhone")
        let start = Date.now
        try await mini.cycle(key: key, now: start)
        let asleep = start.addingTimeInterval(120)
        try await mini.cycle(.pushOnly, key: key, now: asleep, asleepSince: asleep)
        try await phone.cycle(key: key)

        let reported = try #require(try phone.devices().first { !$0.isThisDevice })
        #expect(reported.activity(now: asleep.addingTimeInterval(9 * 3600)) == .asleep(since: Date(syncMilliseconds: asleep.syncMilliseconds)))

        try await mini.cycle(key: key, now: asleep.addingTimeInterval(9 * 3600))
        try await phone.cycle(key: key)
        let woken = try #require(try phone.devices().first { !$0.isThisDevice })
        #expect(woken.asleepSince == nil)
    }

    @Test func aDeviceNotHeardFromIsLastSeen() async throws {
        let mini = try device("Mac mini"), phone = try device("iPhone")
        let start = Date.now
        try await mini.cycle(key: key, now: start)
        try await phone.cycle(key: key)
        let reported = try #require(try phone.devices().first { !$0.isThisDevice })
        #expect(reported.activity(now: start.addingTimeInterval(3 * 3600)) == .lastSeen(Date(syncMilliseconds: start.syncMilliseconds)))
    }

    @Test func unsentCountsOnlyWhatTheLastSuccessfulCycleLeft() async throws {
        let mini = try device("Mac mini"), phone = try device("iPhone")
        try await mini.cycle(key: key)
        // A change made since the last cycle is this cycle's work, not stuck.
        _ = try SnippetStore(database: mini.database).save(Snippet(name: "New", body: "x"))
        try await mini.cycle(key: key, now: .now.addingTimeInterval(DeviceSyncHandler.heartbeat + 1))
        try await phone.cycle(key: key)
        #expect(try phone.devices().first { !$0.isThisDevice }?.unsent == 0)

        // One the server refused stays pending: the next report counts it.
        _ = try SnippetStore(database: mini.database).save(Snippet(name: "Refused", body: "x"))
        let refusedID = try #require(try await mini.database.reader.read { db in
            try String.fetchOne(db, sql: "SELECT syncID FROM snippet WHERE name = 'Refused'")
        })
        mini.transport.refused.withLock { $0 = [key.recordID(.snippet, localKey: refusedID)] }
        try await mini.cycle(key: key, now: .now.addingTimeInterval(2 * DeviceSyncHandler.heartbeat + 2))
        try await mini.cycle(key: key, now: .now.addingTimeInterval(3 * DeviceSyncHandler.heartbeat + 3))
        try await phone.cycle(key: key)
        #expect(try phone.devices().first { !$0.isThisDevice }?.unsent == 1)
    }

    @Test func forgettingADeviceRemovesItEverywhereUntilItReportsAgain() async throws {
        let mini = try device("Mac mini"), phone = try device("iPhone"), laptop = try device("MacBook")
        try await mini.cycle(key: key)
        try await laptop.cycle(key: key)
        try await phone.cycle(key: key)
        #expect(try phone.devices().count == 3)

        try phone.database.forgetSyncDevice(try mini.id)
        #expect(try phone.devices().map(\.name) == ["iPhone", "MacBook"])
        try await phone.cycle(key: key)
        try await laptop.cycle(key: key)
        #expect(try laptop.devices().map(\.name) == ["MacBook", "iPhone"])

        // The Mac mini wasn't gone after all: it hears it was forgotten, and
        // its next cycle reports again.
        try await mini.cycle(key: key)
        #expect(try mini.devices().map(\.name) == ["iPhone", "MacBook"])
        try await mini.cycle(key: key)
        #expect(try mini.devices().first?.name == "Mac mini")
        try await laptop.cycle(key: key)
        #expect(try laptop.devices().map(\.name) == ["MacBook", "iPhone", "Mac mini"])
    }

    @Test func thisDeviceCantBeForgotten() async throws {
        let phone = try device("iPhone")
        try await phone.cycle(key: key)
        try phone.database.forgetSyncDevice(try phone.id)
        #expect(try phone.devices().map(\.name) == ["iPhone"])
    }

    @Test func aBuildWithoutTheDeviceHandlerPassesOverTheReports() async throws {
        let mini = try device("Mac mini"), older = try device("Older Mac")
        _ = try SnippetStore(database: mini.database).save(Snippet(name: "Greeting", body: "hello"))
        try await mini.cycle(key: key)
        try await older.cycle(key: key, reportsDevice: false)
        #expect(try older.devices().isEmpty)
        #expect(try await SnippetStore(database: older.database).all().map(\.name) == ["Greeting"])
        #expect(try older.database.syncState().cursor == Int64(server.records.map(\.seq).max() ?? 0), "the pull isn't held up")
    }

    @Test func pendingReportsAndForgetsAreNotLocalChanges() async throws {
        let phone = try device("iPhone")
        let counts = Mutex<[Int]>([])
        let observation = phone.database.observePendingSyncRecords { count in counts.withLock { $0.append(count) } }
        defer { observation.cancel() }
        try await phone.database.writer.write { db in
            try db.execute(sql: "INSERT INTO syncRecord (entity, localKey, modifiedAt, pending) VALUES ('device', 'x', 1, 1)")
        }
        try await Task.sleep(for: .milliseconds(100))
        #expect(counts.withLock { $0 }.allSatisfy { $0 == 0 })
    }

    @Test func anotherDevicesReportGoesOutAgainAsItArrived() async throws {
        let mini = try device("Mac mini"), phone = try device("iPhone")
        try await mini.cycle(key: key)
        try await phone.cycle(key: key)
        let handler = DeviceSyncHandler(database: phone.database, name: "iPhone", collections: [:], lastFailure: nil)
        let stored = try await phone.database.reader.read { db in try SyncDevices.storedData(of: try mini.id, db: db) }
        let outgoing = try await handler.outgoing(localKey: try mini.id, key: key, database: phone.database)
        #expect(outgoing?.payload == stored)
    }

    // MARK: Behind

    func reported(_ name: String, platform: String = "macOS", version: String = "0.1.0", build: String = "1",
                  collections: [String: Int] = ["knowledge": 1]) -> SyncDevice {
        SyncDevice(DevicePayload(
            v: 1, deviceID: name, name: name, platform: platform, osVersion: "26.1", appVersion: version,
            appBuild: build, collections: collections, reportedAt: 0, unsent: 0), isThisDevice: false)
    }

    @Test func aLowerVersionOnTheSamePlatformIsBehind() {
        let old = reported("Mini", version: "0.1.0"), new = reported("Book", version: "0.2.0")
        let phone = reported("iPhone", platform: "iOS", version: "0.3.0")
        let devices = [old, new, phone]
        #expect(old.isBehind(among: devices))
        #expect(!new.isBehind(among: devices), "an iPhone's version says nothing about a Mac's")
        #expect(!phone.isBehind(among: devices))
        #expect(reported("Mini", build: "9").isBehind(among: [reported("Book", build: "10")]), "builds compare as numbers")
    }

    @Test func aLowerPayloadVersionOfASyncedCollectionIsBehind() {
        let old = reported("Mini", collections: ["knowledge": 1, "clip": 1])
        let phone = reported("iPhone", platform: "iOS", collections: ["knowledge": 2])
        #expect(old.isBehind(among: [old, phone]))
        #expect(!reported("Mini", collections: ["clip": 1]).isBehind(among: [phone]), "a collection it doesn't sync")
    }
}

extension DeviceSyncTests {
    @Test func theLinesSayWhatADeviceIsDoing() {
        let now = Date(timeIntervalSince1970: 1_792_500_000)
        var mini = reported("Mac mini")
        mini.reportedAt = now.addingTimeInterval(-60)
        #expect(mini.activityLine(now: now) == "Syncing")
        mini.reportedAt = now.addingTimeInterval(-9 * 3600)
        #expect(mini.activityLine(now: now) == "Last synced 9 h ago")
        mini.asleepSince = now.addingTimeInterval(-3 * 86_400)
        #expect(mini.activityLine(now: now).hasPrefix("Asleep since "))
        mini.bootedAt = now.addingTimeInterval(-3 * 86_400)
        #expect(mini.uptimeLine(now: now) == "Up 3 d")
        #expect(mini.updateHint == "Update Cortex on this Mac")
        #expect(reported("iPhone", platform: "iOS").updateHint == "Update Cortex on this iPhone")
        mini.battery = SyncDevice.Battery(level: 80, isCharging: true)
        #expect(mini.batteryLine == "80 %, charging")
        #expect(mini.symbol == "laptopcomputer")
        #expect(mini.versionLine == "macOS 26.1 · Cortex 0.1.0 (1)")
    }
}
