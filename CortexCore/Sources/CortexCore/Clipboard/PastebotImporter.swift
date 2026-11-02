#if os(macOS)
import Foundation
import GRDB

/// One-off import of Pastebot 2's history.
///
/// Pastebot keeps each pasteboard as a plain SQLite database in its group
/// container: `general.pastebot/sql` is the clipboard history, every other
/// `<UUID>.pastebot/sql` is a pasteboard the user saved items to. Their items
/// are imported pinned. (`log.sql` in the app container is only a debug log.)
///
/// Schema (Pastebot 2.x): `entries(uuid, created_at, copied_at, source_name,
/// source_bundle_identifier, item_count, …)` with Unix timestamps, and
/// `types_data(entry_uuid, item_index, type, data)` holding every pasteboard
/// type of every item.
public struct PastebotImporter: Sendable {
    public static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(
            path: "Library/Group Containers/9JTH7AWHE6.com.tapbots.Pastebot2Mac/Library/Application Support",
            directoryHint: .isDirectory)
    }

    public struct Pasteboard: Sendable {
        public var name: String
        public var isHistory: Bool
        public var snapshots: [ClipSnapshot]
    }

    public struct Report: Sendable, Equatable {
        public var inserted = 0
        public var alreadyPresent = 0
        public var skipped = 0
    }

    public let directory: URL

    public init(directory: URL = PastebotImporter.defaultDirectory) {
        self.directory = directory
    }

    /// Reads every pasteboard without changing anything.
    public func read() throws -> [Pasteboard] {
        let stores = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "pastebot" }
            .map { $0.appending(path: "sql") }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .sorted { $0.path < $1.path }
        return try stores.map(readPasteboard(at:))
    }

    public func importAll(_ pasteboards: [Pasteboard], into store: ClipStore, indexSensitive: Bool) throws -> Report {
        var report = Report()
        for pasteboard in pasteboards {
            for snapshot in pasteboard.snapshots {
                switch try store.record(snapshot, indexSensitive: indexSensitive, bumpExisting: false, pin: !pasteboard.isHistory) {
                case .inserted: report.inserted += 1
                case .bumped: report.alreadyPresent += 1
                case .skipped: report.skipped += 1
                }
            }
        }
        Log.logger("import").info("Pastebot import: \(report.inserted) new, \(report.alreadyPresent) present, \(report.skipped) skipped")
        return report
    }

    // MARK: - Reading one store

    private struct EntryRow: Decodable, FetchableRecord {
        var uuid: String
        var created_at: Double
        var copied_at: Double?
        var source_name: String?
        var source_bundle_identifier: String?
    }

    private struct TypeRow: Decodable, FetchableRecord {
        var entry_uuid: String
        var item_index: Int
        var type: String
        var data: Data?
    }

    func readPasteboard(at url: URL) throws -> Pasteboard {
        // Pastebot may be running and holds the database in WAL mode: read a
        // copy (with its -wal and -shm files) instead of the live file.
        let copy = FileManager.default.temporaryDirectory
            .appending(path: "pastebot-import-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: copy, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: copy) }
        for suffix in ["", "-wal", "-shm"] {
            let source = URL(filePath: url.path + suffix)
            if FileManager.default.fileExists(atPath: source.path) {
                try FileManager.default.copyItem(at: source, to: copy.appending(path: "sql" + suffix))
            }
        }

        // No passphrase: SQLCipher reads plain SQLite files as they are.
        let queue = try DatabaseQueue(path: copy.appending(path: "sql").path)
        defer { try? queue.close() }

        return try queue.read { db in
            let name = try String.fetchOne(db, sql: "SELECT name FROM pasteboard WHERE name IS NOT NULL AND name != '' LIMIT 1")
            let isHistory = url.deletingLastPathComponent().lastPathComponent == "general.pastebot"
            let entries = try EntryRow.fetchAll(db, sql: """
                SELECT uuid, created_at, copied_at, source_name, source_bundle_identifier
                FROM entries ORDER BY COALESCE(copied_at, created_at)
                """)
            let types = Dictionary(grouping: try TypeRow.fetchAll(db, sql: """
                SELECT entry_uuid, item_index, type, data FROM types_data ORDER BY entry_uuid, item_index, id
                """), by: \.entry_uuid)

            let snapshots = entries.map { entry in
                Self.snapshot(entry: entry, types: types[entry.uuid] ?? [])
            }
            return Pasteboard(name: isHistory ? "History" : (name ?? "Saved items"), isHistory: isHistory, snapshots: snapshots)
        }
    }

    private static func snapshot(entry: EntryRow, types: [TypeRow]) -> ClipSnapshot {
        var representations: [LoadedRepresentation] = []

        let fileURLs = types
            .filter { $0.type == ClipType.fileURL }
            .compactMap { $0.data.flatMap { String(data: $0, encoding: .utf8) }.flatMap(URL.init(string:)) }
        if !fileURLs.isEmpty {
            representations.append(ClipSnapshot.fileURLRepresentation(fileURLs))
        }

        let firstItem = types.filter { $0.item_index == 0 }
        for row in firstItem where row.type != ClipType.fileURL && ClipType.stored.contains(row.type) {
            if let data = row.data, !data.isEmpty {
                representations.append(LoadedRepresentation(type: row.type, data: data))
            }
        }
        // Older apps only provide UTF-16 text.
        if !representations.contains(where: { $0.type == ClipType.plainText }),
           let utf16 = firstItem.first(where: { $0.type == "public.utf16-external-plain-text" })?.data,
           let text = String(data: utf16, encoding: .utf16) {
            representations.append(LoadedRepresentation(type: ClipType.plainText, data: Data(text.utf8)))
        }

        let created = Date(timeIntervalSince1970: entry.created_at)
        return ClipSnapshot(
            representations: representations,
            plainText: nil,
            isSensitive: SensitivityRules.isSensitive(types: types.map(\.type), sourceBundleID: entry.source_bundle_identifier),
            sourceBundleID: entry.source_bundle_identifier,
            sourceAppName: entry.source_name,
            copiedAt: entry.copied_at.map(Date.init(timeIntervalSince1970:)) ?? created,
            createdAt: created)
    }
}
#endif
