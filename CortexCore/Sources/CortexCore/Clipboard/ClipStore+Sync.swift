import Foundation
import GRDB

/// What leaves this Mac and what is accepted from the other one (docs/SYNC.md,
/// "What syncs and what stays local"). Read at the start of each record, so a
/// changed setting applies right away.
public struct ClipSyncOptions: Sendable, Equatable {
    /// Sensitive clips travel only when this is on, in both directions.
    public var syncSensitive: Bool
    /// Clips above this size stay local, and arriving ones above it are ignored.
    public var maxClipBytes: Int
    /// Whether the text of arriving sensitive clips goes into the full-text index.
    public var indexSensitive: Bool
    /// An arriving clip that this would purge right away isn't stored.
    public var retention: RetentionPolicy?

    public init(
        syncSensitive: Bool = false,
        maxClipBytes: Int = 10 * 1024 * 1024,
        indexSensitive: Bool = false,
        retention: RetentionPolicy? = nil
    ) {
        self.syncSensitive = syncSensitive
        self.maxClipBytes = maxClipBytes
        self.indexSensitive = indexSensitive
        self.retention = retention
    }
}

enum ClipSyncError: Error, CustomStringConvertible {
    case unsupportedKind(String)
    case blobSizeMismatch(String)
    case malformed(String)

    var description: String {
        switch self {
        case .unsupportedKind(let kind): "clips of kind \(kind) don't sync"
        case .blobSizeMismatch(let id): "blob \(id) isn't the size the clip says"
        case .malformed(let reason): "malformed clip payload: \(reason)"
        }
    }
}

/// Clips for the sync engine: the record key is the content hash.
public struct ClipSyncHandler: SyncEntityHandler {
    public var entity: SyncCollection { .clip }
    public var supportedVersion: Int { ClipPayload.version }

    private let store: ClipStore
    private let options: @Sendable () -> ClipSyncOptions

    public init(store: ClipStore, options: @escaping @Sendable () -> ClipSyncOptions) {
        self.store = store
        self.options = options
    }

    public init(store: ClipStore, options: ClipSyncOptions = ClipSyncOptions()) {
        self.init(store: store, options: { options })
    }

    public func outgoing(localKey: String, key: SyncKey, database: AppDatabase) async throws -> SyncOutgoing? {
        try await store.syncOutgoing(contentHash: localKey, key: key, options: options())
    }

    public func prepare(payload: Data, blobs: SyncBlobSource) async throws -> SyncPreparedRecord {
        let decoded = try JSONDecoder().decode(ClipPayload.self, from: payload)
        return try await store.prepareRemote(decoded, blobs: blobs, options: options())
    }

    public func applyDeletion(localKey: String, in db: Database) throws {
        try store.deleteRemotelyDeleted(contentHash: localKey, db: db)
    }
}

extension ClipStore {
    // MARK: - Outgoing

    /// The payload of a clip, or nil if the filters keep it local: `files`
    /// clips (paths are machine-specific), sensitive clips with sensitive sync
    /// off, and clips above the size cap.
    func syncOutgoing(contentHash: String, key: SyncKey, options: ClipSyncOptions) async throws -> SyncOutgoing? {
        let loaded = try await database.reader.read { db -> (ClipItem, [ClipRepresentation])? in
            guard let item = try ClipItem.filter(ClipItem.Columns.contentHash == contentHash).fetchOne(db),
                  item.kind != .files,
                  options.syncSensitive || !item.isSensitive,
                  item.byteSize <= options.maxClipBytes
            else { return nil }
            let representations = try ClipRepresentation
                .filter(Column("clipItemID") == item.id)
                .order(Column("position"))
                .fetchAll(db)
            return (item, representations)
        }
        guard let (item, rows) = loaded else { return nil }

        var representations: [ClipPayload.Representation] = []
        var blobs: [SyncOutgoing.Blob] = []
        for row in rows {
            if let data = row.data {
                representations.append(.init(type: row.type, data: data, blob: nil, size: row.byteSize))
            } else if let blobID = row.blobID {
                let plaintext = try self.blobs.read(blobID)
                let id = key.blobID(for: plaintext)
                if !blobs.contains(where: { $0.id == id }) {
                    blobs.append(SyncOutgoing.Blob(id: id, plaintext: plaintext))
                }
                representations.append(.init(type: row.type, data: nil, blob: id, size: plaintext.count))
            }
        }
        let payload = ClipPayload(
            v: ClipPayload.version, contentHash: item.contentHash, kind: item.kind,
            representations: representations, plainText: item.plainText,
            isSensitive: item.isSensitive, isPinned: item.isPinned,
            sourceBundleID: item.sourceBundleID, sourceAppName: item.sourceAppName,
            createdAt: item.createdAt.syncMilliseconds, lastCopiedAt: item.lastCopiedAt.syncMilliseconds)
        return SyncOutgoing(payload: try JSONEncoder().encode(payload), blobs: blobs, keep: item.isPinned)
    }

    // MARK: - Incoming

    /// Decodes a remote clip. For an unknown clip that passes the filters, the
    /// blobs are downloaded and written to the local blob store here, outside
    /// the transaction, the same way `record` does it. A clip this Mac already
    /// has needs no download: only its flags and dates are merged.
    func prepareRemote(_ remote: ClipPayload, blobs source: SyncBlobSource, options: ClipSyncOptions) async throws -> SyncPreparedRecord {
        guard remote.kind != .files else { throw ClipSyncError.unsupportedKind(remote.kind.rawValue) }
        let hash = remote.contentHash
        let known = try await database.reader.read { db in
            try ClipItem.filter(ClipItem.Columns.contentHash == hash).fetchCount(db) > 0
        }

        var newItem: ClipItem?
        var prepared: [PreparedRepresentation] = []
        var newBlobIDs: [String] = []
        if !known && Self.accepts(remote, options: options) {
            do {
                var representations: [LoadedRepresentation] = []
                for representation in remote.representations {
                    let data: Data
                    if let blob = representation.blob {
                        data = try await source.blob(id: blob)
                        guard data.count == representation.size else { throw ClipSyncError.blobSizeMismatch(blob) }
                    } else if let inline = representation.data {
                        data = inline
                    } else {
                        throw ClipSyncError.malformed("a representation has neither data nor a blob")
                    }
                    representations.append(LoadedRepresentation(type: representation.type, data: data))
                }
                let snapshot = ClipSnapshot(
                    representations: representations, plainText: remote.plainText, isSensitive: remote.isSensitive,
                    sourceBundleID: remote.sourceBundleID, sourceAppName: remote.sourceAppName,
                    copiedAt: Date(syncMilliseconds: remote.lastCopiedAt),
                    createdAt: Date(syncMilliseconds: remote.createdAt))
                // The key must be the hash of what is stored, or the same
                // content copied here would not find this clip.
                guard snapshot.contentHash == hash, snapshot.kind == remote.kind else {
                    throw ClipSyncError.malformed("the content doesn't match its hash")
                }
                prepared = try prepareRepresentations(of: snapshot, newBlobIDs: &newBlobIDs)
                newItem = Self.makeItem(from: snapshot, hash: hash, indexSensitive: options.indexSensitive, pin: remote.isPinned)
            } catch {
                blobs.delete(newBlobIDs)
                throw error
            }
        }

        let insertItem = newItem
        let insertRepresentations = prepared
        let blobIDs = newBlobIDs
        let indexSensitive = options.indexSensitive
        let store = self
        return SyncPreparedRecord(
            localKey: hash,
            superseded: { _, _ in store.blobs.delete(blobIDs) },
            apply: { db, _ in
                if let existing = try ClipItem.filter(ClipItem.Columns.contentHash == hash).fetchOne(db) {
                    store.blobs.delete(blobIDs)
                    return try Self.merge(remote, into: existing, indexSensitive: indexSensitive, db: db)
                }
                guard var item = insertItem else { return .ignored }
                do {
                    try Self.insert(&item, representations: insertRepresentations, db: db)
                } catch {
                    store.blobs.delete(blobIDs)
                    throw error
                }
                return .applied
            })
    }

    /// The filters for an arriving clip: size, sensitive, and local retention
    /// (an unpinned clip older than the retention would be purged right away).
    static func accepts(_ remote: ClipPayload, options: ClipSyncOptions, now: Date = .now) -> Bool {
        if remote.isSensitive && !options.syncSensitive { return false }
        if remote.representations.reduce(0, { $0 + $1.size }) > options.maxClipBytes { return false }
        if !remote.isPinned, let retention = options.retention {
            let copied = Date(syncMilliseconds: remote.lastCopiedAt)
            if let maxAge = retention.maxAge, copied < now.addingTimeInterval(-maxAge) { return false }
            if remote.isSensitive, let maxAge = retention.sensitiveMaxAge, copied < now.addingTimeInterval(-maxAge) { return false }
        }
        return true
    }

    /// A clip both Macs have: `lastCopiedAt` takes the later value,
    /// `isSensitive` is OR-ed, and the newer write (the remote one, because the
    /// engine only calls this then) decides `isPinned`. When the result isn't
    /// what the remote payload says, this Mac has to send it back.
    static func merge(_ remote: ClipPayload, into existing: ClipItem, indexSensitive: Bool, db: Database) throws -> SyncApplyOutcome {
        var item = existing
        item.lastCopiedAt = max(existing.lastCopiedAt, Date(syncMilliseconds: remote.lastCopiedAt))
        item.isSensitive = existing.isSensitive || remote.isSensitive
        item.isPinned = remote.isPinned
        item.sourceBundleID = existing.sourceBundleID ?? remote.sourceBundleID
        item.sourceAppName = existing.sourceAppName ?? remote.sourceAppName
        item.searchText = searchText(
            plainText: item.plainText, recognizedText: item.recognizedText, sourceAppName: item.sourceAppName,
            isSensitive: item.isSensitive, indexSensitive: indexSensitive)
        try item.update(db)

        let matches = item.lastCopiedAt.syncMilliseconds == remote.lastCopiedAt
            && item.isSensitive == remote.isSensitive
            && item.isPinned == remote.isPinned
        return matches ? .applied : .mergedLocally
    }

    /// A remote delete of one clip. The blob files go after the commit, so a
    /// rolled-back page can't leave rows without their blobs.
    func deleteRemotelyDeleted(contentHash: String, db: Database) throws {
        let blobIDs = try String.fetchAll(db, sql: """
            SELECT blobID FROM clipRepresentation
            WHERE blobID IS NOT NULL AND clipItemID IN (SELECT id FROM clipItem WHERE contentHash = ?)
            """, arguments: [contentHash])
        try db.execute(sql: "DELETE FROM clipItem WHERE contentHash = ?", arguments: [contentHash])
        let blobs = blobs
        db.afterNextTransaction(onCommit: { _ in blobs.delete(blobIDs) })
    }
}
