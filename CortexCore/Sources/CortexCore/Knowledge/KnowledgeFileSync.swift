import CryptoKit
import Foundation
import GRDB

enum KnowledgeSyncError: Error, CustomStringConvertible {
    case malformed(String)

    var description: String {
        switch self {
        case .malformed(let reason): "malformed knowledge payload: \(reason)"
        }
    }
}

/// The knowledge folder for the sync engine (docs/modules/KNOWLEDGE.md, "Sync and
/// backups"): every file in it, at any depth, except hidden ones and those in
/// hidden folders (`.git/`, `.conflicts/`, `.gitignore`). `ActionFileSync`
/// generalised to a folder tree: the record key is the path relative to the
/// folder, `syncRecord.fileHash` the SHA-256 of the content last synced, and the
/// payload the bytes plus the modification date. Files up to `inlineLimit` travel
/// in the payload, larger ones (pictures in `assets/`) as blobs.
///
/// The losing version of a conflict, and every file a remote delete takes
/// away, goes to `.conflicts/<folders>/<name>-<date>-<hash>.<ext>`, which
/// nothing indexes, syncs or commits. The app's folder watcher indexes what
/// arrives; nothing here knows about items.
public struct KnowledgeFileSync: SyncEntityHandler {
    public static let inlineLimit = 256 * 1024
    /// Larger files stay on this Mac: the server takes blobs up to 32 MB.
    public static let maxFileBytes = 25 * 1024 * 1024
    public static let conflictsDirectoryName = ".conflicts"
    /// `metadata` key: the folder the rows describe. When it changes (another
    /// folder was chosen), the rows are forgotten instead of turning into
    /// tombstones for every file of the old folder.
    static let folderMetadataKey = "knowledgeSyncFolder"

    public var entity: SyncCollection { .knowledge }
    public var supportedVersion: Int { KnowledgeFilePayload.version }

    public let root: URL
    let hashes: KnowledgeFileHashes
    /// What the rows describe, stored in `metadata`: the folder's path unless
    /// the app names it otherwise. iOS names it, because the absolute path of
    /// an app's container is not guaranteed to stay the same.
    let folderIdentity: String

    /// `hashes`: kept across cycles by the app, so unchanged files are not
    /// read again every cycle.
    public init(root: URL, hashes: KnowledgeFileHashes = KnowledgeFileHashes(), folderIdentity: String? = nil) {
        self.root = root
        self.hashes = hashes
        self.folderIdentity = folderIdentity ?? root.standardizedFileURL.path(percentEncoded: false)
    }

    // MARK: - Paths and hashes

    /// A relative path of plain components: no `..`, nothing hidden, no
    /// empty component. Remote paths are checked with this before anything
    /// is written.
    static func isValidPath(_ path: String) -> Bool {
        guard !path.isEmpty, path.utf8.count <= 1024, !path.contains("\0"), !path.hasPrefix("/"), !path.hasSuffix("/")
        else { return false }
        return path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { component in
            !component.isEmpty && !component.hasPrefix(".") && component.utf8.count <= 255
        }
    }

    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func url(of path: String) -> URL {
        root.appending(path: path, directoryHint: .notDirectory)
    }

    private var rootExists: Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: root.path(percentEncoded: false), isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    // MARK: - Scanning (before each cycle)

    private struct LocalFile {
        var hash: String
        var modifiedAt: Date
    }

    /// The files that can sync, and the paths of every file that is there (a
    /// file that is too large stays local but must not look deleted).
    private func readFolder() -> (syncable: [String: LocalFile], present: Set<String>) {
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { return ([:], []) }
        let rootPath = root.standardizedFileURL.path(percentEncoded: false)
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        var syncable: [String: LocalFile] = [:]
        var present = Set<String>()
        var seen = Set<String>()
        for case let url as URL in enumerator {
            let full = url.standardizedFileURL.path(percentEncoded: false)
            guard full.hasPrefix(prefix) else { continue }
            let path = String(full.dropFirst(prefix.count))
            guard Self.isValidPath(path),
                  let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true
            else { continue }
            present.insert(path)
            seen.insert(path)
            let modified = values.contentModificationDate ?? .now
            guard let size = values.fileSize, size <= Self.maxFileBytes else {
                Log.sync.notice("A knowledge file is larger than \(Self.maxFileBytes / 1024 / 1024) MB; it stays local")
                continue
            }
            if let known = hashes.hash(of: path, size: size, modified: modified) {
                syncable[path] = LocalFile(hash: known, modifiedAt: modified)
            } else if let data = try? Data(contentsOf: url) {
                let hash = Self.hash(data)
                hashes.set(hash, of: path, size: size, modified: modified)
                syncable[path] = LocalFile(hash: hash, modifiedAt: modified)
            }
        }
        hashes.keep(only: seen)
        return (syncable, present)
    }

    /// Compares the folder with the `syncRecord` rows: a new or changed file
    /// is a pending write, a file that's gone is a tombstone. A changed file
    /// is stamped with its modification date, so the edit made last wins even
    /// if this Mac only notices it later. A missing folder changes nothing
    /// (it would look like every file was deleted).
    public func beforeCycle(database: AppDatabase) async throws {
        guard rootExists else {
            Log.sync.notice("The knowledge folder is missing; nothing is scanned")
            return
        }
        let (files, present) = readFolder()
        let now = Date.now
        let folder = folderIdentity
        try await database.writer.write { db in
            let scanned: String? = try String.fetchOne(
                db, sql: "SELECT value FROM metadata WHERE key = ?", arguments: [Self.folderMetadataKey])
            if scanned != folder {
                if scanned != nil {
                    // Another folder: what was synced from the old one says
                    // nothing about this one. Pull everything again; the
                    // newer of two versions of a file wins as always.
                    try db.execute(sql: "DELETE FROM syncRecord WHERE entity = 'knowledge'")
                    var state = try SyncState.read(db)
                    state.cursor = 0
                    try state.write(db)
                }
                try db.execute(sql: """
                    INSERT INTO metadata (key, value) VALUES (?, ?)
                    ON CONFLICT (key) DO UPDATE SET value = excluded.value
                    """, arguments: [Self.folderMetadataKey, folder])
            }

            let rows = try Row.fetchAll(db, sql: """
                SELECT localKey, deleted, fileHash FROM syncRecord WHERE entity = 'knowledge'
                """)
            var known: [String: (deleted: Bool, fileHash: String?)] = [:]
            for row in rows {
                known[row["localKey"]] = (row["deleted"], row["fileHash"])
            }

            for (path, file) in files {
                if let row = known[path], !row.deleted, row.fileHash == file.hash { continue }
                try db.execute(sql: """
                    INSERT INTO syncRecord (entity, localKey, modifiedAt, pending, deleted, device, fileHash)
                    VALUES ('knowledge', ?, ?, 1, 0, NULL, ?)
                    ON CONFLICT (entity, localKey) DO UPDATE SET
                      modifiedAt = \(SyncSchema.capped("max(excluded.modifiedAt, syncRecord.modifiedAt + 1)")),
                      pending = 1, deleted = 0, device = NULL, fileHash = excluded.fileHash
                    """, arguments: [path, min(file.modifiedAt, now).syncMilliseconds, file.hash])
            }
            for (path, row) in known where !row.deleted && !present.contains(path) {
                try db.execute(sql: """
                    UPDATE syncRecord SET
                      modifiedAt = \(SyncSchema.capped("max(\(SyncSchema.nowMs), modifiedAt + 1)")), pending = 1, deleted = 1, device = NULL
                    WHERE entity = 'knowledge' AND localKey = ?
                    """, arguments: [path])
            }
        }
    }

    // MARK: - Outgoing

    public func outgoing(localKey: String, key: SyncKey, database: AppDatabase) async throws -> SyncOutgoing? {
        let url = url(of: localKey)
        guard Self.isValidPath(localKey),
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey]),
              values.isRegularFile == true,
              let data = try? Data(contentsOf: url), data.count <= Self.maxFileBytes
        else { return nil }
        let modified = (values.contentModificationDate ?? .now).syncMilliseconds
        if data.count <= Self.inlineLimit {
            let payload = KnowledgeFilePayload(
                v: KnowledgeFilePayload.version, path: localKey, modified: modified, data: data, blob: nil, size: data.count)
            return SyncOutgoing(payload: try JSONEncoder().encode(payload))
        }
        let id = key.blobID(for: data)
        let payload = KnowledgeFilePayload(
            v: KnowledgeFilePayload.version, path: localKey, modified: modified, data: nil, blob: id, size: data.count)
        return SyncOutgoing(payload: try JSONEncoder().encode(payload), blobs: [SyncOutgoing.Blob(id: id, plaintext: data)])
    }

    // MARK: - Incoming

    public func prepare(payload: Data, blobs: SyncBlobSource) async throws -> SyncPreparedRecord {
        let remote = try JSONDecoder().decode(KnowledgeFilePayload.self, from: payload)
        guard Self.isValidPath(remote.path) else { throw KnowledgeSyncError.malformed("bad path") }
        guard remote.size <= Self.maxFileBytes else { throw KnowledgeSyncError.malformed("file too large") }
        let data: Data
        if let inline = remote.data {
            data = inline
        } else if let blob = remote.blob {
            data = try await blobs.blob(id: blob)
        } else {
            throw KnowledgeSyncError.malformed("neither data nor blob")
        }
        guard data.count == remote.size else { throw KnowledgeSyncError.malformed("size mismatch") }

        let path = remote.path
        let remoteHash = Self.hash(data)
        let modified = Date(syncMilliseconds: remote.modified)
        let sync = self

        return SyncPreparedRecord(
            localKey: path,
            superseded: { db, write in
                // The local version won. Keep the remote one, unless this is
                // only our own record coming back.
                guard let deviceID = try? SyncState.read(db).deviceID, write.device != deviceID,
                      let local = try? Data(contentsOf: sync.url(of: path)), Self.hash(local) != remoteHash
                else { return }
                sync.archive(data, at: path)
            },
            apply: { db, _ in
                let row = try Row.fetchOne(db, sql: """
                    SELECT fileHash, pending FROM syncRecord WHERE entity = 'knowledge' AND localKey = ?
                    """, arguments: [path])
                let existing = try? Data(contentsOf: sync.url(of: path))
                if let local = existing, Self.hash(local) != remoteHash {
                    // Unpushed local changes (or a file that was never synced)
                    // lose against the newer remote write; keep them.
                    let syncedHash: String? = row?["fileHash"]
                    let pending: Bool = row?["pending"] ?? false
                    if row == nil || syncedHash != Self.hash(local) || pending {
                        sync.archive(local, at: path)
                    }
                    try sync.write(data, at: path, modified: modified)
                } else if existing == nil {
                    try sync.write(data, at: path, modified: modified)
                }
                try db.execute(sql: """
                    INSERT INTO syncRecord (entity, localKey, modifiedAt, pending, deleted, device, fileHash)
                    VALUES ('knowledge', ?, ?, 0, 0, NULL, ?)
                    ON CONFLICT (entity, localKey) DO UPDATE SET fileHash = excluded.fileHash
                    """, arguments: [path, 0, remoteHash])
                return .applied
            })
    }

    /// A remote delete: the file moves to `.conflicts/` instead of vanishing.
    /// Only a file of exactly this name: on a case-insensitive volume
    /// `Note.md` may be what another record (`note.md`) wrote.
    public func applyDeletion(localKey: String, in db: Database) throws {
        guard Self.isValidPath(localKey) else { return }
        let url = url(of: localKey)
        let parent = url.deletingLastPathComponent()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: parent.path(percentEncoded: false))) ?? []
        guard names.contains(url.lastPathComponent), let local = try? Data(contentsOf: url) else { return }
        guard archive(local, at: localKey) else { return }
        try FileManager.default.removeItem(at: url)
        removeEmptyFolders(above: localKey)
    }

    // MARK: - Files

    /// Writes to a temporary file next to the target and renames it over
    /// the target, so a reader sees the old or the new content, never half.
    /// The file keeps the modification date it had on the other Mac.
    private func write(_ data: Data, at path: String, modified: Date) throws {
        let target = url(of: path)
        let folder = target.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let temporary = folder.appending(path: ".sync-\(UUID().uuidString).tmp", directoryHint: .notDirectory)
        do {
            try data.write(to: temporary)
            try? FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: temporary.path(percentEncoded: false))
            guard rename(temporary.path(percentEncoded: false), target.path(percentEncoded: false)) == 0 else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(errno))])
            }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    /// Folders a remote delete left empty, up to the project's own folder
    /// (an emptied skill's folder, not the project).
    private func removeEmptyFolders(above path: String) {
        var components = path.split(separator: "/").map(String.init)
        components.removeLast()
        while components.count > 1 {
            let folder = root.appending(path: components.joined(separator: "/"), directoryHint: .isDirectory)
            let contents = (try? FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))) ?? ["?"]
            guard contents.allSatisfy({ $0 == ".DS_Store" }), (try? FileManager.default.removeItem(at: folder)) != nil else { return }
            components.removeLast()
        }
    }

    /// Keeps a version in `.conflicts/<folders>/<name>-<date>-<hash>.<ext>`.
    /// The same content is stored once, however often it is archived.
    @discardableResult
    func archive(_ data: Data, at path: String, now: Date = .now) -> Bool {
        let fileManager = FileManager.default
        var components = path.split(separator: "/").map(String.init)
        let name = components.removeLast()
        var folder = root.appending(path: Self.conflictsDirectoryName, directoryHint: .isDirectory)
        for component in components {
            folder = folder.appending(path: component, directoryHint: .isDirectory)
        }
        let ext = (name as NSString).pathExtension
        let stem = ext.isEmpty ? name : String(name.dropLast(ext.count + 1))
        let suffix = ext.isEmpty ? "" : ".\(ext)"
        let digest = String(Self.hash(data).prefix(8))
        do {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            let existing = (try? fileManager.contentsOfDirectory(atPath: folder.path(percentEncoded: false))) ?? []
            if existing.contains(where: { $0.hasPrefix(stem + "-") && $0.hasSuffix("-\(digest)\(suffix)") }) { return true }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "UTC")
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            let file = folder.appending(
                path: "\(stem)-\(formatter.string(from: now))-\(digest)\(suffix)", directoryHint: .notDirectory)
            try data.write(to: file)
            Log.sync.notice("Kept a conflicting version of a knowledge file in .conflicts/")
            return true
        } catch {
            Log.sync.error("Could not keep a conflicting knowledge file: \(String(describing: error), privacy: .public)")
            return false
        }
    }
}

/// The hashes of the knowledge files by path, size and modification date,
/// so a scan reads only the files that changed. Kept by the app across
/// cycles; a new one reads every file once.
public final class KnowledgeFileHashes: @unchecked Sendable {
    private struct Entry {
        var size: Int
        var modified: Date
        var hash: String
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    public init() {}

    func hash(of path: String, size: Int, modified: Date) -> String? {
        lock.withLock {
            guard let entry = entries[path], entry.size == size, entry.modified == modified else { return nil }
            return entry.hash
        }
    }

    func set(_ hash: String, of path: String, size: Int, modified: Date) {
        lock.withLock { entries[path] = Entry(size: size, modified: modified, hash: hash) }
    }

    func keep(only paths: Set<String>) {
        lock.withLock { entries = entries.filter { paths.contains($0.key) } }
    }
}
