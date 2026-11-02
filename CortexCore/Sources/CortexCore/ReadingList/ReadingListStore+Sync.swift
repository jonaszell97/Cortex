import Foundation
import GRDB

enum ReadingListSyncError: Error, CustomStringConvertible {
    case malformed(String)

    var description: String {
        switch self {
        case .malformed(let reason): "malformed reading list payload: \(reason)"
        }
    }
}

/// Reading list links for the sync engine: the record key is the link's
/// normalized URL. The newer write wins the whole link (title, note, read
/// state).
public struct ReadingListSyncHandler: SyncEntityHandler {
    public var entity: SyncCollection { .reading }
    public var supportedVersion: Int { ReadingItemPayload.version }

    private let store: ReadingListStore
    /// A newer version of a link that says it was read before this is
    /// treated like the local purge treats it: deleted here, not stored.
    /// Otherwise purged links would come back from the server (this Mac's
    /// own records included).
    private let deleteReadBefore: Date?

    public init(store: ReadingListStore, deleteReadBefore: Date? = nil) {
        self.store = store
        self.deleteReadBefore = deleteReadBefore
    }

    public func outgoing(localKey: String, key: SyncKey, database: AppDatabase) async throws -> SyncOutgoing? {
        try await store.syncOutgoing(url: localKey)
    }

    public func prepare(payload: Data, blobs: SyncBlobSource) async throws -> SyncPreparedRecord {
        let decoded = try JSONDecoder().decode(ReadingItemPayload.self, from: payload)
        return try ReadingListStore.prepareRemote(decoded, deleteReadBefore: deleteReadBefore)
    }

    public func applyDeletion(localKey: String, in db: Database) throws {
        try db.execute(sql: "DELETE FROM readingItem WHERE url = ?", arguments: [localKey])
    }
}

extension ReadingListStore {
    // MARK: - Outgoing

    func syncOutgoing(url: String) async throws -> SyncOutgoing? {
        let item = try await database.reader.read { db in
            try ReadingItem.filter(Column("url") == url).fetchOne(db)
        }
        guard let item else { return nil }
        let payload = ReadingItemPayload(
            v: ReadingItemPayload.version, url: item.url, title: item.title, note: item.note,
            sourceAppName: item.sourceAppName, addedAt: item.addedAt.syncMilliseconds,
            readAt: item.readAt?.syncMilliseconds)
        return SyncOutgoing(payload: try JSONEncoder().encode(payload))
    }

    // MARK: - Incoming

    /// The URL is kept exactly as sent, since it is the record key; it only
    /// has to be a web link. (A later build may normalize differently, and
    /// both Macs must still agree on the key.)
    static func prepareRemote(_ remote: ReadingItemPayload, deleteReadBefore: Date? = nil) throws -> SyncPreparedRecord {
        guard ReadingItem.normalizedURL(remote.url) != nil else { throw ReadingListSyncError.malformed("not a web link") }
        let purged = if let readAt = remote.readAt, let deleteReadBefore {
            Date(syncMilliseconds: readAt) < deleteReadBefore
        } else {
            false
        }
        return SyncPreparedRecord(localKey: remote.url) { db, _ in
            guard !purged else {
                // What the purge would do with it: gone, and no tombstone.
                try db.execute(sql: "DELETE FROM readingItem WHERE url = ?", arguments: [remote.url])
                return .ignored
            }
            return try applyRemote(remote, db: db)
        }
    }

    /// Writes a remote link that is newer than the local version of the same
    /// URL, or that has none yet (the engine decides which).
    static func applyRemote(_ remote: ReadingItemPayload, db: Database) throws -> SyncApplyOutcome {
        var item = try ReadingItem.filter(Column("url") == remote.url).fetchOne(db) ?? ReadingItem(url: remote.url)
        item.title = ReadingItem.normalizedText(remote.title)
        item.note = ReadingItem.normalizedText(remote.note)
        item.sourceAppName = remote.sourceAppName
        item.addedAt = Date(syncMilliseconds: remote.addedAt)
        item.readAt = remote.readAt.map { Date(syncMilliseconds: $0) }
        if item.id == nil {
            try item.insert(db)
        } else {
            try item.update(db)
        }
        return .applied
    }
}
