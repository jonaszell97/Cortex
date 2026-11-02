import Foundation
import GRDB

/// Why a cycle ended early. Each case has the plain-words status of docs/SYNC.md,
/// "The UI and status messages".
public enum SyncEngineError: Error, Equatable, CustomStringConvertible, LocalizedError {
    case unreachable
    case unauthorized
    /// A record doesn't open with this Mac's sync key.
    case keyMismatch
    /// A record has a payload version this build doesn't know.
    case updateRequired
    case server(status: Int)
    case badResponse
    /// The server's epoch changed again and again within one cycle.
    case unstableServer

    init(_ error: SyncTransportError) {
        switch error {
        case .unreachable: self = .unreachable
        case .unauthorized: self = .unauthorized
        case .payloadTooLarge: self = .server(status: 413)
        case .server(let status): self = .server(status: status)
        case .malformedResponse, .responseTooLarge: self = .badResponse
        }
    }

    public var description: String {
        switch self {
        case .unreachable: "Server unreachable — is Tailscale connected?"
        case .unauthorized: "Token rejected"
        case .keyMismatch: "Sync key doesn't match"
        case .updateRequired: "Update Cortex on this Mac"
        case .server(507): "The sync server's storage is full"
        case .server(let status): "The sync server answered \(status)"
        case .badResponse: "The sync server sent an unexpected answer"
        case .unstableServer: "The sync server keeps changing its identity"
        }
    }

    public var errorDescription: String? { description }
}

public enum SyncMode: Sendable {
    /// Pull, then push.
    case full
    /// Push only: before sleep, with a few seconds of budget (docs/SYNC.md,
    /// "Scheduling").
    case pushOnly
}

public struct SyncCycleReport: Sendable, Equatable {
    /// Records received from the server.
    public var pulled = 0
    /// Records written to the local data.
    public var applied = 0
    /// The collections of those records, so the apps reload only what
    /// changed (every device's report arrives now and then, plans/IOS.md M6).
    public var changedCollections: Set<SyncCollection> = []
    /// Remote records that couldn't be applied and were skipped.
    public var skipped = 0
    /// Records the server took.
    public var sent = 0
    /// Pushed records the server already had a newer write of.
    public var stale = 0
    /// The server's epoch changed: this Mac uploads everything again.
    public var epochReset = false

    public init() {}
}

public enum SyncKeyVerification: Sendable, Equatable {
    case matches
    /// The server holds a key check that this key doesn't open.
    case mismatch
    /// The server has no key check yet: nothing has been set up on it.
    case notFound
}

/// One sync cycle at a time: health, epoch check, pull, apply, push
/// (docs/SYNC.md, "The sync cycle"). It never touches the main actor and holds no
/// state beyond the current cycle; the cursor, epoch and `pending` flags live in
/// the database, in the same transactions as the data they describe.
public actor SyncEngine {
    static let pageSize = 200
    static let pushBatchSize = 50
    /// A push batch stops growing at this many bytes of payloads and blobs
    /// (the server caps a push body at 32 MB).
    static let pushBatchBytes = 8 * 1024 * 1024
    static let maxEpochRestarts = 3
    /// A remote `modifiedAt` further ahead of this Mac's clock is refused.
    static let maxClockLead: Int64 = 24 * 60 * 60 * 1000
    /// Cycles a record that doesn't open stops the pull before it is skipped,
    /// once the key is confirmed (docs/SYNC.md, "Applying remote records").
    static let maxUnopenedCycles = 3

    private let database: AppDatabase
    private let transport: any SyncTransport
    private let key: SyncKey
    private let handlers: [SyncCollection: any SyncEntityHandler]
    private let onRemoteChanges: (@Sendable (SyncCycleReport) -> Void)?

    private var running: Task<SyncCycleReport, Error>?

    // The current cycle.
    private var report = SyncCycleReport()
    private var epoch = ""
    private var deviceID = ""
    /// Rows the push gave up on in this cycle, so a record that can't be built
    /// doesn't make the loop spin. They stay pending for the next cycle.
    private var gaveUp = Set<RowKey>()
    /// Whether a pulled record has opened with this key, in this cycle or
    /// before (`SyncState.confirmedKey`).
    private var keyConfirmed = false

    /// `onRemoteChanges` runs after a cycle that wrote remote data, also when
    /// the cycle then failed: the app refreshes the palette and the keyword table.
    public init(
        database: AppDatabase,
        transport: any SyncTransport,
        key: SyncKey,
        handlers: [any SyncEntityHandler],
        onRemoteChanges: (@Sendable (SyncCycleReport) -> Void)? = nil
    ) {
        self.database = database
        self.transport = transport
        self.key = key
        self.handlers = Dictionary(handlers.map { ($0.entity, $0) }, uniquingKeysWith: { _, last in last })
        self.onRemoteChanges = onRemoteChanges
    }

    private struct RowKey: Hashable {
        var entity: String
        var localKey: String
    }

    private struct PendingRow {
        var entity: SyncCollection
        var localKey: String
        var modifiedAt: Int64
        var deleted: Bool
        var device: String?
    }

    /// Thrown inside a cycle after an epoch change was handled: start over.
    private struct EpochChanged: Error {}

    // MARK: - Running a cycle

    /// Runs a cycle, after the one in flight if there is one. Cancelling the
    /// caller cancels the cycle; nothing is lost, because the cursor and the
    /// `pending` flags only change together with the data.
    @discardableResult
    public func runCycle(_ mode: SyncMode = .full) async throws -> SyncCycleReport {
        let previous = running
        let task = Task {
            _ = try? await previous?.value
            return try await self.performCycle(mode)
        }
        running = task
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func performCycle(_ mode: SyncMode) async throws -> SyncCycleReport {
        report = SyncCycleReport()
        defer {
            if report.applied > 0 {
                onRemoteChanges?(report)
            }
        }
        for attempt in 0...Self.maxEpochRestarts {
            do {
                try await cycleBody(mode)
                break
            } catch is EpochChanged {
                report.epochReset = true
                if attempt == Self.maxEpochRestarts { throw SyncEngineError.unstableServer }
            }
        }
        return report
    }

    private func cycleBody(_ mode: SyncMode) async throws {
        gaveUp = []
        let health = try await call { try await self.transport.health() }

        // The epoch check. A first cycle just remembers the epoch: the
        // migration marked everything pending already.
        let state = try database.syncState()
        deviceID = state.deviceID
        keyConfirmed = state.confirmedKey == key.keyCheckID
        epoch = health.epoch
        if state.epoch != health.epoch {
            if state.epoch == nil {
                try await database.updateSyncState { $0.epoch = health.epoch }
            } else {
                try await resetForNewEpoch(health.epoch)
                report.epochReset = true
            }
        }

        try await coverCollections()

        for handler in handlers.values {
            try Task.checkCancellation()
            do {
                try await handler.beforeCycle(database: database)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                Log.sync.error("beforeCycle failed for \(handler.entity.rawValue, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }

        if mode == .full {
            try await pull()
        }
        let sawStale = try await push()
        // A stale answer means the server holds a newer write: fetch it now
        // instead of waiting for the next cycle.
        if mode == .full && sawStale {
            try await pull()
        }

        try await database.updateSyncState { $0.lastSuccess = .now }
        Log.sync.info("""
            sync cycle: pulled=\(self.report.pulled) applied=\(self.report.applied) skipped=\(self.report.skipped) \
            sent=\(self.report.sent) stale=\(self.report.stale)
            """)
    }

    // MARK: - Epoch

    /// Throws `EpochChanged` after resetting, if a response comes from a
    /// different server database than the cycle began with. Any response can
    /// say so: the server rotates its epoch itself when a client's cursor is
    /// ahead of it (docs/SYNC.md, "The epoch").
    private func checkEpoch(_ responseEpoch: String) async throws {
        guard responseEpoch != epoch else { return }
        epoch = responseEpoch
        try await resetForNewEpoch(responseEpoch)
        throw EpochChanged()
    }

    /// The cursor goes back to 0 and every record is uploaded again,
    /// tombstones included: a Mac that still holds a deleted clip must not
    /// bring it back. The key check goes first, so whichever Mac reconnects
    /// to the new server publishes it.
    private func resetForNewEpoch(_ newEpoch: String) async throws {
        Log.sync.notice("The sync server's epoch changed; uploading everything again")
        try await database.writer.write { db in
            var state = try SyncState.read(db)
            state.cursor = 0
            state.epoch = newEpoch
            state.unopened = [:]
            try state.write(db)
            try db.execute(sql: "UPDATE syncRecord SET pending = 1")
            try Self.markKeyCheckPending(db)
        }
    }

    // MARK: - Collections

    /// The cursor only speaks for the collections that had a handler while
    /// it advanced: the pull passes over records of the others (an older
    /// build that didn't know them, a module or switch that was off). When a
    /// collection joins, the cursor goes back to 0 so its records are pulled
    /// after all; what is already here loses to itself under last-writer-wins.
    /// A collection that leaves drops out, so it pulls again when it returns.
    private func coverCollections() async throws {
        let active = Set(handlers.keys)
        try await database.writer.write { db in
            var state = try SyncState.read(db)
            guard state.collections != active else { return }
            let joined = active.subtracting(state.collections ?? [])
            if !joined.isEmpty, state.cursor > 0 {
                let names = joined.map(\.rawValue).sorted().joined(separator: ", ")
                Log.sync.notice("Pulling everything again for newly synced collections: \(names, privacy: .public)")
                state.cursor = 0
            }
            state.collections = active
            try state.write(db)
        }
    }

    // MARK: - Transport

    private func call<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
        do {
            return try await operation()
        } catch let error as SyncTransportError {
            throw SyncEngineError(error)
        }
    }

    // MARK: - Pull

    private func pull() async throws {
        var since = try database.syncState().cursor
        while true {
            try Task.checkCancellation()
            let current = since
            let page = try await call { try await self.transport.changes(since: current, limit: Self.pageSize) }
            try await checkEpoch(page.epoch)
            report.pulled += page.records.count
            try await apply(page, since: since)
            if !page.more { return }
            guard page.cursor > since else { throw SyncEngineError.badResponse }
            since = page.cursor
        }
    }

    private struct Incoming {
        var record: SyncWireRecord
        var collection: SyncCollection
        var handler: any SyncEntityHandler
        /// Nil: a tombstone for a record this Mac never had.
        var localKey: String?
        /// Nil for a tombstone.
        var prepared: SyncPreparedRecord?
    }

    /// One page: decrypt and prepare every record outside the transaction
    /// (blobs are downloaded here), then write all of it, and the cursor, in
    /// one short transaction. A crash can only replay a page, never skip one.
    ///
    /// Every record, tombstones included, must open with its metadata as AAD
    /// before last-writer-wins looks at that metadata (docs/SYNC.md, "Sealing and
    /// authenticated metadata").
    private func apply(_ page: SyncChangesPage, since: Int64) async throws {
        let blobs = SyncBlobSource { [self] id in try await self.fetchBlob(id) }
        var incoming: [Incoming] = []
        var tombstoneKeys: [SyncCollection: [String: String]] = [:]
        // Records that didn't open and are skipped: their counts go with the page.
        var passedUnopened: [String] = []

        for record in page.records {
            try Task.checkCancellation()
            guard let collection = record.syncCollection else {
                Log.sync.notice("Skipping a record of an unknown collection")
                continue
            }
            if collection == .meta {
                if key.opensKeyCheck(record) {
                    keyConfirmed = true
                } else {
                    try passUnopened(record, &passedUnopened)
                }
                continue
            }
            guard let handler = handlers[collection] else { continue }
            guard Self.isAcceptable(modifiedAt: record.modifiedAt, now: Date.now.syncMilliseconds) else {
                skip(record, "modifiedAt \(record.modifiedAt) is out of range")
                continue
            }

            let plaintext: Data
            switch open(record, collection: collection) {
            case .opened(let opened):
                plaintext = opened
            case .v1:
                // Its metadata, tombstone flag included, could have been
                // changed by anyone with the token. The Mac that wrote it
                // uploads it again as v2 once it is updated.
                skip(record, "sealed by protocol v1, so its metadata isn't authenticated")
                continue
            case .unopened:
                try passUnopened(record, &passedUnopened)
                continue
            }

            if record.deleted {
                guard SyncKey.isTombstone(plaintext) else {
                    skip(record, "a tombstone whose payload isn't one")
                    continue
                }
                if tombstoneKeys[collection] == nil {
                    tombstoneKeys[collection] = try localKeysByRecordID(collection)
                }
                incoming.append(Incoming(
                    record: record, collection: collection, handler: handler,
                    localKey: tombstoneKeys[collection]?[record.id], prepared: nil))
                continue
            }

            guard let version = Self.payloadVersion(plaintext) else {
                skip(record, "no payload version")
                continue
            }
            if version > handler.supportedVersion { throw SyncEngineError.updateRequired }
            do {
                let prepared = try await handler.prepare(payload: plaintext, blobs: blobs)
                guard key.recordID(collection, localKey: prepared.localKey) == record.id else {
                    skip(record, "the payload doesn't belong to this record")
                    continue
                }
                incoming.append(Incoming(
                    record: record, collection: collection, handler: handler,
                    localKey: prepared.localKey, prepared: prepared))
            } catch is CancellationError {
                throw CancellationError()
            } catch SyncEngineError.keyMismatch {
                // One of its blobs doesn't open.
                try passUnopened(record, &passedUnopened)
            } catch let error as SyncEngineError {
                throw error
            } catch {
                skip(record, String(describing: error))
            }
        }

        let deviceID = deviceID
        let cursor = page.cursor
        let batch = incoming
        let confirmedKey = keyConfirmed ? key.keyCheckID : nil
        let passed = passedUnopened
        let (applied, changed, failed) = try await database.writer.write { db -> (Int, Set<SyncCollection>, [String]) in
            var applied = 0
            var changed = Set<SyncCollection>()
            var failed: [String] = []
            for item in batch {
                do {
                    // A savepoint, so a record that fails undoes only itself.
                    try db.inSavepoint {
                        if try Self.write(item, deviceID: deviceID, db: db) {
                            applied += 1
                            changed.insert(item.collection)
                        }
                        return .commit
                    }
                } catch {
                    failed.append(String(describing: error))
                }
            }
            var state = try SyncState.read(db)
            let before = state
            state.cursor = cursor
            if let confirmedKey { state.confirmedKey = confirmedKey }
            for mark in passed { state.unopened[mark] = nil }
            if state != before { try state.write(db) }
            return (applied, changed, failed)
        }
        report.applied += applied
        report.changedCollections.formUnion(changed)
        report.skipped += failed.count
        for reason in failed {
            Log.sync.error("Could not apply a remote record: \(reason, privacy: .public)")
        }
    }

    /// Writes one record if the remote write is newer than the local one:
    /// `(modifiedAt, device)` is compared like the server does (docs/SYNC.md,
    /// "Applying remote records"). Afterwards the row is `(remote modifiedAt,
    /// pending = 0)`, which also cancels the `pending = 1` the data write's
    /// triggers left, so an applied change never echoes back to the server.
    private static func write(_ item: Incoming, deviceID: String, db: Database) throws -> Bool {
        // A tombstone for a record this Mac never had: nothing to delete.
        guard let localKey = item.localKey else { return false }
        let record = item.record
        let remote = SyncRemoteWrite(modifiedAt: record.modifiedAt, device: record.device)

        let local = try Row.fetchOne(
            db, sql: "SELECT modifiedAt, device FROM syncRecord WHERE entity = ? AND localKey = ?",
            arguments: [item.collection, localKey])
        if let local {
            let localWrite = (try local.decode(Int64.self, forColumn: "modifiedAt"), (local["device"] as String?) ?? deviceID)
            guard isNewer((record.modifiedAt, record.device), than: localWrite) else {
                item.prepared?.superseded?(db, remote)
                return false
            }
        }

        var outcome = SyncApplyOutcome.applied
        if let prepared = item.prepared {
            outcome = try prepared.apply(db, remote)
            if outcome == .ignored { return false }
        } else {
            try item.handler.applyDeletion(localKey: localKey, in: db)
        }
        if outcome == .mergedLocally {
            // A new local write that follows the remote one, to be pushed.
            try db.execute(sql: """
                INSERT INTO syncRecord (entity, localKey, modifiedAt, pending, deleted, synced)
                VALUES (?, ?, \(SyncSchema.capped("max(\(SyncSchema.nowMs), ? + 1)")), 1, 0, 1)
                ON CONFLICT (entity, localKey) DO UPDATE SET
                  modifiedAt = excluded.modifiedAt, pending = 1, deleted = 0, device = NULL, synced = 1
                """, arguments: [item.collection, localKey, record.modifiedAt])
            return true
        }
        try db.execute(sql: """
            INSERT INTO syncRecord (entity, localKey, modifiedAt, pending, deleted, device, synced)
            VALUES (?, ?, ?, 0, ?, ?, 1)
            ON CONFLICT (entity, localKey) DO UPDATE SET
              modifiedAt = excluded.modifiedAt, pending = 0, deleted = excluded.deleted, device = excluded.device,
              synced = 1
            """, arguments: [
                item.collection, localKey, record.modifiedAt, record.deleted,
                record.device == deviceID ? nil : record.device,
            ])
        return true
    }

    /// Whether a remote `modifiedAt` can be stored: within the range the
    /// server takes, and at most a day ahead of this Mac's clock. Anything
    /// else would win every comparison from then on (docs/SYNC.md, "Sealing and
    /// authenticated metadata").
    static func isAcceptable(modifiedAt: Int64, now: Int64) -> Bool {
        modifiedAt >= 0 && modifiedAt <= min(SyncSchema.maxModifiedAt, now + maxClockLead)
    }

    /// The server's tie-break: a later `modifiedAt` wins, then the greater device ID.
    static func isNewer(_ a: (Int64, String), than b: (Int64, String)) -> Bool {
        a.0 != b.0 ? a.0 > b.0 : b.1.utf8.lexicographicallyPrecedes(a.1.utf8)
    }

    /// Record ID to local key, for the tombstones of a page (their payload is
    /// null, so the key can only come from the local rows).
    private func localKeysByRecordID(_ collection: SyncCollection) throws -> [String: String] {
        let keys = try database.reader.read { db in
            try String.fetchAll(db, sql: "SELECT localKey FROM syncRecord WHERE entity = ?", arguments: [collection])
        }
        return Dictionary(keys.map { (key.recordID(collection, localKey: $0), $0) }, uniquingKeysWith: { first, _ in first })
    }

    private struct VersionProbe: Decodable {
        var v: Int?
    }

    private static func payloadVersion(_ plaintext: Data) -> Int? {
        (try? JSONDecoder().decode(VersionProbe.self, from: plaintext))?.v
    }

    private func skip(_ record: SyncWireRecord, _ reason: String) {
        report.skipped += 1
        Log.sync.error("Skipping record \(record.id, privacy: .public): \(reason, privacy: .public)")
    }

    private enum Opened {
        case opened(Data)
        /// Sealed by protocol v1, or a v1 tombstone without a payload.
        case v1
        case unopened
    }

    /// Opens a record's payload with its metadata as AAD. Any record that
    /// opens, v1 or v2, confirms the key.
    private func open(_ record: SyncWireRecord, collection: SyncCollection) -> Opened {
        guard let sealed = record.payload else { return .v1 }
        if let plaintext = try? key.open(sealed, for: SyncRecordHeader(record, collection: collection)) {
            keyConfirmed = true
            return .opened(plaintext)
        }
        if (try? key.openV1(sealed, collection: collection, id: record.id)) != nil {
            keyConfirmed = true
            return .v1
        }
        return .unopened
    }

    /// What identifies a record that doesn't open in `SyncState.unopened`: a
    /// new write of the record starts its count again.
    static func unopenedMark(_ record: SyncWireRecord) -> String {
        "\(record.collection)/\(record.id)/\(record.modifiedAt)/\(record.device)"
    }

    /// A record that doesn't open (or whose blob doesn't): a wrong key, or
    /// junk pushed by someone who holds only the token. Until a record has
    /// opened with this key, it is a wrong key, and the pull stops with the
    /// cursor where it is; a stuck cursor beats silently skipping data. Once
    /// the key is confirmed, the record still stops the pull for
    /// `maxUnopenedCycles` cycles and is then skipped, so junk can't hold
    /// the cursor for good (docs/SYNC.md, "Applying remote records").
    private func passUnopened(_ record: SyncWireRecord, _ passed: inout [String]) throws {
        let mark = Self.unopenedMark(record)
        let confirmedKey = keyConfirmed ? key.keyCheckID : nil
        let cycles = try database.writer.write { db in
            var state = try SyncState.read(db)
            if let confirmedKey { state.confirmedKey = confirmedKey }
            let cycles = (state.unopened[mark] ?? 0) + 1
            state.unopened[mark] = cycles
            try state.write(db)
            return cycles
        }
        guard keyConfirmed, cycles >= Self.maxUnopenedCycles else { throw SyncEngineError.keyMismatch }
        skip(record, "it doesn't open with the sync key (\(cycles) cycles)")
        passed.append(mark)
        if record.syncCollection == .meta && record.id == key.keyCheckID {
            // Junk in place of the key check: put this Mac's back, so a Mac
            // that joins later can check its key.
            try database.writer.write(Self.markKeyCheckPending)
        }
    }

    private func fetchBlob(_ id: String) async throws -> Data {
        let found: SyncBlobDownload?
        do {
            found = try await transport.blob(id: id)
        } catch SyncTransportError.responseTooLarge {
            throw SyncBlobError.tooLarge(id)
        } catch let error as SyncTransportError {
            throw SyncEngineError(error)
        }
        guard let download = found else { throw SyncBlobError.missing(id) }
        try await checkEpoch(download.epoch)
        do {
            return try key.openBlob(download.data, id: id)
        } catch {
            throw SyncEngineError.keyMismatch
        }
    }

    // MARK: - Push

    /// Pushes pending rows in batches until none is left. Returns whether the
    /// server held a newer write of any record.
    private func push() async throws -> Bool {
        var sawStale = false
        var batchLimit = Self.pushBatchSize
        while true {
            try Task.checkCancellation()
            let rows = try pendingRows(limit: batchLimit)
            if rows.isEmpty { return sawStale }

            var batch = try await buildBatch(rows)
            try acknowledge(batch.filtered, sent: false)
            if batch.records.isEmpty { continue }

            // A record whose blob the server refused is left for later.
            let refusedBlobs = try await upload(batch.blobs)
            if !refusedBlobs.isEmpty {
                for item in batch.records where !refusedBlobs.isDisjoint(with: item.wire.blobs) {
                    Log.sync.error("Record \(item.row.localKey.prefix(8), privacy: .public) has a blob too large to push")
                    gaveUp.insert(RowKey(entity: item.row.entity.rawValue, localKey: item.row.localKey))
                }
                batch.records.removeAll { !refusedBlobs.isDisjoint(with: $0.wire.blobs) }
                if batch.records.isEmpty { continue }
            }

            let response: SyncPushResponse
            do {
                response = try await transport.push(device: deviceID, records: batch.records.map(\.wire))
            } catch let error as SyncTransportError where error == .payloadTooLarge || error == .server(status: 422) {
                // Halve the batch to find the record the server refuses, as too
                // large or as invalid; a single such record is left for later.
                if batch.records.count == 1 {
                    let row = batch.records[0].row
                    Log.sync.error("""
                        Record \(row.localKey.prefix(8), privacy: .public) was refused: \(error.description, privacy: .public)
                        """)
                    gaveUp.insert(RowKey(entity: row.entity.rawValue, localKey: row.localKey))
                }
                batchLimit = max(1, batch.records.count / 2)
                continue
            } catch let error as SyncTransportError {
                throw SyncEngineError(error)
            }
            try await checkEpoch(response.epoch)

            var results: [String: SyncPushResult] = [:]
            for result in response.results {
                results[result.collection + "/" + result.id] = result
            }
            var acknowledged: [PendingRow] = []
            for item in batch.records {
                guard let result = results[item.wire.collection + "/" + item.wire.id] else {
                    gaveUp.insert(RowKey(entity: item.row.entity.rawValue, localKey: item.row.localKey))
                    continue
                }
                acknowledged.append(item.row)
                switch result.status {
                case .applied: report.sent += 1
                case .stale:
                    report.stale += 1
                    sawStale = true
                }
            }
            try acknowledge(acknowledged, sent: true)
        }
    }

    private struct BuiltRecord {
        var row: PendingRow
        var wire: SyncWireRecord
    }

    private struct Batch {
        var records: [BuiltRecord] = []
        /// Rows the filters exclude: acknowledged without a push.
        var filtered: [PendingRow] = []
        /// Plaintext of the blobs the records refer to, by blob ID.
        var blobs: [String: Data] = [:]
    }

    /// Entities with a handler, plus the key check.
    private var pushableEntities: [String] {
        (handlers.keys.map(\.rawValue) + [SyncCollection.meta.rawValue]).sorted()
    }

    /// Pending rows, the key check first, then oldest first.
    private func pendingRows(limit: Int) throws -> [PendingRow] {
        let entities = pushableEntities.map { "'\($0)'" }.joined(separator: ", ")
        let rows = try database.reader.read { [gaveUp] db in
            try Row.fetchAll(db, sql: """
                SELECT entity, localKey, modifiedAt, deleted, device FROM syncRecord
                WHERE pending = 1 AND entity IN (\(entities))
                ORDER BY entity = 'meta' DESC, modifiedAt, entity, localKey
                LIMIT ?
                """, arguments: [limit + gaveUp.count])
        }
        var pending: [PendingRow] = []
        for row in rows {
            let entity: String = row["entity"]
            let localKey: String = row["localKey"]
            let rowKey = RowKey(entity: entity, localKey: localKey)
            guard !gaveUp.contains(rowKey), let collection = SyncCollection(rawValue: entity) else { continue }
            do {
                pending.append(PendingRow(
                    entity: collection, localKey: localKey, modifiedAt: try row.decode(Int64.self, forColumn: "modifiedAt"),
                    deleted: row["deleted"], device: row["device"]))
            } catch {
                Log.sync.error("Skipping record \(localKey.prefix(8), privacy: .public): \(String(describing: error), privacy: .public)")
                gaveUp.insert(rowKey)
            }
        }
        return Array(pending.prefix(limit))
    }

    private func buildBatch(_ rows: [PendingRow]) async throws -> Batch {
        var batch = Batch()
        var bytes = 0
        for row in rows {
            try Task.checkCancellation()
            if bytes >= Self.pushBatchBytes && !batch.records.isEmpty { break }

            let id = key.recordID(row.entity, localKey: row.localKey)
            let device = row.device ?? deviceID
            let header = SyncRecordHeader(
                collection: row.entity, id: id, modifiedAt: row.modifiedAt, device: device, deleted: row.deleted)
            if row.deleted {
                // Sealed too, so only a Mac with the key can delete.
                let sealed = try key.seal(SyncKey.tombstoneContents, for: header)
                bytes += sealed.count
                batch.records.append(BuiltRecord(row: row, wire: SyncWireRecord(
                    collection: row.entity, id: id, modifiedAt: row.modifiedAt, device: device,
                    deleted: true, payload: sealed)))
                continue
            }

            let outgoing: SyncOutgoing?
            if row.entity == .meta {
                outgoing = SyncOutgoing(payload: Data())
            } else {
                guard let handler = handlers[row.entity] else { continue }
                do {
                    outgoing = try await handler.outgoing(localKey: row.localKey, key: key, database: database)
                } catch is CancellationError {
                    throw CancellationError()
                } catch let error as SyncEngineError {
                    throw error
                } catch {
                    Log.sync.error("Could not build record \(id, privacy: .public): \(String(describing: error), privacy: .public)")
                    gaveUp.insert(RowKey(entity: row.entity.rawValue, localKey: row.localKey))
                    continue
                }
            }
            guard let outgoing else {
                batch.filtered.append(row)
                continue
            }

            let sealed = row.entity == .meta
                ? try key.sealedKeyCheck(modifiedAt: row.modifiedAt, device: device)
                : try key.seal(outgoing.payload, for: header)
            for blob in outgoing.blobs {
                batch.blobs[blob.id] = blob.plaintext
                bytes += blob.plaintext.count
            }
            bytes += sealed.count
            batch.records.append(BuiltRecord(row: row, wire: SyncWireRecord(
                collection: row.entity, id: id, modifiedAt: row.modifiedAt, device: device,
                deleted: false, keep: outgoing.keep, blobs: outgoing.blobs.map(\.id), payload: sealed)))
        }
        return batch
    }

    /// Uploads the blobs the server lacks. They go before the records that
    /// refer to them, so a record never points at a blob that isn't there.
    /// Returns the IDs of the blobs the server refused as too large.
    private func upload(_ blobs: [String: Data]) async throws -> Set<String> {
        guard !blobs.isEmpty else { return [] }
        let ids = blobs.keys.sorted()
        let missing = try await call { try await self.transport.missingBlobs(ids) }
        try await checkEpoch(missing.epoch)
        var refused = Set<String>()
        for id in missing.missing {
            guard let plaintext = blobs[id] else { continue }
            try Task.checkCancellation()
            let sealed = try key.sealBlob(plaintext, id: id)
            let result: SyncPutBlobResult
            do {
                result = try await transport.putBlob(id: id, data: sealed)
            } catch SyncTransportError.payloadTooLarge {
                refused.insert(id)
                continue
            } catch let error as SyncTransportError {
                throw SyncEngineError(error)
            }
            try await checkEpoch(result.epoch)
        }
        return refused
    }

    /// Clears `pending` only for the exact `modifiedAt` that was pushed: an
    /// edit made during the push stays pending and goes out next time.
    /// - Parameter sent: Whether the server took them (and `synced` is set), as
    ///   opposed to rows the filters keep local.
    private func acknowledge(_ rows: [PendingRow], sent: Bool) throws {
        guard !rows.isEmpty else { return }
        try database.writer.write { db in
            for row in rows {
                try db.execute(
                    sql: """
                        UPDATE syncRecord SET pending = 0, synced = max(synced, ?)
                        WHERE entity = ? AND localKey = ? AND modifiedAt = ?
                        """,
                    arguments: [sent, row.entity, row.localKey, row.modifiedAt])
            }
        }
    }

    // MARK: - Key check

    /// Queues the key check for upload. Setting sync up on the first Mac calls
    /// this; an epoch reset does it by itself.
    public func publishKeyCheck() throws {
        try database.writer.write(Self.markKeyCheckPending)
    }

    private static func markKeyCheckPending(_ db: Database) throws {
        try db.execute(sql: """
            INSERT INTO syncRecord (entity, localKey, modifiedAt, pending, deleted)
            VALUES ('meta', ?, \(SyncSchema.nowMs), 1, 0)
            \(SyncSchema.markLocalWrite(deleted: false))
            """, arguments: [SyncKey.keyCheckLocalKey])
    }

    /// Joining from the second Mac: looks for the key check on the server and
    /// tries this key on it, before anything is pulled or applied. Changes no
    /// local state.
    public func verifyKey() async throws -> SyncKeyVerification {
        var since: Int64 = 0
        while true {
            let current = since
            let page = try await call { try await self.transport.changes(since: current, limit: 1000) }
            if let record = page.records.first(where: { $0.syncCollection == .meta }) {
                return key.opensKeyCheck(record) ? .matches : .mismatch
            }
            guard page.more, page.cursor > since else { return .notFound }
            since = page.cursor
        }
    }
}

extension AppDatabase {
    /// "Upload Everything Again", and enabling sync on a Mac with data: the
    /// next push sends every record.
    public func markEverythingPending() throws {
        try writer.write { db in try db.execute(sql: "UPDATE syncRecord SET pending = 1") }
    }

    /// A data type was turned on, or a filter for it widened (sensitive clips,
    /// a larger size cap): its rows are offered again, and the cursor goes back
    /// to 0 because the records the filter dropped on arrival are not pulled
    /// again otherwise. The records already applied are skipped by
    /// last-writer-wins.
    public func restartSync(for entity: SyncCollection) throws {
        try writer.write { db in
            try db.execute(sql: "UPDATE syncRecord SET pending = 1 WHERE entity = ?", arguments: [entity])
            var state = try SyncState.read(db)
            state.cursor = 0
            try state.write(db)
        }
    }

    /// "Disconnect": forget the server this Mac was talking to. Local data and
    /// the `syncRecord` rows stay; the next server starts from the beginning.
    public func resetSyncProgress() throws {
        try updateSyncState {
            $0.cursor = 0
            $0.epoch = nil
            $0.lastSuccess = nil
            $0.confirmedKey = nil
            $0.unopened = [:]
        }
    }
}
