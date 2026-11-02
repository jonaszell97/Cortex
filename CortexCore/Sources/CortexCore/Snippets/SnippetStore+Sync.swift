import Foundation
import GRDB

enum SnippetSyncError: Error, CustomStringConvertible {
    case malformed(String)

    var description: String {
        switch self {
        case .malformed(let reason): "malformed snippet payload: \(reason)"
        }
    }
}

/// Snippets for the sync engine: the record key is the snippet's `syncID`.
/// `usageCount` and `lastUsedAt` stay local (docs/SYNC.md, "What syncs and what
/// stays local").
public struct SnippetSyncHandler: SyncEntityHandler {
    public var entity: SyncCollection { .snippet }
    public var supportedVersion: Int { SnippetPayload.version }

    private let store: SnippetStore

    public init(store: SnippetStore) {
        self.store = store
    }

    public func outgoing(localKey: String, key: SyncKey, database: AppDatabase) async throws -> SyncOutgoing? {
        try await store.syncOutgoing(syncID: localKey)
    }

    public func prepare(payload: Data, blobs: SyncBlobSource) async throws -> SyncPreparedRecord {
        let decoded = try JSONDecoder().decode(SnippetPayload.self, from: payload)
        return try SnippetStore.prepareRemote(decoded)
    }

    public func applyDeletion(localKey: String, in db: Database) throws {
        try db.execute(sql: "DELETE FROM snippet WHERE syncID = ?", arguments: [localKey])
    }
}

extension SnippetStore {
    // MARK: - Outgoing

    func syncOutgoing(syncID: String) async throws -> SyncOutgoing? {
        let snippet = try await database.reader.read { db in
            try Snippet.fetchOne(db, sql: "SELECT * FROM snippet WHERE syncID = ?", arguments: [syncID])
        }
        guard let snippet else { return nil }
        let payload = SnippetPayload(
            v: SnippetPayload.version, syncID: syncID, name: snippet.name, keyword: snippet.keyword,
            body: snippet.body, tags: snippet.tags,
            createdAt: snippet.createdAt.syncMilliseconds, updatedAt: snippet.updatedAt.syncMilliseconds)
        return SyncOutgoing(payload: try JSONEncoder().encode(payload))
    }

    // MARK: - Incoming

    /// Remote data goes through the same normalization and validation as a
    /// local edit; a snippet that can't pass is skipped.
    static func prepareRemote(_ remote: SnippetPayload) throws -> SyncPreparedRecord {
        guard !remote.syncID.isEmpty else { throw SnippetSyncError.malformed("no syncID") }
        let checked = try normalized(Snippet(
            name: remote.name, keyword: remote.keyword, body: remote.body, tags: remote.tags,
            createdAt: Date(syncMilliseconds: remote.createdAt), updatedAt: Date(syncMilliseconds: remote.updatedAt)))
        var payload = remote
        payload.name = checked.name
        payload.keyword = checked.keyword
        payload.tags = checked.tags
        let normalizedPayload = payload
        return SyncPreparedRecord(localKey: remote.syncID) { db, write in
            try applyRemote(normalizedPayload, write: write, db: db)
        }
    }

    /// Writes a remote snippet that is newer than the local version of the
    /// same `syncID`, or that has none yet (the engine calls this then).
    ///
    /// - Unknown `syncID`, but a local snippet of the same name (ignoring case)
    ///   that was never synced and is still waiting to be pushed: the first
    ///   sync, when both Macs hold the same Raycast import. It is adopted: the
    ///   local row takes the remote `syncID` and the newer write decides the
    ///   content.
    /// - A name or keyword taken by another snippet: the older of the two
    ///   writes gives way (a name gets a number, a keyword is dropped). Both
    ///   Macs compare the same two write stamps, so both decide alike; the one
    ///   that gives way is written as a new version that travels to the other.
    ///
    /// The result is `.mergedLocally` when what's stored isn't what the remote
    /// payload says, so the other Mac hears about it.
    static func applyRemote(_ remote: SnippetPayload, write: SyncRemoteWrite, db: Database) throws -> SyncApplyOutcome {
        let deviceID = try SyncState.read(db).deviceID
        let log = Log.logger("snippets")
        var useRemoteContent = true

        var target = try Snippet.fetchOne(db, sql: "SELECT * FROM snippet WHERE syncID = ?", arguments: [remote.syncID])
        if target == nil,
           let sameName = try Snippet.fetchOne(
                db, sql: "SELECT * FROM snippet WHERE name = ? COLLATE NOCASE", arguments: [remote.name]),
           let id = sameName.id,
           let oldSyncID = try String.fetchOne(db, sql: "SELECT syncID FROM snippet WHERE id = ?", arguments: [id]),
           let local = try Row.fetchOne(db, sql: """
                SELECT modifiedAt, device FROM syncRecord
                WHERE entity = 'snippet' AND localKey = ? AND pending = 1 AND synced = 0
                """, arguments: [oldSyncID]) {
            let localModifiedAt = try local.decode(Int64.self, forColumn: "modifiedAt")
            let localDevice: String = (local["device"] as String?) ?? deviceID
            useRemoteContent = SyncEngine.isNewer((write.modifiedAt, write.device), than: (localModifiedAt, localDevice))
            try db.execute(sql: "UPDATE snippet SET syncID = ? WHERE id = ?", arguments: [remote.syncID, id])
            try db.execute(
                sql: "DELETE FROM syncRecord WHERE entity = 'snippet' AND localKey = ?", arguments: [oldSyncID])
            target = sameName
            log.info("Adopted a local snippet for a remote one of the same name")
        }

        var snippet = target ?? Snippet(name: remote.name, body: remote.body)
        if useRemoteContent {
            snippet.name = remote.name
            snippet.keyword = remote.keyword
            snippet.body = remote.body
            snippet.tags = remote.tags
            snippet.createdAt = Date(syncMilliseconds: remote.createdAt)
            snippet.updatedAt = Date(syncMilliseconds: remote.updatedAt)

            if let other = try Row.fetchOne(
                db, sql: "SELECT id, name, syncID, updatedAt FROM snippet WHERE name = ? COLLATE NOCASE AND id IS NOT ?",
                arguments: [snippet.name, snippet.id]) {
                if SyncEngine.isNewer((write.modifiedAt, write.device), than: try version(of: other, deviceID: deviceID, db: db)) {
                    // The other snippet is older and gives way. A local write: it goes to the server too.
                    let name = try numbered(other["name"], db: db)
                    try db.execute(sql: "UPDATE snippet SET name = ? WHERE id = ?", arguments: [name, other["id"] as Int64])
                    log.info("A local snippet’s name was taken by a newer remote one; renamed to “\(name, privacy: .private)”")
                } else {
                    snippet.name = try numbered(remote.name, db: db)
                    log.info("A remote snippet’s name was taken; stored as “\(snippet.name, privacy: .private)”")
                }
            }

            if let keyword = snippet.keyword,
               let other = try Row.fetchOne(
                    db, sql: "SELECT id, syncID, updatedAt FROM snippet WHERE keyword = ? AND id IS NOT ?",
                    arguments: [keyword, snippet.id]) {
                if SyncEngine.isNewer((write.modifiedAt, write.device), than: try version(of: other, deviceID: deviceID, db: db)) {
                    try db.execute(sql: "UPDATE snippet SET keyword = NULL WHERE id = ?", arguments: [other["id"] as Int64])
                } else {
                    snippet.keyword = nil
                }
            }
        }

        if snippet.id == nil {
            try snippet.insert(db)
            let generated = try String.fetchOne(db, sql: "SELECT syncID FROM snippet WHERE id = ?", arguments: [snippet.id])
            try db.execute(sql: "UPDATE snippet SET syncID = ? WHERE id = ?", arguments: [remote.syncID, snippet.id])
            if let generated {
                try db.execute(
                    sql: "DELETE FROM syncRecord WHERE entity = 'snippet' AND localKey = ?", arguments: [generated])
            }
        } else {
            try snippet.update(db)
        }

        let matches = snippet.name == remote.name && snippet.keyword == remote.keyword
            && snippet.body == remote.body && snippet.tags == remote.tags
        return matches ? .applied : .mergedLocally
    }

    /// The write stamp of a local snippet: what its `syncRecord` says, or its
    /// edit date if it has no row.
    private static func version(of snippet: Row, deviceID: String, db: Database) throws -> (Int64, String) {
        let row = try Row.fetchOne(db, sql: """
            SELECT modifiedAt, device FROM syncRecord WHERE entity = 'snippet' AND localKey = ?
            """, arguments: [snippet["syncID"] as String?])
        let modifiedAt = try row.map { try $0.decode(Int64.self, forColumn: "modifiedAt") }
            ?? (snippet["updatedAt"] as Date).syncMilliseconds
        let device: String = (row?["device"] as String?) ?? deviceID
        return (modifiedAt, device)
    }

    /// "Name (2)", or the first higher number that is free.
    private static func numbered(_ name: String, db: Database) throws -> String {
        var number = 2
        while try Bool.fetchOne(
            db, sql: "SELECT 1 FROM snippet WHERE name = ? COLLATE NOCASE", arguments: ["\(name) (\(number))"]) == true {
            number += 1
        }
        return "\(name) (\(number))"
    }
}
