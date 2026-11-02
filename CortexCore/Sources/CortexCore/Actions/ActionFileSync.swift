import CryptoKit
import Foundation
import GRDB

enum ActionSyncError: Error, CustomStringConvertible {
    case malformed(String)

    var description: String {
        switch self {
        case .malformed(let reason): "malformed action payload: \(reason)"
        }
    }
}

/// User-defined quick actions for the sync engine (docs/SYNC.md, "Handling per
/// data type"): every `*.toml` file at the top level of the actions folder. The
/// record key is the file name and `syncRecord.fileHash` is the SHA-256 of the
/// content last synced. `QuickActionService` is untouched: the files are written
/// atomically and its `DirectoryWatcher` reloads them.
///
/// The losing version of a conflict, and every file a remote delete takes away,
/// goes to `.conflicts/` in the same folder, which the loader doesn't read.
public struct ActionFileSync: SyncEntityHandler {
    public static let maxFileBytes = 64 * 1024
    public static let conflictsDirectoryName = ".conflicts"

    public var entity: SyncCollection { .action }
    public var supportedVersion: Int { ActionFilePayload.version }

    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    // MARK: - Names and hashes

    /// A plain `*.toml` file name: no path, nothing hidden. Remote names are
    /// checked with this before anything is written.
    static func isValidFileName(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.count <= 255 && !name.hasPrefix(".")
            && !name.contains("/") && !name.contains("\0") && !name.contains(":")
            && name.lowercased().hasSuffix(".toml") && name.count > ".toml".count
    }

    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func url(of name: String) -> URL {
        directory.appending(path: name, directoryHint: .notDirectory)
    }

    // MARK: - Scanning (before each cycle)

    private struct LocalFile {
        var hash: String
        var modifiedAt: Date
    }

    /// Reads the folder: the files that can sync, and the names of every
    /// `*.toml` that is there (a file that is too large or not UTF-8 stays
    /// local but must not look deleted).
    private func readFolder() -> (syncable: [String: LocalFile], present: Set<String>) {
        let fileManager = FileManager.default
        let entries = (try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey])) ?? []
        var syncable: [String: LocalFile] = [:]
        var present = Set<String>()
        for entry in entries {
            let name = entry.lastPathComponent
            guard Self.isValidFileName(name) else { continue }
            let values = try? entry.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey])
            guard values?.isRegularFile == true else { continue }
            present.insert(name)
            guard let size = values?.fileSize, size <= Self.maxFileBytes,
                  let data = try? Data(contentsOf: entry), String(data: data, encoding: .utf8) != nil
            else {
                Log.sync.notice("Action file \(name, privacy: .private) is too large or not UTF-8; it stays local")
                continue
            }
            syncable[name] = LocalFile(hash: Self.hash(data), modifiedAt: values?.contentModificationDate ?? .now)
        }
        return (syncable, present)
    }

    /// Compares the folder with the `syncRecord` rows: a new or changed file
    /// is a pending write, a file that's gone is a tombstone (docs/SYNC.md, "The
    /// sync cycle", "Scan files"). A changed file is stamped with its
    /// modification date, so the edit that was made last wins even if this Mac
    /// only notices it later.
    public func beforeCycle(database: AppDatabase) async throws {
        let (files, present) = readFolder()
        let now = Date.now
        try await database.writer.write { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT localKey, deleted, fileHash FROM syncRecord WHERE entity = 'action'
                """)
            var known: [String: (deleted: Bool, fileHash: String?)] = [:]
            for row in rows {
                known[row["localKey"]] = (row["deleted"], row["fileHash"])
            }

            for (name, file) in files {
                if let row = known[name], !row.deleted, row.fileHash == file.hash { continue }
                try db.execute(sql: """
                    INSERT INTO syncRecord (entity, localKey, modifiedAt, pending, deleted, device, fileHash)
                    VALUES ('action', ?, ?, 1, 0, NULL, ?)
                    ON CONFLICT (entity, localKey) DO UPDATE SET
                      modifiedAt = \(SyncSchema.capped("max(excluded.modifiedAt, syncRecord.modifiedAt + 1)")),
                      pending = 1, deleted = 0, device = NULL, fileHash = excluded.fileHash
                    """, arguments: [name, min(file.modifiedAt, now).syncMilliseconds, file.hash])
            }
            for (name, row) in known where !row.deleted && !present.contains(name) {
                try db.execute(sql: """
                    UPDATE syncRecord SET
                      modifiedAt = \(SyncSchema.capped("max(\(SyncSchema.nowMs), modifiedAt + 1)")), pending = 1, deleted = 1, device = NULL
                    WHERE entity = 'action' AND localKey = ?
                    """, arguments: [name])
            }
        }
    }

    // MARK: - Outgoing

    public func outgoing(localKey: String, key: SyncKey, database: AppDatabase) async throws -> SyncOutgoing? {
        guard Self.isValidFileName(localKey),
              let data = try? Data(contentsOf: url(of: localKey)), data.count <= Self.maxFileBytes,
              let contents = String(data: data, encoding: .utf8)
        else { return nil }
        let payload = ActionFilePayload(v: ActionFilePayload.version, fileName: localKey, contents: contents)
        return SyncOutgoing(payload: try JSONEncoder().encode(payload))
    }

    // MARK: - Incoming

    public func prepare(payload: Data, blobs: SyncBlobSource) async throws -> SyncPreparedRecord {
        let remote = try JSONDecoder().decode(ActionFilePayload.self, from: payload)
        guard Self.isValidFileName(remote.fileName) else { throw ActionSyncError.malformed("bad file name") }
        let data = Data(remote.contents.utf8)
        guard data.count <= Self.maxFileBytes else { throw ActionSyncError.malformed("file too large") }
        let name = remote.fileName
        let remoteHash = Self.hash(data)
        let sync = self

        return SyncPreparedRecord(
            localKey: name,
            superseded: { db, write in
                // The local version won. Keep the remote one, unless this is
                // only our own record coming back.
                guard let deviceID = try? SyncState.read(db).deviceID, write.device != deviceID,
                      let local = try? Data(contentsOf: sync.url(of: name)), Self.hash(local) != remoteHash
                else { return }
                sync.archive(data, named: name)
            },
            apply: { db, _ in
                let row = try Row.fetchOne(db, sql: """
                    SELECT fileHash, pending FROM syncRecord WHERE entity = 'action' AND localKey = ?
                    """, arguments: [name])
                let existing = try? Data(contentsOf: sync.url(of: name))
                if let local = existing, Self.hash(local) != remoteHash {
                    // Unpushed local changes (or a file that was never synced)
                    // lose against the newer remote write; keep them.
                    let localHash = Self.hash(local)
                    let syncedHash: String? = row?["fileHash"]
                    let pending: Bool = row?["pending"] ?? false
                    if row == nil || syncedHash != localHash || pending {
                        sync.archive(local, named: name)
                    }
                    try sync.write(data, named: name)
                } else if existing == nil {
                    try sync.write(data, named: name)
                }
                try db.execute(sql: """
                    INSERT INTO syncRecord (entity, localKey, modifiedAt, pending, deleted, device, fileHash)
                    VALUES ('action', ?, ?, 0, 0, NULL, ?)
                    ON CONFLICT (entity, localKey) DO UPDATE SET fileHash = excluded.fileHash
                    """, arguments: [name, 0, remoteHash])
                return .applied
            })
    }

    /// A remote delete: the file moves to `.conflicts/` instead of vanishing,
    /// because actions are written by hand.
    public func applyDeletion(localKey: String, in db: Database) throws {
        guard Self.isValidFileName(localKey), let local = try? Data(contentsOf: url(of: localKey)) else { return }
        archive(local, named: localKey)
        try FileManager.default.removeItem(at: url(of: localKey))
    }

    // MARK: - Files

    /// Writes to a temporary file in the folder and renames it over the
    /// target, so a reader sees the old or the new content, never half.
    private func write(_ data: Data, named name: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appending(path: ".sync-\(UUID().uuidString).tmp", directoryHint: .notDirectory)
        do {
            try data.write(to: temporary)
            guard rename(temporary.path, url(of: name).path) == 0 else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(errno))])
            }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    /// Keeps a version in `.conflicts/<name>-<date>-<hash>.toml`. The same
    /// content is stored once, however often it is archived.
    @discardableResult
    func archive(_ data: Data, named name: String, now: Date = .now) -> Bool {
        let fileManager = FileManager.default
        let conflicts = directory.appending(path: Self.conflictsDirectoryName, directoryHint: .isDirectory)
        let stem = String(name.dropLast(".toml".count))
        let digest = String(Self.hash(data).prefix(8))
        do {
            try fileManager.createDirectory(at: conflicts, withIntermediateDirectories: true)
            let existing = (try? fileManager.contentsOfDirectory(atPath: conflicts.path)) ?? []
            if existing.contains(where: { $0.hasPrefix(stem + "-") && $0.hasSuffix("-\(digest).toml") }) { return true }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "UTC")
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            let file = conflicts.appending(path: "\(stem)-\(formatter.string(from: now))-\(digest).toml", directoryHint: .notDirectory)
            try data.write(to: file)
            Log.sync.notice("Kept a conflicting version of an action in .conflicts/")
            return true
        } catch {
            Log.sync.error("Could not keep a conflicting action version: \(String(describing: error), privacy: .public)")
            return false
        }
    }
}
