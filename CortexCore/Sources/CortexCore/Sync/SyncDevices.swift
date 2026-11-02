import Foundation
import GRDB
#if os(macOS)
import IOKit.ps
import SystemConfiguration
#endif

// The devices that sync (plans/IOS.md, M6): each one keeps one record in the
// `device` collection, keyed by its device ID, with what it is and how its
// sync is doing. Sealed like every record, so the server learns nothing new.
// Builds from before M6 pass over the collection.

/// A device's report, as it travels.
struct DevicePayload: Codable, Sendable, Equatable {
    static let version = 1

    struct Failure: Codable, Sendable, Equatable {
        var message: String
        var at: Int64
    }

    struct Battery: Codable, Sendable, Equatable {
        /// Percent.
        var level: Int
        var charging: Bool
    }

    var v: Int
    var deviceID: String
    var name: String
    /// `macOS` or `iOS`.
    var platform: String
    var osVersion: String
    var appVersion: String
    var appBuild: String
    /// The app executable's modification date: from-source builds all say
    /// the same version.
    var builtAt: Int64?
    /// The collections it syncs, with the payload version it understands.
    var collections: [String: Int]
    /// When it sent this, during a cycle that pushed: a moment it was syncing.
    var reportedAt: Int64
    /// Local changes the last successful cycle before this report didn't
    /// send: stuck ones, not the ones made since.
    var unsent: Int
    var lastFailure: Failure?
    /// A Mac that pushed before going to sleep.
    var asleepSince: Int64?
    // Macs only.
    var bootedAt: Int64?
    var diskFree: Int64?
    var diskTotal: Int64?
    var battery: Battery?
    /// The Bonjour name (`name.local`) and the user, for SSH (M7).
    var hostName: String?
    var userName: String?

    /// Without the values that change all the time: when this differs, the
    /// device reports at once instead of with the next heartbeat.
    var significant: DevicePayload {
        var copy = self
        copy.reportedAt = 0
        copy.unsent = 0
        copy.diskFree = nil
        copy.battery = nil
        return copy
    }
}

/// What a device knows about itself without the app: the system, the
/// build, and on Macs the uptime, disk and battery.
public struct DeviceStats: Sendable, Equatable {
    public var platform: String
    public var osVersion: String
    public var appVersion: String
    public var appBuild: String
    public var builtAt: Date?
    public var bootedAt: Date?
    public var diskFree: Int64?
    public var diskTotal: Int64?
    public var battery: SyncDevice.Battery?
    public var hostName: String?
    public var userName: String?

    public init(
        platform: String, osVersion: String, appVersion: String, appBuild: String, builtAt: Date? = nil,
        bootedAt: Date? = nil, diskFree: Int64? = nil, diskTotal: Int64? = nil, battery: SyncDevice.Battery? = nil,
        hostName: String? = nil, userName: String? = nil
    ) {
        self.platform = platform
        self.osVersion = osVersion
        self.appVersion = appVersion
        self.appBuild = appBuild
        self.builtAt = builtAt
        self.bootedAt = bootedAt
        self.diskFree = diskFree
        self.diskTotal = diskTotal
        self.battery = battery
        self.hostName = hostName
        self.userName = userName
    }

    /// This device, now.
    public static func current() -> DeviceStats {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let info = Bundle.main.infoDictionary ?? [:]
        let builtAt = (try? Bundle.main.executableURL?.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate
        var stats = DeviceStats(
            platform: platform,
            osVersion: "\(os.majorVersion).\(os.minorVersion)" + (os.patchVersion > 0 ? ".\(os.patchVersion)" : ""),
            appVersion: info["CFBundleShortVersionString"] as? String ?? "?",
            appBuild: info["CFBundleVersion"] as? String ?? "?",
            builtAt: builtAt)
        #if os(macOS)
        stats.bootedAt = bootDate()
        let volume = try? URL(filePath: NSHomeDirectory()).resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey])
        stats.diskFree = volume?.volumeAvailableCapacityForImportantUsage
        stats.diskTotal = volume?.volumeTotalCapacity.map(Int64.init)
        stats.battery = battery()
        stats.hostName = (SCDynamicStoreCopyLocalHostName(nil) as String?).map { "\($0).local" }
        stats.userName = NSUserName()
        #endif
        return stats
    }

    #if os(macOS)
    static let platform = "macOS"
    #else
    static let platform = "iOS"
    #endif

    #if os(macOS)
    /// The name in System Settings → General → About ("Jonas's Mac mini").
    public static func computerName() -> String {
        (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? Host.current().localizedName ?? "Mac"
    }

    /// From `kern.boottime`, which, unlike the uptime, doesn't stop while asleep.
    static func bootDate() -> Date? {
        var boot = timeval()
        var size = MemoryLayout<timeval>.size
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        guard sysctl(&mib, 2, &boot, &size, nil, 0) == 0, boot.tv_sec > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(boot.tv_sec))
    }

    /// The internal battery; nil on a Mac without one.
    static func battery() -> SyncDevice.Battery? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let maximum = description[kIOPSMaxCapacityKey] as? Int, maximum > 0
            else { continue }
            return SyncDevice.Battery(
                level: min(100, current * 100 / maximum), isCharging: description[kIOPSIsChargingKey] as? Bool ?? false)
        }
        return nil
    }
    #endif
}

/// A device that syncs, as its last report says.
public struct SyncDevice: Sendable, Equatable, Identifiable {
    public struct Failure: Sendable, Equatable {
        public var message: String
        public var at: Date

        public init(message: String, at: Date) {
            self.message = message
            self.at = at
        }
    }

    public struct Battery: Sendable, Equatable {
        public var level: Int
        public var isCharging: Bool

        public init(level: Int, isCharging: Bool) {
            self.level = level
            self.isCharging = isCharging
        }
    }

    public enum Activity: Sendable, Equatable {
        /// Reported within the heartbeat (and a cycle's wait).
        case active
        case asleep(since: Date)
        case lastSeen(Date)
    }

    /// The device ID (`SyncState.deviceID`).
    public var id: String
    public var name: String
    public var platform: String
    public var osVersion: String
    public var appVersion: String
    public var appBuild: String
    public var builtAt: Date?
    public var collections: [SyncCollection: Int]
    public var reportedAt: Date
    /// Changes it had not managed to send when it reported.
    public var unsent: Int
    public var lastFailure: Failure?
    public var asleepSince: Date?
    public var bootedAt: Date?
    public var diskFree: Int64?
    public var diskTotal: Int64?
    public var battery: Battery?
    public var hostName: String?
    public var userName: String?
    public var isThisDevice: Bool

    init(_ payload: DevicePayload, isThisDevice: Bool) {
        id = payload.deviceID
        name = payload.name
        platform = payload.platform
        osVersion = payload.osVersion
        appVersion = payload.appVersion
        appBuild = payload.appBuild
        builtAt = payload.builtAt.map(Date.init(syncMilliseconds:))
        collections = Dictionary(
            payload.collections.compactMap { name, version in SyncCollection(rawValue: name).map { ($0, version) } },
            uniquingKeysWith: max)
        reportedAt = Date(syncMilliseconds: payload.reportedAt)
        unsent = payload.unsent
        lastFailure = payload.lastFailure.map { Failure(message: $0.message, at: Date(syncMilliseconds: $0.at)) }
        asleepSince = payload.asleepSince.map(Date.init(syncMilliseconds:))
        bootedAt = payload.bootedAt.map(Date.init(syncMilliseconds:))
        diskFree = payload.diskFree
        diskTotal = payload.diskTotal
        battery = payload.battery.map { Battery(level: $0.level, isCharging: $0.charging) }
        hostName = payload.hostName
        userName = payload.userName
        self.isThisDevice = isThisDevice
    }

    public var isMac: Bool { platform == "macOS" }

    /// A report within this long means the device is syncing: the
    /// heartbeat, plus a periodic cycle's wait and some slack.
    public static let activeWindow: TimeInterval = DeviceSyncHandler.heartbeat + 5 * 60

    public func activity(now: Date = .now) -> Activity {
        if let asleepSince { return .asleep(since: asleepSince) }
        return now.timeIntervalSince(reportedAt) < Self.activeWindow ? .active : .lastSeen(reportedAt)
    }

    /// Whether another device runs a newer Cortex: it understands a higher
    /// payload version of a collection this one syncs (so this one will stop
    /// at the first such record), or it has a higher version and build on the
    /// same platform.
    public func isBehind(among devices: [SyncDevice]) -> Bool {
        devices.contains { other in
            guard other.id != id else { return false }
            if collections.contains(where: { collection, version in (other.collections[collection] ?? 0) > version }) {
                return true
            }
            return other.platform == platform
                && "\(other.appVersion).\(other.appBuild)".compare("\(appVersion).\(appBuild)", options: .numeric)
                    == .orderedDescending
        }
    }

    /// An SF Symbol: a laptop has a battery.
    public var symbol: String {
        if !isMac { return platform == "iOS" ? "iphone" : "display" }
        return battery == nil ? "desktopcomputer" : "laptopcomputer"
    }
}

/// This device's report and the other devices' ones, for the engine. Made
/// for one cycle, with the app's values as they are then.
public struct DeviceSyncHandler: SyncEntityHandler {
    /// A report goes out at least this often while a device syncs, and at
    /// once when something besides the unsent count, disk and battery
    /// changed.
    public static let heartbeat: TimeInterval = 15 * 60

    public var entity: SyncCollection { .device }
    public var supportedVersion: Int { DevicePayload.version }

    private let database: AppDatabase
    private let name: String
    private let collections: [SyncCollection: Int]
    private let lastFailure: SyncDevice.Failure?
    private let asleepSince: Date?
    private let reportsNow: Bool
    private let now: @Sendable () -> Date
    private let stats: @Sendable () -> DeviceStats

    /// - Parameters:
    ///   - collections: The other handlers of the cycle, by their collection
    ///     and supported payload version.
    ///   - lastFailure: The last cycle that failed on this device.
    ///   - asleepSince: Set for the push before a Mac sleeps.
    ///   - reportsNow: Report even if nothing changed and the heartbeat
    ///     isn't due: the iPhone going to the background, so its last report
    ///     is when it was last used rather than up to a heartbeat earlier.
    public init(
        database: AppDatabase, name: String, collections: [SyncCollection: Int], lastFailure: SyncDevice.Failure?,
        asleepSince: Date? = nil, reportsNow: Bool = false, now: @escaping @Sendable () -> Date = { .now },
        stats: @escaping @Sendable () -> DeviceStats = { .current() }
    ) {
        self.database = database
        self.name = name
        var collections = collections
        collections[.device] = DevicePayload.version
        self.collections = collections
        self.lastFailure = lastFailure
        self.asleepSince = asleepSince
        self.reportsNow = reportsNow
        self.now = now
        self.stats = stats
    }

    /// The handlers of a cycle, by collection and supported version.
    public static func collections(of handlers: [any SyncEntityHandler]) -> [SyncCollection: Int] {
        Dictionary(handlers.map { ($0.entity, $0.supportedVersion) }, uniquingKeysWith: max)
    }

    /// Marks this device's report pending when it is due: the first time,
    /// after a significant change, after the heartbeat, or after another
    /// device forgot this one, or when asked to (`reportsNow`).
    public func beforeCycle(database: AppDatabase) async throws {
        let now = now()
        let stats = stats()
        try await self.database.writer.write { [self] db in
            let deviceID = try SyncState.read(db).deviceID
            let current = try report(deviceID: deviceID, stats: stats, now: now, db: db)
            let stored = try SyncDevices.payload(of: deviceID, db: db)
            let isDue = stored.map {
                reportsNow
                    || $0.significant != current.significant
                    || now.timeIntervalSince(Date(syncMilliseconds: $0.reportedAt)) >= Self.heartbeat
            } ?? true
            guard isDue else { return }
            try SyncDevices.store(try JSONEncoder().encode(current), of: deviceID, db: db)
            try db.execute(sql: """
                INSERT INTO syncRecord (entity, localKey, modifiedAt, pending, deleted)
                VALUES ('device', ?, \(SyncSchema.nowMs), 1, 0)
                \(SyncSchema.markLocalWrite(deleted: false))
                """, arguments: [deviceID])
        }
    }

    /// This device's report with the values of the moment it is pushed
    /// (`reportedAt` is then a moment it was syncing);
    /// another device's one as it arrived (an epoch reset sends every record
    /// again).
    public func outgoing(localKey: String, key: SyncKey, database: AppDatabase) async throws -> SyncOutgoing? {
        let now = now()
        let stats = stats()
        return try await self.database.writer.write { [self] db -> SyncOutgoing? in
            let deviceID = try SyncState.read(db).deviceID
            guard localKey == deviceID else {
                return try SyncDevices.storedData(of: localKey, db: db).map { SyncOutgoing(payload: $0) }
            }
            let payload = try JSONEncoder().encode(try report(deviceID: deviceID, stats: stats, now: now, db: db))
            try SyncDevices.store(payload, of: deviceID, db: db)
            return SyncOutgoing(payload: payload)
        }
    }

    public func prepare(payload: Data, blobs: SyncBlobSource) async throws -> SyncPreparedRecord {
        let decoded = try JSONDecoder().decode(DevicePayload.self, from: payload)
        guard !decoded.deviceID.isEmpty else { throw SyncDevices.Error.malformed("no device ID") }
        return SyncPreparedRecord(localKey: decoded.deviceID) { db, _ in
            // As it arrived, so the fields a later build adds go out unchanged.
            try SyncDevices.store(payload, of: decoded.deviceID, db: db)
            return .applied
        }
    }

    public func applyDeletion(localKey: String, in db: Database) throws {
        try db.execute(sql: "DELETE FROM syncDevice WHERE deviceID = ?", arguments: [localKey])
    }

    private func report(deviceID: String, stats: DeviceStats, now: Date, db: Database) throws -> DevicePayload {
        // Written before the last successful cycle ended and still pending:
        // that cycle couldn't send them. Newer changes are this cycle's work.
        let unsent = try SyncState.read(db).lastSuccess.map { lastSuccess in
            try Int.fetchOne(db, sql: """
                SELECT count(*) FROM syncRecord
                WHERE pending = 1 AND entity NOT IN ('device', 'meta') AND modifiedAt < ?
                """, arguments: [lastSuccess.syncMilliseconds]) ?? 0
        } ?? 0
        return DevicePayload(
            v: DevicePayload.version, deviceID: deviceID, name: name, platform: stats.platform,
            osVersion: stats.osVersion, appVersion: stats.appVersion, appBuild: stats.appBuild,
            builtAt: stats.builtAt?.syncMilliseconds,
            collections: Dictionary(uniqueKeysWithValues: collections.map { ($0.key.rawValue, $0.value) }),
            reportedAt: now.syncMilliseconds, unsent: unsent,
            lastFailure: lastFailure.map { DevicePayload.Failure(message: $0.message, at: $0.at.syncMilliseconds) },
            asleepSince: asleepSince?.syncMilliseconds, bootedAt: stats.bootedAt?.syncMilliseconds,
            diskFree: stats.diskFree, diskTotal: stats.diskTotal,
            battery: stats.battery.map { DevicePayload.Battery(level: $0.level, charging: $0.isCharging) },
            hostName: stats.hostName, userName: stats.userName)
    }
}

/// The `syncDevice` table: the last report of each device, this one included.
enum SyncDevices {
    enum Error: Swift.Error, CustomStringConvertible {
        case malformed(String)

        var description: String {
            switch self {
            case .malformed(let reason): "malformed device payload: \(reason)"
            }
        }
    }

    /// No triggers: the handler marks this device's row pending itself.
    static func migrate(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE syncDevice (
              deviceID  TEXT PRIMARY KEY NOT NULL,  -- also the sync key
              payload   BLOB NOT NULL               -- DevicePayload JSON, as received
            );
            """)
    }

    static func storedData(of deviceID: String, db: Database) throws -> Data? {
        try Data.fetchOne(db, sql: "SELECT payload FROM syncDevice WHERE deviceID = ?", arguments: [deviceID])
    }

    static func payload(of deviceID: String, db: Database) throws -> DevicePayload? {
        try storedData(of: deviceID, db: db).flatMap { try? JSONDecoder().decode(DevicePayload.self, from: $0) }
    }

    static func store(_ payload: Data, of deviceID: String, db: Database) throws {
        try db.execute(sql: """
            INSERT INTO syncDevice (deviceID, payload) VALUES (?, ?)
            ON CONFLICT (deviceID) DO UPDATE SET payload = excluded.payload
            """, arguments: [deviceID, payload])
    }

    /// This device first, then by name.
    static func all(_ db: Database) throws -> [SyncDevice] {
        let deviceID = try SyncState.read(db).deviceID
        let rows = try Row.fetchAll(db, sql: "SELECT deviceID, payload FROM syncDevice")
        let devices = rows.compactMap { row -> SyncDevice? in
            guard let payload = try? JSONDecoder().decode(DevicePayload.self, from: row["payload"] as Data) else {
                return nil
            }
            return SyncDevice(payload, isThisDevice: (row["deviceID"] as String) == deviceID)
        }
        return devices.sorted {
            $0.isThisDevice != $1.isThisDevice
                ? $0.isThisDevice
                : $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}

extension AppDatabase {
    /// Every device's last report, this one first (once it has reported).
    public func syncDevices() throws -> [SyncDevice] {
        try reader.read(SyncDevices.all)
    }

    /// Calls `onChange` with the devices whenever a report arrives or
    /// changes (and once at the start).
    public func observeSyncDevices(onChange: @escaping @Sendable ([SyncDevice]) -> Void) -> SyncObservation {
        let observation = ValueObservation.tracking(SyncDevices.all).removeDuplicates()
        let cancellable = observation.start(
            in: reader, scheduling: .async(onQueue: .main),
            onError: { error in Log.sync.error("Observing the devices failed: \(String(describing: error), privacy: .public)") },
            onChange: onChange)
        return SyncObservation(cancellable)
    }

    /// "Forget": removes a device that is gone, on every device. If it
    /// syncs again, its next report brings it back. This device can't be
    /// forgotten.
    public func forgetSyncDevice(_ deviceID: String) throws {
        try writer.write { db in
            guard try SyncState.read(db).deviceID != deviceID else { return }
            try db.execute(sql: "DELETE FROM syncDevice WHERE deviceID = ?", arguments: [deviceID])
            try db.execute(sql: """
                INSERT INTO syncRecord (entity, localKey, modifiedAt, pending, deleted)
                VALUES ('device', ?, \(SyncSchema.nowMs), 1, 1)
                \(SyncSchema.markLocalWrite(deleted: true))
                """, arguments: [deviceID])
        }
    }
}

// MARK: - Text

extension SyncDevice {
    /// "Syncing", "Asleep since 18:02", "Last synced 9 h ago".
    public func activityLine(now: Date = .now) -> String {
        switch activity(now: now) {
        case .active: "Syncing"
        case .asleep(let since): "Asleep since \(Self.time(since, now: now))"
        case .lastSeen(let date): "Last synced \(SyncStatus.age(since: date, now: now))"
        }
    }

    /// "macOS 26.1 · Cortex 0.1.0 (1), built 26 Oct".
    public var versionLine: String {
        var line = "\(platform) \(osVersion) · Cortex \(appVersion) (\(appBuild))"
        if let builtAt { line += ", built \(builtAt.formatted(.dateTime.day().month()))" }
        return line
    }

    /// What to do about a device that is behind.
    public var updateHint: String {
        "Update Cortex on this \(isMac ? "Mac" : platform == "iOS" ? "iPhone" : "device")"
    }

    /// "Up 3 d", from the boot date.
    public func uptimeLine(now: Date = .now) -> String? {
        bootedAt.map { "Up \(SyncStatus.age(since: $0, now: now).replacing(" ago", with: ""))" }
    }

    /// "120 GB of 494 GB free".
    public var diskLine: String? {
        guard let diskFree else { return nil }
        let free = diskFree.formatted(.byteCount(style: .file))
        return diskTotal.map { "\(free) of \($0.formatted(.byteCount(style: .file))) free" } ?? "\(free) free"
    }

    /// "80 %, charging".
    public var batteryLine: String? {
        battery.map { "\($0.level) %" + ($0.isCharging ? ", charging" : "") }
    }

    private static func time(_ date: Date, now: Date) -> String {
        Calendar.current.isDate(date, inSameDayAs: now)
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }
}
