import Foundation
import GRDB

/// This Mac's place in the sync, kept in the `metadata` table (docs/SYNC.md,
/// "Client schema") so it moves together with the data it describes: the cursor
/// advances in the same transaction as the page it was read with.
public struct SyncState: Sendable, Equatable {
    /// Random, created by the `v4_sync` migration. Marks this Mac's writes on
    /// the server.
    public var deviceID: String
    /// The last server `seq` applied here.
    public var cursor: Int64
    /// The server database the cursor belongs to (docs/SYNC.md, "The epoch").
    public var epoch: String?
    public var lastSuccess: Date?
    /// `SyncKey.keyCheckID` of the key once a pulled record opened with it.
    /// From then on a record that doesn't open is junk, not a wrong key, and
    /// is skipped after a few cycles (docs/SYNC.md, "Applying remote records").
    public var confirmedKey: String?
    /// Records that didn't open, by `SyncEngine.unopenedMark`, with the
    /// number of cycles each one stopped the pull.
    public var unopened: [String: Int] = [:]
    /// The collections that had a handler while the cursor advanced. Records
    /// of any other collection were passed over, so one that joins this set
    /// pulls from the beginning (`SyncEngine`). Nil: not recorded yet (a
    /// database from before this was kept), which counts as none.
    public var collections: Set<SyncCollection>?

    /// Milliseconds kept, so "Last synced" can't jump backwards.
    static let dateFormat = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    enum Key {
        static let deviceID = "syncDeviceID"
        static let cursor = "syncCursor"
        static let epoch = "syncEpoch"
        static let lastSuccess = "syncLastSuccess"
        static let confirmedKey = "syncConfirmedKey"
        static let unopened = "syncUnopened"
        static let collections = "syncCollections"
    }

    public static func read(_ db: Database) throws -> SyncState {
        let rows = try Row.fetchAll(db, sql: "SELECT key, value FROM metadata WHERE key LIKE 'sync%'")
        let values = Dictionary(rows.map { ($0["key"] as String, $0["value"] as String) },
                                uniquingKeysWith: { first, _ in first })
        guard let deviceID = values[Key.deviceID] else {
            throw DatabaseError(message: "metadata has no \(Key.deviceID); is the v4_sync migration missing?")
        }
        return SyncState(
            deviceID: deviceID,
            cursor: values[Key.cursor].flatMap { Int64($0) } ?? 0,
            epoch: values[Key.epoch],
            lastSuccess: values[Key.lastSuccess].flatMap { try? Date($0, strategy: dateFormat) },
            confirmedKey: values[Key.confirmedKey],
            unopened: values[Key.unopened]
                .flatMap { try? JSONDecoder().decode([String: Int].self, from: Data($0.utf8)) } ?? [:],
            collections: values[Key.collections].map {
                Set($0.split(separator: ",").compactMap { SyncCollection(rawValue: String($0)) })
            })
    }

    /// Writes every field. The device ID never changes after the migration,
    /// so it isn't written.
    public func write(_ db: Database) throws {
        try Self.set(Key.cursor, String(cursor), db: db)
        try Self.set(Key.epoch, epoch, db: db)
        try Self.set(Key.lastSuccess, lastSuccess?.formatted(Self.dateFormat), db: db)
        try Self.set(Key.confirmedKey, confirmedKey, db: db)
        let unopenedJSON = try unopened.isEmpty ? nil : String(decoding: JSONEncoder().encode(unopened), as: UTF8.self)
        try Self.set(Key.unopened, unopenedJSON, db: db)
        try Self.set(Key.collections, collections?.map(\.rawValue).sorted().joined(separator: ","), db: db)
    }

    private static func set(_ key: String, _ value: String?, db: Database) throws {
        if let value {
            try db.execute(sql: """
                INSERT INTO metadata (key, value) VALUES (?, ?)
                ON CONFLICT (key) DO UPDATE SET value = excluded.value
                """, arguments: [key, value])
        } else {
            try db.execute(sql: "DELETE FROM metadata WHERE key = ?", arguments: [key])
        }
    }
}

extension AppDatabase {
    public func syncState() throws -> SyncState {
        try reader.read(SyncState.read)
    }

    /// Reads, changes and writes the sync state in one transaction.
    @discardableResult
    public func updateSyncState(_ change: (inout SyncState) throws -> Void) throws -> SyncState {
        try writer.write { db in
            var state = try SyncState.read(db)
            try change(&state)
            try state.write(db)
            return state
        }
    }
}

/// A running database observation; cancelling stops the callbacks.
public final class SyncObservation: @unchecked Sendable {
    private var cancellable: AnyDatabaseCancellable?

    init(_ cancellable: AnyDatabaseCancellable) {
        self.cancellable = cancellable
    }

    public func cancel() {
        cancellable?.cancel()
        cancellable = nil
    }

    deinit { cancel() }
}

extension AppDatabase {
    /// Calls `onChange` with the number of rows waiting to be pushed, whenever
    /// that number changes (and once at the start). `SyncService` schedules a
    /// cycle when it's above 0 (docs/SYNC.md, "Scheduling"). Counting instead of
    /// watching the table means the engine's own bookkeeping (acknowledging rows,
    /// applying a page) doesn't wake it up again. This device's report
    /// (`device`) is marked pending inside a cycle and pushed by it, so it
    /// doesn't count.
    public func observePendingSyncRecords(onChange: @escaping @Sendable (Int) -> Void) -> SyncObservation {
        let observation = ValueObservation
            .tracking { db in
                try Int.fetchOne(db, sql: "SELECT count(*) FROM syncRecord WHERE pending = 1 AND entity <> 'device'") ?? 0
            }
            .removeDuplicates()
        let cancellable = observation.start(
            in: reader, scheduling: .async(onQueue: DispatchQueue(label: "dev.jonaszell.cortex.sync-observation")),
            onError: { error in Log.sync.error("Observing pending sync records failed: \(String(describing: error), privacy: .public)") },
            onChange: onChange)
        return SyncObservation(cancellable)
    }
}
