import CryptoKit
import Foundation
import GRDB
@testable import CortexCore

// Stand-ins for the clip, snippet and action handlers of Steps 4 to 6, so the
// engine can be tested on its own.

/// Snippets on the real `snippet` table, so the `v4_sync` triggers fire for
/// both local edits and applied remote records.
struct SnippetTestHandler: SyncEntityHandler {
    var entity: SyncCollection { .snippet }
    var supportedVersion = 1
    /// The `v` written into outgoing payloads.
    var writtenVersion = 1
    /// Applying a snippet with this name throws.
    var poisonName: String?

    struct Payload: Codable {
        var v: Int
        var syncID: String
        var name: String
        var body: String
    }

    func outgoing(localKey: String, key: SyncKey, database: AppDatabase) async throws -> SyncOutgoing? {
        let row = try await database.reader.read { db -> [String]? in
            try Row.fetchOne(db, sql: "SELECT name, body FROM snippet WHERE syncID = ?", arguments: [localKey])
                .map { [$0["name"], $0["body"]] }
        }
        guard let row else { return nil }
        let payload = Payload(v: writtenVersion, syncID: localKey, name: row[0], body: row[1])
        return SyncOutgoing(payload: try JSONEncoder().encode(payload))
    }

    func prepare(payload: Data, blobs: SyncBlobSource) async throws -> SyncPreparedRecord {
        let decoded = try JSONDecoder().decode(Payload.self, from: payload)
        let poison = poisonName
        return SyncPreparedRecord(localKey: decoded.syncID) { db, _ in
            if decoded.name == poison { throw DatabaseError(message: "poisoned") }
            let now = Date.now
            if try Bool.fetchOne(db, sql: "SELECT 1 FROM snippet WHERE syncID = ?", arguments: [decoded.syncID]) != nil {
                try db.execute(
                    sql: "UPDATE snippet SET name = ?, body = ?, updatedAt = ? WHERE syncID = ?",
                    arguments: [decoded.name, decoded.body, now, decoded.syncID])
            } else {
                try db.execute(sql: """
                    INSERT INTO snippet (name, body, tags, createdAt, updatedAt, syncID) VALUES (?, ?, '[]', ?, ?, ?)
                    """, arguments: [decoded.name, decoded.body, now, now, decoded.syncID])
            }
            return .applied
        }
    }

    func applyDeletion(localKey: String, in db: Database) throws {
        try db.execute(sql: "DELETE FROM snippet WHERE syncID = ?", arguments: [localKey])
    }
}

/// Free-form notes in a test table; text longer than `inlineLimit` goes as a
/// blob. Rows are tracked by hand, the way the triggers do for real data.
struct NoteTestHandler: SyncEntityHandler {
    var entity: SyncCollection { .action }
    var supportedVersion = 1
    var inlineLimit = 100
    /// Notes with these keys are excluded by the filters.
    var filtered: Set<String> = []
    /// A remote note with this key is not stored; the handler answers `.ignored`.
    var ignoredKey: String?

    struct Payload: Codable {
        var v: Int
        var key: String
        var text: String?
        var blob: String?
    }

    static func createTable(in database: AppDatabase) throws {
        try database.writer.write { db in
            try db.execute(sql: "CREATE TABLE note (key TEXT PRIMARY KEY, text TEXT NOT NULL)")
        }
    }

    static func set(_ key: String, _ text: String, in database: AppDatabase) throws {
        try database.writer.write { db in
            try db.execute(sql: """
                INSERT INTO note (key, text) VALUES (?, ?)
                ON CONFLICT (key) DO UPDATE SET text = excluded.text
                """, arguments: [key, text])
            try touch(key, deleted: false, db: db)
        }
    }

    static func remove(_ key: String, in database: AppDatabase) throws {
        try database.writer.write { db in
            try db.execute(sql: "DELETE FROM note WHERE key = ?", arguments: [key])
            try touch(key, deleted: true, db: db)
        }
    }

    static func text(_ key: String, in database: AppDatabase) throws -> String? {
        try database.reader.read { db in
            try String.fetchOne(db, sql: "SELECT text FROM note WHERE key = ?", arguments: [key])
        }
    }

    private static func touch(_ key: String, deleted: Bool, db: Database) throws {
        try db.execute(sql: """
            INSERT INTO syncRecord (entity, localKey, modifiedAt, pending, deleted)
            VALUES ('action', ?, \(SyncSchema.nowMs), 1, \(deleted ? 1 : 0))
            \(SyncSchema.markLocalWrite(deleted: deleted))
            """, arguments: [key])
    }

    func outgoing(localKey: String, key: SyncKey, database: AppDatabase) async throws -> SyncOutgoing? {
        if filtered.contains(localKey) { return nil }
        guard let text = try Self.text(localKey, in: database) else { return nil }
        let data = Data(text.utf8)
        if data.count <= inlineLimit {
            let payload = Payload(v: 1, key: localKey, text: text, blob: nil)
            return SyncOutgoing(payload: try JSONEncoder().encode(payload))
        }
        let blobID = key.blobID(for: data)
        let payload = Payload(v: 1, key: localKey, text: nil, blob: blobID)
        return SyncOutgoing(
            payload: try JSONEncoder().encode(payload), blobs: [.init(id: blobID, plaintext: data)])
    }

    func prepare(payload: Data, blobs: SyncBlobSource) async throws -> SyncPreparedRecord {
        let decoded = try JSONDecoder().decode(Payload.self, from: payload)
        let text: String
        if let blob = decoded.blob {
            text = String(decoding: try await blobs.blob(id: blob), as: UTF8.self)
        } else {
            text = decoded.text ?? ""
        }
        let ignored = decoded.key == ignoredKey
        return SyncPreparedRecord(localKey: decoded.key) { db, _ in
            if ignored { return .ignored }
            try db.execute(sql: """
                INSERT INTO note (key, text) VALUES (?, ?)
                ON CONFLICT (key) DO UPDATE SET text = excluded.text
                """, arguments: [decoded.key, text])
            return .applied
        }
    }

    func applyDeletion(localKey: String, in db: Database) throws {
        try db.execute(sql: "DELETE FROM note WHERE key = ?", arguments: [localKey])
    }
}

/// A transport that wraps another to inject failures and interleaved work.
final class HookedTransport: SyncTransport, @unchecked Sendable {
    private let wrapped: any SyncTransport
    private let lock = NSLock()
    private var _failures: [String: Error] = [:]
    private var _counts: [String: Int] = [:]
    private var _beforePush: (@Sendable () async throws -> Void)?
    private var _afterPush: Error?
    private var _hooks: [String: @Sendable () -> Void] = [:]

    init(_ wrapped: any SyncTransport) {
        self.wrapped = wrapped
    }

    /// Makes the `n`th call (1-based) of an operation throw `error`.
    func fail(_ operation: String, onCall n: Int, with error: Error) {
        lock.withLock { _failures["\(operation)#\(n)"] = error }
    }

    func failAlways(_ operation: String, with error: Error) {
        lock.withLock { _failures[operation] = error }
    }

    /// Runs `work` after the engine decided to push, before the push is sent.
    func beforePush(_ work: @escaping @Sendable () async throws -> Void) {
        lock.withLock { _beforePush = work }
    }

    /// The server takes the push, but the response is lost.
    func loseNextPushResponse(_ error: Error = SyncTransportError.unreachable) {
        lock.withLock { _afterPush = error }
    }

    /// Runs `work` before every call of an operation.
    func onCall(_ operation: String, _ work: @escaping @Sendable () -> Void) {
        lock.withLock { _hooks[operation] = work }
    }

    func count(_ operation: String) -> Int { lock.withLock { _counts[operation] ?? 0 } }

    private func enter(_ operation: String) throws {
        lock.withLock { _hooks[operation] }?()
        let failure = lock.withLock { () -> Error? in
            let n = (_counts[operation] ?? 0) + 1
            _counts[operation] = n
            return _failures["\(operation)#\(n)"] ?? _failures[operation]
        }
        if let failure { throw failure }
    }

    func health() async throws -> SyncHealth {
        try enter("health")
        return try await wrapped.health()
    }

    func changes(since cursor: Int64, limit: Int) async throws -> SyncChangesPage {
        try enter("changes")
        return try await wrapped.changes(since: cursor, limit: limit)
    }

    func push(device: String, records: [SyncWireRecord]) async throws -> SyncPushResponse {
        try enter("push")
        if let work = lock.withLock({ () -> (@Sendable () async throws -> Void)? in
            defer { _beforePush = nil }
            return _beforePush
        }) {
            try await work()
        }
        let response = try await wrapped.push(device: device, records: records)
        if let error = lock.withLock({ () -> Error? in
            defer { _afterPush = nil }
            return _afterPush
        }) {
            throw error
        }
        return response
    }

    func missingBlobs(_ ids: [String]) async throws -> SyncMissingBlobs {
        try enter("missingBlobs")
        return try await wrapped.missingBlobs(ids)
    }

    func putBlob(id: String, data: Data) async throws -> SyncPutBlobResult {
        try enter("putBlob")
        return try await wrapped.putBlob(id: id, data: data)
    }

    func blob(id: String) async throws -> SyncBlobDownload? {
        try enter("blob")
        return try await wrapped.blob(id: id)
    }
}

/// Sealing as protocol v1 did, written out from docs/SYNC.md, "Sealing and
/// authenticated metadata", rather than with `SyncKey`, which no longer seals
/// this way: AES-GCM with the HKDF payload key and only `collection + "/" + id`
/// as AAD.
enum SyncKeyTestV1 {
    static func seal(_ plaintext: Data, key: SyncKey, collection: SyncCollection, id: String) throws -> Data {
        let payloadKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: key.rawValue), info: Data("cortex sync payload v1".utf8),
            outputByteCount: 32)
        return try AES.GCM.seal(plaintext, using: payloadKey, authenticating: Data("\(collection.rawValue)/\(id)".utf8)).combined!
    }

    /// A record as a v1 build pushed it: a tombstone has no payload.
    static func record(
        _ plaintext: Data, key: SyncKey, collection: SyncCollection, id: String,
        modifiedAt: Int64 = Date.now.syncMilliseconds, device: String, deleted: Bool = false
    ) throws -> SyncWireRecord {
        SyncWireRecord(
            collection: collection, id: id, modifiedAt: modifiedAt, device: device, deleted: deleted,
            payload: deleted ? nil : try seal(plaintext, key: key, collection: collection, id: id))
    }
}

extension SyncWireRecord {
    /// A record sealed with `key` the way a Mac pushes it.
    static func sealed(
        _ plaintext: Data, key: SyncKey, collection: SyncCollection, id: String,
        modifiedAt: Int64 = Date.now.syncMilliseconds, device: String, deleted: Bool = false
    ) throws -> SyncWireRecord {
        let header = SyncRecordHeader(collection: collection, id: id, modifiedAt: modifiedAt, device: device, deleted: deleted)
        return SyncWireRecord(
            collection: collection, id: id, modifiedAt: modifiedAt, device: device, deleted: deleted,
            payload: try key.seal(plaintext, for: header))
    }
}

/// One Mac in a test: a database, a sync engine, and the stores on top.
struct SyncPeer {
    let database: AppDatabase
    let engine: SyncEngine
    let snippets: SnippetStore
    let transport: HookedTransport

    var deviceID: String { get throws { try database.syncState().deviceID } }

    init(
        database: AppDatabase, transport: HookedTransport, key: SyncKey, handlers: [any SyncEntityHandler] = [SnippetTestHandler()],
        onRemoteChanges: (@Sendable (SyncCycleReport) -> Void)? = nil
    ) {
        self.database = database
        self.snippets = SnippetStore(database: database)
        self.transport = transport
        self.engine = SyncEngine(
            database: database, transport: transport, key: key, handlers: handlers, onRemoteChanges: onRemoteChanges)
    }

    init(
        server: InMemorySyncServer, key: SyncKey, handlers: [any SyncEntityHandler] = [SnippetTestHandler()],
        token: String = InMemorySyncServer.token,
        onRemoteChanges: (@Sendable (SyncCycleReport) -> Void)? = nil
    ) throws {
        self.init(
            database: try makeTestDatabase(),
            transport: HookedTransport(DirectTransport(server: server, token: token)),
            key: key, handlers: handlers, onRemoteChanges: onRemoteChanges)
    }

    struct Row: Equatable {
        var entity: String
        var localKey: String
        var modifiedAt: Int64
        var pending: Bool
        var deleted: Bool
        var device: String?
    }

    func rows(_ entity: String) throws -> [Row] {
        try database.reader.read { db in
            try GRDB.Row.fetchAll(db, sql: """
                SELECT entity, localKey, modifiedAt, pending, deleted, device FROM syncRecord
                WHERE entity = ? ORDER BY localKey
                """, arguments: [entity]).map {
                Row(entity: $0["entity"], localKey: $0["localKey"], modifiedAt: $0["modifiedAt"],
                    pending: $0["pending"], deleted: $0["deleted"], device: $0["device"])
            }
        }
    }

    func row(_ entity: String, _ localKey: String) throws -> Row? {
        try rows(entity).first { $0.localKey == localKey }
    }

    /// Whether the server has taken or sent a version of this record.
    func isSynced(_ entity: String, _ localKey: String) throws -> Bool {
        try database.reader.read { db in
            try Bool.fetchOne(
                db, sql: "SELECT synced FROM syncRecord WHERE entity = ? AND localKey = ?", arguments: [entity, localKey]) ?? false
        }
    }

    var pendingCount: Int {
        get throws {
            try database.reader.read { db in
                try Int.fetchOne(db, sql: "SELECT count(*) FROM syncRecord WHERE pending = 1") ?? 0
            }
        }
    }

    func syncID(ofSnippet name: String) throws -> String? {
        try database.reader.read { db in
            try String.fetchOne(db, sql: "SELECT syncID FROM snippet WHERE name = ?", arguments: [name])
        }
    }

    /// name → body of every snippet.
    func snippetBodies() throws -> [String: String] {
        try database.reader.read { db in
            Dictionary(uniqueKeysWithValues: try GRDB.Row.fetchAll(db, sql: "SELECT name, body FROM snippet")
                .map { ($0["name"] as String, $0["body"] as String) })
        }
    }
}
