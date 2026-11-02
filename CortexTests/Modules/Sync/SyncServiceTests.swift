import AppKit
import Foundation
import Testing
@testable import Cortex
import CortexCore

/// A small in-memory sync server for the service tests: stores records by
/// (collection, id), hands them out by sequence number, and can be switched
/// off. The protocol itself is tested against the real thing in CortexCore.
final class StubSyncServer: SyncTransport, @unchecked Sendable {
    enum Mode { case ok, unreachable, unauthorized }

    private let lock = NSLock()
    private var _mode = Mode.ok
    private var records: [String: SyncWireRecord] = [:]
    private var nextSeq: Int64 = 1
    private var blobs: [String: Data] = [:]
    let epoch = "stub-epoch"

    var mode: Mode {
        get { lock.withLock { _mode } }
        set { lock.withLock { _mode = newValue } }
    }

    var recordCount: Int { lock.withLock { records.count } }

    private func check() throws {
        switch mode {
        case .ok: break
        case .unreachable: throw SyncTransportError.unreachable
        case .unauthorized: throw SyncTransportError.unauthorized
        }
    }

    func health() async throws -> SyncHealth {
        if mode == .unreachable { throw SyncTransportError.unreachable }
        return SyncHealth(status: "ok", epoch: epoch)
    }

    func changes(since cursor: Int64, limit: Int) async throws -> SyncChangesPage {
        try check()
        return lock.withLock {
            let all = records.values.filter { ($0.seq ?? 0) > cursor }.sorted { ($0.seq ?? 0) < ($1.seq ?? 0) }
            let page = Array(all.prefix(limit))
            return SyncChangesPage(records: page, cursor: page.last?.seq ?? cursor, more: all.count > page.count, epoch: epoch)
        }
    }

    func push(device: String, records incoming: [SyncWireRecord]) async throws -> SyncPushResponse {
        try check()
        return lock.withLock {
            var results: [SyncPushResult] = []
            for var record in incoming {
                let key = record.collection + "/" + record.id
                if let stored = records[key],
                   (stored.modifiedAt, stored.device) > (record.modifiedAt, record.device) {
                    results.append(SyncPushResult(collection: record.collection, id: record.id, status: .stale, seq: stored.seq ?? 0))
                    continue
                }
                record.seq = nextSeq
                nextSeq += 1
                records[key] = record
                results.append(SyncPushResult(collection: record.collection, id: record.id, status: .applied, seq: record.seq ?? 0))
            }
            return SyncPushResponse(results: results, epoch: epoch)
        }
    }

    func missingBlobs(_ ids: [String]) async throws -> SyncMissingBlobs {
        try check()
        return lock.withLock { SyncMissingBlobs(missing: ids.filter { blobs[$0] == nil }, epoch: epoch) }
    }

    func putBlob(id: String, data: Data) async throws -> SyncPutBlobResult {
        try check()
        return lock.withLock {
            let isNew = blobs[id] == nil
            blobs[id] = data
            return SyncPutBlobResult(stored: isNew, epoch: epoch)
        }
    }

    func blob(id: String) async throws -> SyncBlobDownload? {
        try check()
        return lock.withLock { blobs[id].map { SyncBlobDownload(data: $0, epoch: epoch) } }
    }
}

func textSnapshot(_ text: String) -> ClipSnapshot {
    ClipSnapshot(
        representations: [LoadedRepresentation(type: ClipType.plainText, data: Data(text.utf8))],
        plainText: text, isSensitive: false, sourceBundleID: "test.TextEdit", sourceAppName: "TextEdit")
}

final class MemorySecrets: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]

    func data(for account: String) throws -> Data? { lock.withLock { items[account] } }
    func set(_ data: Data, for account: String) throws { lock.withLock { items[account] = data } }
    func delete(_ account: String) throws { lock.withLock { items[account] = nil } }
    var accounts: Set<String> { lock.withLock { Set(items.keys) } }
}

/// Counts calls from closures the test hands out, by what called.
@MainActor
final class Tally {
    private(set) var count = 0
    private(set) var collections: [SyncCollection] = []
    func add(_ collection: SyncCollection? = nil) {
        count += 1
        if let collection { collections.append(collection) }
    }
}

/// One Mac: a database, the services on top of it, and a sync service wired
/// to a stub server, carrying what the modules contribute.
@MainActor
struct SyncMac {
    let database: AppDatabase
    let clipboard: ClipboardService
    let snippets: SnippetsService
    let actions: ActionsService
    let settings: SyncSettings
    let secrets = MemorySecrets()
    let sync: SyncService
    private let suiteName = "CortexTests-\(UUID().uuidString)"

    /// - Parameters:
    ///   - collections: Those of switched-on modules.
    ///   - remoteChanges: Counts the contributions told about remote changes.
    ///   - reportsDevice: Whether cycles carry this Mac's report, which
    ///     the tests that count records leave out.
    init(
        server: StubSyncServer, collections: Set<SyncCollection> = [.clip, .snippet, .action],
        remoteChanges: Tally? = nil, reportsDevice: Bool = false
    ) throws {
        let defaults = UserDefaults(suiteName: suiteName)!
        database = try makeTestDatabase()
        clipboard = ClipboardService(database: database, settings: ClipboardSettings(defaults: defaults))
        snippets = SnippetsService(database: database, settings: SnippetsSettings(defaults: defaults))
        let folder = FileManager.default.temporaryDirectory.appending(path: "CortexTests-actions-\(UUID().uuidString)", directoryHint: .isDirectory)
        actions = ActionsService(directory: folder, defaults: defaults)
        settings = SyncSettings(defaults: defaults)
        let contributions = [
            ClipboardModule.syncContribution(for: clipboard),
            SnippetsModule.syncContribution(for: snippets),
            ActionsModule.syncContribution(for: actions),
        ]
        .filter { collections.contains($0.collection) }
        .map { contribution in
            var counted = contribution
            counted.didApplyRemoteChanges = {
                contribution.didApplyRemoteChanges()
                remoteChanges?.add(contribution.collection)
            }
            return counted
        }
        sync = SyncService(
            database: database, settings: settings, secrets: secrets, contributions: { contributions },
            usesTriggers: false, reportsDevice: reportsDevice, makeTransport: { _, _ in server })
        // The Sync module is on.
        sync.start()
    }

    /// Removes the test's UserDefaults domain.
    func tearDown() {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
    }

    func snippetNames() async -> [String] {
        await snippets.all().map(\.name)
    }

    func clipTexts() async throws -> [String] {
        try await clipboard.store.summaries().map(\.preview)
    }
}

@MainActor
@Suite struct SyncServiceTests {
    let server = StubSyncServer()
    let url = "https://cortex-sync.example.dev"
    let token = "0123456789abcdef0123456789abcdef"

    @Test func changesToHiddenFilesOfAWatchedFolderAskForNoCycle() {
        let folder = URL(filePath: "/Users/me/.config/cortex/knowledge", directoryHint: .isDirectory)
        #expect(SyncService.isHidden("/Users/me/.config/cortex/knowledge/.git/index", in: folder))
        #expect(SyncService.isHidden("/Users/me/.config/cortex/knowledge/.conflicts/p/a.md", in: folder))
        #expect(SyncService.isHidden("/Users/me/.config/cortex/knowledge/p/.DS_Store", in: folder))
        #expect(!SyncService.isHidden("/Users/me/.config/cortex/knowledge/p/notes/a.md", in: folder))
        // The folder's own path has dots above it; only what is below counts.
        #expect(!SyncService.isHidden("/Users/me/.config/cortex/knowledge", in: folder))
        #expect(!SyncService.isHidden("/elsewhere/.git", in: folder))
    }

    @Test func aMacThatIsNotSetUpDoesNothing() async throws {
        let mac = try SyncMac(server: server)
        #expect(!mac.sync.isConfigured && !mac.sync.isActive)
        #expect(mac.sync.status == .off)
        mac.sync.syncNow()
        await mac.sync.runCycle()
        #expect(server.recordCount == 0)
        #expect(mac.sync.status == .off)
        #expect(!mac.sync.copyPairingCode(to: NSPasteboard.withUniqueName()))
        #expect(mac.sync.pairingQRCode() == nil)
    }

    @Test func settingUpTheFirstMacStoresTheKeysAndUploadsEverything() async throws {
        let a = try SyncMac(server: server)
        defer { a.tearDown() }
        try a.snippets.store.save(Snippet(name: "Greeting", body: "hello"))
        try a.clipboard.store.record(textSnapshot("a clip"), indexSensitive: false)

        try await a.sync.setUp(serverURL: url, token: " \(token)\n")
        await a.sync.waitUntilIdle()

        #expect(a.sync.isConfigured && a.sync.isActive)
        #expect(a.settings.serverURL?.absoluteString == url)
        #expect(a.secrets.accounts == [SyncKey.keychainAccount, SyncKey.tokenKeychainAccount])
        let storedToken = try #require(try a.secrets.data(for: SyncKey.tokenKeychainAccount))
        #expect(String(data: storedToken, encoding: .utf8) == token)
        guard case .synced(_, let sent, _) = a.sync.status else {
            Issue.record("expected a finished sync, got \(a.sync.status)")
            return
        }
        // The clip, the snippet and the key check.
        #expect(sent == 3 && server.recordCount == 3)
        #expect(a.sync.lastSuccess != nil)
        #expect(a.sync.status.menuLine(lastSuccess: a.sync.lastSuccess)?.hasPrefix("Synced") == true)
        #expect(a.sync.pairingQRCode() != nil)
    }

    @Test func theSecondMacJoinsWithThePairingCodeAndThingsMerge() async throws {
        let a = try SyncMac(server: server), b = try SyncMac(server: server)
        defer { a.tearDown(); b.tearDown() }
        try a.snippets.store.save(Snippet(name: "From A", body: "a"))
        try a.clipboard.store.record(textSnapshot("clip from A"), indexSensitive: false)
        try b.snippets.store.save(Snippet(name: "From B", body: "b"))
        try await a.sync.setUp(serverURL: url, token: token)
        await a.sync.waitUntilIdle()

        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        #expect(a.sync.copyPairingCode(to: pasteboard))
        let code = try #require(pasteboard.string(forType: .string))
        #expect(code.hasPrefix("cxsync1:"))
        // Cortex records the code as a sensitive clip and masks it.
        #expect(pasteboard.types?.contains(Paster.concealedType) == true)

        try await b.sync.join(pairingCode: code)
        await b.sync.waitUntilIdle()
        #expect(b.sync.isConfigured && b.sync.isActive)
        #expect(await b.snippetNames().sorted() == ["From A", "From B"])
        #expect(try await b.clipTexts() == ["clip from A"])

        await a.sync.runCycle()
        #expect(await a.snippetNames().sorted() == ["From A", "From B"])
    }

    @Test func remoteChangesAreAnnounced() async throws {
        let announced = Tally()
        let a = try SyncMac(server: server), b = try SyncMac(server: server, remoteChanges: announced)
        defer { a.tearDown(); b.tearDown() }
        try a.snippets.store.save(Snippet(name: "Hello", body: "x"))
        try await a.sync.setUp(serverURL: url, token: token)
        await a.sync.waitUntilIdle()
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        a.sync.copyPairingCode(to: pasteboard)

        let code = try #require(pasteboard.string(forType: .string))
        try await b.sync.join(pairingCode: code)
        await b.sync.waitUntilIdle()
        // Only the contribution whose records arrived, once per cycle that wrote some.
        #expect(announced.count >= 1 && Set(announced.collections) == [.snippet])
    }

    @Test func eachMacReportsItselfAndListsTheOthers() async throws {
        let announced = Tally()
        let a = try SyncMac(server: server, reportsDevice: true)
        let b = try SyncMac(server: server, remoteChanges: announced, reportsDevice: true)
        defer { a.tearDown(); b.tearDown() }
        try await a.sync.setUp(serverURL: url, token: token)
        await a.sync.waitUntilIdle()
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        a.sync.copyPairingCode(to: pasteboard)
        try await b.sync.join(pairingCode: try #require(pasteboard.string(forType: .string)))
        await b.sync.waitUntilIdle()
        await a.sync.runCycle()
        try await Task.sleep(for: .milliseconds(100))

        let name = DeviceStats.computerName()
        #expect(a.sync.devices.count == 2 && b.sync.devices.count == 2)
        #expect(a.sync.devices.first?.isThisDevice == true && a.sync.devices.allSatisfy { $0.name == name })
        #expect(b.sync.devices.contains { !$0.isThisDevice && $0.collections[.snippet] == 1 })
        #expect(announced.count == 0, "a report reloads no module")

        let other = try #require(a.sync.devices.first { !$0.isThisDevice })
        a.sync.forgetDevice(other)
        try await Task.sleep(for: .milliseconds(100))
        #expect(a.sync.devices.map(\.isThisDevice) == [true])
    }

    @Test func aWrongKeyOrAnEmptyServerFailsAtSetup() async throws {
        let a = try SyncMac(server: server), b = try SyncMac(server: server)
        defer { a.tearDown(); b.tearDown() }
        let stranger = SyncPairing(serverURL: try SyncSetup.parseServerURL(url), token: token, key: .generate())

        // Nothing set up on the server yet.
        await #expect(throws: SyncSetupError.serverIsEmpty) { try await b.sync.join(pairingCode: stranger.code) }
        #expect(!b.sync.isConfigured && b.secrets.accounts.isEmpty && !b.sync.isActive)

        try await a.sync.setUp(serverURL: url, token: token)
        await a.sync.waitUntilIdle()

        // A key that doesn't open the server's key check.
        await #expect(throws: SyncEngineError.keyMismatch) { try await b.sync.join(pairingCode: stranger.code) }
        #expect(!b.sync.isConfigured && b.secrets.accounts.isEmpty && !b.sync.isActive)
        // Setting up a second "first Mac" would orphan what is on the server.
        await #expect(throws: SyncSetupError.serverHoldsOtherData) { try await b.sync.setUp(serverURL: url, token: token) }
        #expect(!b.sync.isConfigured)

        await #expect(throws: SyncKeyError.malformedPairingCode) { try await b.sync.join(pairingCode: "hello") }
    }

    @Test func aRejectedTokenFailsAtSetupWithThePlainWords() async throws {
        let a = try SyncMac(server: server)
        defer { a.tearDown() }
        server.mode = .unauthorized
        await #expect(throws: SyncEngineError.unauthorized) { try await a.sync.setUp(serverURL: url, token: token) }
        #expect(!a.sync.isConfigured)
        server.mode = .ok
        let tested = await a.sync.testConnection(serverURL: url, token: token)
        #expect(tested == .success("Connected"))
        server.mode = .unauthorized
        let rejected = await a.sync.testConnection(serverURL: url, token: token)
        #expect(rejected == .failure(SyncTestError(message: "The sync server rejected the token.")))
        let empty = await a.sync.testConnection(serverURL: url, token: "  ")
        #expect(empty == .failure(SyncTestError(message: SyncSetupError.missingToken.errorDescription!)))
    }

    @Test func aServerThatIsDownChangesNothingAndTheStatusSaysSo() async throws {
        let a = try SyncMac(server: server)
        defer { a.tearDown() }
        try await a.sync.setUp(serverURL: url, token: token)
        await a.sync.waitUntilIdle()
        try a.snippets.store.save(Snippet(name: "Offline edit", body: "x"))
        let before = try a.database.syncState()

        server.mode = .unreachable
        await a.sync.runCycle()

        #expect(a.sync.status == .failed(.unreachable))
        #expect(a.sync.status.menuLine(lastSuccess: a.sync.lastSuccess) == "Sync paused: server unreachable")
        // Local data is untouched, and the edit waits to be sent.
        #expect(await a.snippetNames() == ["Offline edit"])
        #expect(try a.database.syncState().cursor == before.cursor)
        let pending = try await a.database.reader.read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM syncRecord WHERE pending = 1") ?? 0
        }
        #expect(pending == 1)

        // The retry is scheduled by the backoff. Coming back works without ceremony.
        server.mode = .ok
        a.sync.syncNow()
        await a.sync.waitUntilIdle()
        guard case .synced = a.sync.status else {
            Issue.record("expected a finished sync, got \(a.sync.status)")
            return
        }
    }

    @Test func disconnectingForgetsTheServerButKeepsTheData() async throws {
        let a = try SyncMac(server: server)
        defer { a.tearDown() }
        try a.snippets.store.save(Snippet(name: "Keep me", body: "x"))
        try await a.sync.setUp(serverURL: url, token: token)
        await a.sync.waitUntilIdle()
        #expect(try a.database.syncState().epoch != nil)

        a.sync.disconnect()

        #expect(!a.sync.isConfigured && !a.sync.isActive && a.sync.status == .off)
        #expect(a.secrets.accounts.isEmpty)
        #expect(a.settings.serverURL == nil && !a.sync.isActive && a.sync.isRunning)
        #expect(await a.snippetNames() == ["Keep me"])
        let state = try a.database.syncState()
        #expect(state.cursor == 0 && state.epoch == nil)
        #expect(a.sync.status.menuLine(lastSuccess: a.sync.lastSuccess) == nil)
        let records = server.recordCount
        await a.sync.runCycle()
        #expect(server.recordCount == records)
    }

    @Test func uploadEverythingAgainSendsEveryRecordOnce() async throws {
        let a = try SyncMac(server: server)
        defer { a.tearDown() }
        try a.snippets.store.save(Snippet(name: "One", body: "1"))
        try await a.sync.setUp(serverURL: url, token: token)
        await a.sync.waitUntilIdle()

        a.sync.uploadEverythingAgain()
        await a.sync.waitUntilIdle()
        guard case .synced(_, let sent, _) = a.sync.status else {
            Issue.record("expected a finished sync, got \(a.sync.status)")
            return
        }
        #expect(sent == 2)   // the snippet and the key check
    }

    @Test func switchingSyncOffStopsTheCycles() async throws {
        let a = try SyncMac(server: server)
        defer { a.tearDown() }
        try await a.sync.setUp(serverURL: url, token: token)
        await a.sync.waitUntilIdle()
        a.sync.stop()
        try a.snippets.store.save(Snippet(name: "Not sent", body: "x"))
        let records = server.recordCount
        await a.sync.runCycle()
        #expect(server.recordCount == records)
        #expect(!a.sync.isActive && a.sync.status == .off)

        // On again, it picks up where it left off.
        a.sync.start()
        #expect(a.sync.isActive)
        await a.sync.runCycle()
        #expect(server.recordCount == records + 1)
    }

    @Test func leavesTheRecordsOfSwitchedOffModulesAlone() async throws {
        let a = try SyncMac(server: server, collections: [.clip, .action])
        defer { a.tearDown() }
        try a.snippets.store.save(Snippet(name: "Stays here", body: "x"))
        try a.clipboard.store.record(textSnapshot("a clip"), indexSensitive: false)
        try await a.sync.setUp(serverURL: url, token: token)
        await a.sync.waitUntilIdle()
        // The clip and the key check.
        #expect(server.recordCount == 2)
    }

    @Test func leavesSwitchedOffCollectionsAlone() async throws {
        let a = try SyncMac(server: server)
        defer { a.tearDown() }
        a.settings.setSyncing("syncClips", false)
        try a.snippets.store.save(Snippet(name: "Goes", body: "x"))
        try a.clipboard.store.record(textSnapshot("stays here"), indexSensitive: false)
        try await a.sync.setUp(serverURL: url, token: token)
        await a.sync.waitUntilIdle()
        // The snippet and the key check.
        #expect(server.recordCount == 2)
    }
}
