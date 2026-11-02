import Foundation
import GRDB

/// How long history is kept. Pinned items are always kept.
public struct RetentionPolicy: Sendable, Equatable {
    /// Seconds; nil keeps items regardless of age.
    public var maxAge: TimeInterval?
    /// Number of unpinned items to keep; nil keeps any number.
    public var maxCount: Int?
    /// Seconds for sensitive items; nil means the same as `maxAge`.
    public var sensitiveMaxAge: TimeInterval?

    public init(maxAge: TimeInterval?, maxCount: Int?, sensitiveMaxAge: TimeInterval? = nil) {
        self.maxAge = maxAge
        self.maxCount = maxCount
        self.sensitiveMaxAge = sensitiveMaxAge
    }

    public static let `default` = RetentionPolicy(maxAge: 30 * 86_400, maxCount: 2_000)
}

/// Clipboard history storage on top of `AppDatabase`. Synchronous methods
/// block on the database; call them off the main actor.
public final class ClipStore: Sendable {
    /// Payloads above this size, and all images, go to the blob store.
    public static let inlineLimit = 256 * 1024

    public enum RecordOutcome: Sendable, Equatable {
        case inserted(Int64)
        case bumped(Int64)
        case skipped
    }

    let database: AppDatabase
    let log = Log.logger("clips")

    public init(database: AppDatabase) {
        self.database = database
    }

    var blobs: BlobStore { database.blobs }

    // MARK: - Recording

    /// Stores a snapshot, or moves the existing item with the same content to
    /// the top.
    ///
    /// - Parameters:
    ///   - indexSensitive: Whether the text of sensitive items goes into the
    ///     full-text index.
    ///   - bumpExisting: False for imports: an existing item keeps its date.
    ///   - pin: Pins the item, new or existing.
    @discardableResult
    public func record(
        _ snapshot: ClipSnapshot,
        indexSensitive: Bool,
        bumpExisting: Bool = true,
        pin: Bool = false
    ) throws -> RecordOutcome {
        guard !snapshot.isEmpty else { return .skipped }
        let hash = snapshot.contentHash

        if let id = try database.writer.write({ db in
            try self.bumpIfExists(hash: hash, snapshot: snapshot, indexSensitive: indexSensitive,
                                  bumpExisting: bumpExisting, pin: pin, db: db)
        }) {
            return .bumped(id)
        }

        // Blobs are written before the transaction so it stays short. If the
        // insert fails, they are deleted again; a crash leaves orphans that
        // `removeOrphanBlobs()` sweeps at the next launch.
        var newBlobIDs: [String] = []
        do {
            let prepared = try prepareRepresentations(of: snapshot, newBlobIDs: &newBlobIDs)
            var item = Self.makeItem(from: snapshot, hash: hash, indexSensitive: indexSensitive, pin: pin)

            let outcome: RecordOutcome = try database.writer.write { db in
                // Another writer may have inserted the same content meanwhile.
                if let id = try self.bumpIfExists(hash: hash, snapshot: snapshot, indexSensitive: indexSensitive,
                                                  bumpExisting: bumpExisting, pin: pin, db: db) {
                    return .bumped(id)
                }
                try Self.insert(&item, representations: prepared, db: db)
                return .inserted(item.id!)
            }
            if case .bumped = outcome { blobs.delete(newBlobIDs) }
            return outcome
        } catch {
            blobs.delete(newBlobIDs)
            throw error
        }
    }

    /// A representation ready to be inserted: inline, or already in the blob store.
    struct PreparedRepresentation: Sendable {
        var type: String
        var data: Data?
        var blobID: String?
        var size: Int
    }

    /// Images and payloads above `inlineLimit` go to the blob store, the rest
    /// stays in the row. Written before the transaction so it stays short;
    /// the caller deletes `newBlobIDs` again if the insert doesn't happen
    /// (and a crash leaves orphans that `removeOrphanBlobs()` sweeps).
    func prepareRepresentations(of snapshot: ClipSnapshot, newBlobIDs: inout [String]) throws -> [PreparedRepresentation] {
        var prepared: [PreparedRepresentation] = []
        for representation in snapshot.representations {
            if ClipType.images.contains(representation.type) || representation.data.count > Self.inlineLimit {
                let id = try blobs.write(representation.data)
                newBlobIDs.append(id)
                prepared.append(PreparedRepresentation(type: representation.type, data: nil, blobID: id, size: representation.data.count))
            } else {
                prepared.append(PreparedRepresentation(type: representation.type, data: representation.data, blobID: nil, size: representation.data.count))
            }
        }
        return prepared
    }

    static func insert(_ item: inout ClipItem, representations: [PreparedRepresentation], db: Database) throws {
        try item.insert(db)
        for (position, representation) in representations.enumerated() {
            var row = ClipRepresentation(
                clipItemID: item.id!, position: position, type: representation.type,
                data: representation.data, blobID: representation.blobID, byteSize: representation.size)
            try row.insert(db)
        }
    }

    private func bumpIfExists(
        hash: String, snapshot: ClipSnapshot, indexSensitive: Bool, bumpExisting: Bool, pin: Bool, db: Database
    ) throws -> Int64? {
        guard var existing = try ClipItem.filter(ClipItem.Columns.contentHash == hash).fetchOne(db) else {
            return nil
        }
        if bumpExisting {
            existing.lastCopiedAt = snapshot.copiedAt
            existing.sourceBundleID = snapshot.sourceBundleID ?? existing.sourceBundleID
            existing.sourceAppName = snapshot.sourceAppName ?? existing.sourceAppName
            existing.isSensitive = existing.isSensitive || snapshot.isSensitive
            existing.searchText = Self.searchText(
                plainText: existing.plainText, recognizedText: existing.recognizedText,
                sourceAppName: existing.sourceAppName, isSensitive: existing.isSensitive, indexSensitive: indexSensitive)
        }
        if pin { existing.isPinned = true }
        try existing.update(db)
        return existing.id
    }

    static func makeItem(from snapshot: ClipSnapshot, hash: String, indexSensitive: Bool, pin: Bool) -> ClipItem {
        let kind = snapshot.kind
        var plainText = snapshot.plainText
        var preview: String
        var thumbnail: Data?

        switch kind {
        case .files:
            let urls = snapshot.fileURLs
            plainText = urls.map { $0.isFileURL ? $0.path : $0.absoluteString }.joined(separator: "\n")
            preview = PreviewText.make(urls.map(\.lastPathComponent).joined(separator: ", "))
        case .image:
            let image = snapshot.representations.first { ClipType.images.contains($0.type) }?.data
            thumbnail = image.flatMap(Thumbnail.png(from:))
            let size = image.flatMap(Thumbnail.pixelSize(of:)).map { " \($0.width)×\($0.height)" } ?? ""
            preview = plainText.map(PreviewText.make).flatMap { $0.isEmpty ? nil : $0 } ?? "Image\(size)"
        case .text, .richText:
            preview = PreviewText.make(plainText ?? "")
            if preview.isEmpty { preview = kind == .richText ? "Rich text" : "Empty text" }
        }

        return ClipItem(
            contentHash: hash,
            kind: kind,
            preview: preview,
            plainText: plainText,
            searchText: searchText(
                plainText: plainText, recognizedText: nil, sourceAppName: snapshot.sourceAppName,
                isSensitive: snapshot.isSensitive, indexSensitive: indexSensitive),
            isSensitive: snapshot.isSensitive,
            isPinned: pin,
            sourceBundleID: snapshot.sourceBundleID,
            sourceAppName: snapshot.sourceAppName,
            byteSize: snapshot.byteSize,
            thumbnail: thumbnail,
            createdAt: snapshot.createdAt ?? snapshot.copiedAt,
            lastCopiedAt: snapshot.copiedAt)
    }

    /// The text and the text recognised in an image follow the same rule:
    /// for a sensitive clip, only when sensitive text is indexed.
    static func searchText(
        plainText: String?, recognizedText: String?, sourceAppName: String?, isSensitive: Bool, indexSensitive: Bool
    ) -> String {
        let texts = isSensitive && !indexSensitive ? [] : [plainText, recognizedText]
        return (texts + [sourceAppName]).compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    // MARK: - Reading

    /// Newest first. An empty query lists everything; otherwise every word
    /// must match as a prefix.
    public func summaries(matching query: String = "", limit: Int = 500) async throws -> [ClipSummary] {
        try await database.reader.read { db in
            if let pattern = FTS5Pattern(matchingAllPrefixesIn: query) {
                return try ClipSummary.fetchAll(db, sql: """
                    SELECT \(ClipSummary.selection) FROM clipItem
                    WHERE id IN (SELECT rowid FROM clipItemFTS WHERE clipItemFTS MATCH ?)
                    ORDER BY lastCopiedAt DESC LIMIT ?
                    """, arguments: [pattern, limit])
            }
            return try ClipSummary.fetchAll(db, sql: """
                SELECT \(ClipSummary.selection) FROM clipItem
                ORDER BY lastCopiedAt DESC LIMIT ?
                """, arguments: [limit])
        }
    }

    public func detail(id: Int64) async throws -> ClipDetail? {
        let rows = try await database.reader.read { db -> (ClipItem, [ClipRepresentation])? in
            guard let item = try ClipItem.fetchOne(db, key: id) else { return nil }
            let representations = try ClipRepresentation
                .filter(Column("clipItemID") == id)
                .order(Column("position"))
                .fetchAll(db)
            return (item, representations)
        }
        guard let (item, representations) = rows else { return nil }
        let loaded = try representations.map { row in
            if let data = row.data { return LoadedRepresentation(type: row.type, data: data) }
            guard let blobID = row.blobID else { return LoadedRepresentation(type: row.type, data: Data()) }
            return LoadedRepresentation(type: row.type, data: try blobs.read(blobID))
        }
        return ClipDetail(item: item, representations: loaded)
    }

    public func count() async throws -> Int {
        try await database.reader.read { db in try ClipItem.fetchCount(db) }
    }

    /// The text of the newest text and rich-text clips, newest first (for
    /// the `{clipboard offset=n}` placeholder). A sensitive clip keeps its
    /// place but has no text: a snippet never pastes a password.
    public func recentPlainTexts(limit: Int) async throws -> [String?] {
        try await database.reader.read { db in
            try Optional<String>.fetchAll(db, sql: """
                SELECT CASE WHEN isSensitive THEN NULL ELSE plainText END FROM clipItem
                WHERE kind IN ('text', 'richText') AND plainText IS NOT NULL
                ORDER BY lastCopiedAt DESC LIMIT ?
                """, arguments: [limit])
        }
    }

    /// The newest text and rich-text clips with when they were last copied,
    /// newest first, for a `$` form's suggestions. Sensitive clips are left
    /// out.
    public func recentTexts(limit: Int) async throws -> [RecentClipText] {
        try await database.reader.read { db in
            try Row.fetchAll(db, sql: """
                SELECT plainText, lastCopiedAt FROM clipItem
                WHERE kind IN ('text', 'richText') AND plainText IS NOT NULL AND NOT isSensitive
                ORDER BY lastCopiedAt DESC LIMIT ?
                """, arguments: [limit])
                .map { RecentClipText(text: $0["plainText"], copiedAt: $0["lastCopiedAt"]) }
        }
    }

    // MARK: - Editing

    /// Moves an item to the top after it was pasted or copied from the palette.
    public func markUsed(id: Int64, at date: Date = .now) throws {
        try database.writer.write { db in
            try db.execute(sql: "UPDATE clipItem SET lastCopiedAt = ? WHERE id = ?", arguments: [date, id])
        }
    }

    public func setPinned(_ pinned: Bool, id: Int64) throws {
        try database.writer.write { db in
            try db.execute(sql: "UPDATE clipItem SET isPinned = ? WHERE id = ?", arguments: [pinned, id])
        }
    }

    @discardableResult
    public func delete(ids: [Int64]) throws -> Int {
        guard !ids.isEmpty else { return 0 }
        let placeholders = databaseQuestionMarks(count: ids.count)
        return try deleteItems(where: "id IN (\(placeholders))", arguments: StatementArguments(ids), tombstone: true)
    }

    /// Clears the history. Pinned items stay unless `includingPinned`.
    @discardableResult
    public func deleteAll(includingPinned: Bool = false) throws -> Int {
        try deleteItems(where: includingPinned ? "1" : "isPinned = 0", arguments: [])
    }

    /// Applies the retention policy. Returns the number of deleted items.
    @discardableResult
    public func purge(policy: RetentionPolicy, now: Date = .now) throws -> Int {
        var conditions: [String] = []
        var arguments: StatementArguments = []
        if let maxAge = policy.maxAge {
            conditions.append("lastCopiedAt < ?")
            arguments += [now.addingTimeInterval(-maxAge)]
        }
        if let sensitiveMaxAge = policy.sensitiveMaxAge {
            conditions.append("(isSensitive = 1 AND lastCopiedAt < ?)")
            arguments += [now.addingTimeInterval(-sensitiveMaxAge)]
        }
        if let maxCount = policy.maxCount {
            conditions.append("id NOT IN (SELECT id FROM clipItem WHERE isPinned = 0 ORDER BY lastCopiedAt DESC LIMIT ?)")
            arguments += [maxCount]
        }
        guard !conditions.isEmpty else { return 0 }
        let count = try deleteItems(where: "isPinned = 0 AND (\(conditions.joined(separator: " OR ")))", arguments: arguments)
        if count > 0 { log.info("Purged \(count) items") }
        return count
    }

    /// - Parameter tombstone: Whether the delete travels to the other Mac.
    ///   Only an explicit delete does; purges and Clear History stay local.
    private func deleteItems(where condition: String, arguments: StatementArguments, tombstone: Bool = false) throws -> Int {
        let (count, blobIDs) = try database.writer.write { db -> (Int, [String]) in
            if tombstone {
                try SyncSchema.markClipTombstones(where: condition, arguments: arguments, db: db)
            }
            let blobIDs = try String.fetchAll(db, sql: """
                SELECT blobID FROM clipRepresentation
                WHERE blobID IS NOT NULL AND clipItemID IN (SELECT id FROM clipItem WHERE \(condition))
                """, arguments: arguments)
            try db.execute(sql: "DELETE FROM clipItem WHERE \(condition)", arguments: arguments)
            return (db.changesCount, blobIDs)
        }
        blobs.delete(blobIDs)
        return count
    }

    // MARK: - Recognised text

    /// Image clips whose text has not been read yet, newest first.
    public func unrecognizedImageIDs(limit: Int) async throws -> [Int64] {
        try await database.reader.read { db in
            try Int64.fetchAll(db, sql: """
                SELECT id FROM clipItem WHERE kind = 'image' AND recognizedText IS NULL
                ORDER BY lastCopiedAt DESC LIMIT ?
                """, arguments: [limit])
        }
    }

    /// The decoded image of a clip, for reading its text; nil if the clip
    /// is gone or has no image.
    public func imageData(id: Int64) async throws -> Data? {
        let stored = try await database.reader.read { db -> (data: Data?, blobID: String?)? in
            try Row.fetchOne(db, sql: """
                SELECT data, blobID FROM clipRepresentation
                WHERE clipItemID = ? AND type IN (?, ?) ORDER BY position LIMIT 1
                """, arguments: [id, ClipType.png, ClipType.tiff])
                .map { ($0["data"], $0["blobID"]) }
        }
        guard let stored else { return nil }
        if let data = stored.data { return data }
        return try stored.blobID.map(blobs.read)
    }

    /// Stores the text read from an image clip ("" for none) and indexes it.
    /// `markSensitive` flags the clip too (the text looked like a secret).
    /// Does nothing if the clip was deleted meanwhile. Changes nothing that
    /// syncs, unless the clip is flagged.
    public func setRecognizedText(_ text: String, id: Int64, markSensitive: Bool = false, indexSensitive: Bool) throws {
        try database.writer.write { db in
            guard let item = try ClipItem.fetchOne(db, key: id) else { return }
            let isSensitive = item.isSensitive || markSensitive
            let searchText = Self.searchText(
                plainText: item.plainText, recognizedText: text, sourceAppName: item.sourceAppName,
                isSensitive: isSensitive, indexSensitive: indexSensitive)
            // Only these columns: writing the whole row back would touch
            // the ones the sync triggers watch.
            try db.execute(
                sql: "UPDATE clipItem SET recognizedText = ?, searchText = ?, isSensitive = ? WHERE id = ?",
                arguments: [text, searchText, isSensitive, id])
        }
    }

    // MARK: - Maintenance

    /// Rebuilds the search text of sensitive items after the "index sensitive
    /// items" setting changed.
    public func reindexSensitive(indexSensitive: Bool) throws {
        try database.writer.write { db in
            let rows = try Row.fetchAll(db, sql: "SELECT id, plainText, recognizedText, sourceAppName FROM clipItem WHERE isSensitive = 1")
            for row in rows {
                let text = Self.searchText(
                    plainText: row["plainText"], recognizedText: row["recognizedText"], sourceAppName: row["sourceAppName"],
                    isSensitive: true, indexSensitive: indexSensitive)
                try db.execute(sql: "UPDATE clipItem SET searchText = ? WHERE id = ?", arguments: [text, row["id"]])
            }
        }
    }

    /// Deletes blob files no row refers to. Call before recording starts:
    /// `record` writes blobs before inserting the rows that refer to them.
    @discardableResult
    public func removeOrphanBlobs() throws -> Int {
        let referenced = try database.reader.read { db in
            Set(try String.fetchAll(db, sql: "SELECT blobID FROM clipRepresentation WHERE blobID IS NOT NULL"))
        }
        let orphans = try blobs.storedIDs().subtracting(referenced)
        blobs.delete(orphans)
        if !orphans.isEmpty { log.info("Removed \(orphans.count) orphaned blobs") }
        return orphans.count
    }
}
