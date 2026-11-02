#if os(macOS)
import Foundation
import GRDB
import Testing
@testable import CortexCore

@Suite struct PastebotImporterTests {
    let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appending(path: "PastebotFixture-\(UUID().uuidString)", directoryHint: .isDirectory)
        try makeStore(
            "general.pastebot", pasteboardName: "",
            entries: [
                ("A", 1_788_000_000, 1_788_000_100, "Safari", "com.apple.Safari", [
                    (0, ClipType.plainText, Data("hello from pastebot".utf8)),
                    (0, ClipType.html, Data("<b>hello</b>".utf8)),
                    (0, "com.apple.webarchive", Data(repeating: 1, count: 100)),
                ]),
                ("B", 1_788_000_200, nil, "Finder", "com.apple.finder", [
                    (0, ClipType.fileURL, Data("file:///tmp/one.txt".utf8)),
                    (1, ClipType.fileURL, Data("file:///tmp/two.txt".utf8)),
                    (0, ClipType.plainText, Data("one.txt".utf8)),
                ]),
                ("C", 1_788_000_300, nil, "Legacy", nil, [
                    (0, "public.utf16-external-plain-text", "utf16 text".data(using: .utf16)!),
                ]),
                ("D", 1_788_000_400, nil, "1Password", "com.1password.1password", [
                    (0, ClipType.plainText, Data("s3cret".utf8)),
                ]),
                ("E", 1_788_000_500, nil, "Odd", nil, [
                    (0, "com.apple.webarchive", Data(repeating: 2, count: 10)),
                ]),
            ])
        try makeStore(
            "5E0173D0-CA23-4F91-92A5-1EE5CEFC2C97.pastebot", pasteboardName: "Helpful Things",
            entries: [
                ("F", 1_672_988_523, 1_672_988_580, "Notes", "com.apple.Notes", [
                    (0, ClipType.plainText, Data("saved snippet".utf8)),
                ]),
            ])
    }

    typealias Entry = (uuid: String, created: Double, copied: Double?, sourceName: String?, bundleID: String?,
                       types: [(index: Int, type: String, data: Data)])

    /// Writes a database with Pastebot 2's schema.
    func makeStore(_ folder: String, pasteboardName: String, entries: [Entry]) throws {
        let folderURL = directory.appending(path: folder, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        let queue = try DatabaseQueue(path: folderURL.appending(path: "sql").path)
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE pasteboard (name TEXT, entry_uuids TEXT);
                CREATE TABLE entries (uuid TEXT PRIMARY KEY NOT NULL, version INTEGER NOT NULL, created_at DATETIME NOT NULL,
                    copied_at DATETIME, hash INTEGER NOT NULL, title TEXT, source_name TEXT, source_bundle_identifier TEXT,
                    item_count UNSIGNED INT NOT NULL);
                CREATE TABLE types_data (id INTEGER PRIMARY KEY NOT NULL, entry_uuid TEXT NOT NULL, item_index INTEGER NOT NULL,
                    type TEXT NOT NULL, data BLOB);
                """)
            try db.execute(sql: "INSERT INTO pasteboard (name, entry_uuids) VALUES (?, '')", arguments: [pasteboardName])
            for entry in entries {
                try db.execute(sql: """
                    INSERT INTO entries (uuid, version, created_at, copied_at, hash, source_name, source_bundle_identifier, item_count)
                    VALUES (?, 1, ?, ?, 0, ?, ?, 1)
                    """, arguments: [entry.uuid, entry.created, entry.copied, entry.sourceName, entry.bundleID])
                for type in entry.types {
                    try db.execute(
                        sql: "INSERT INTO types_data (entry_uuid, item_index, type, data) VALUES (?, ?, ?, ?)",
                        arguments: [entry.uuid, type.index, type.type, type.data])
                }
            }
        }
        try queue.close()
    }

    @Test func readsHistoryAndSavedPasteboards() throws {
        let pasteboards = try PastebotImporter(directory: directory).read()
        let history = try #require(pasteboards.first { $0.isHistory })
        let saved = try #require(pasteboards.first { !$0.isHistory })

        #expect(history.snapshots.count == 5)
        #expect(saved.name == "Helpful Things")
        #expect(saved.snapshots.count == 1)

        let text = try #require(history.snapshots.first { $0.sourceAppName == "Safari" })
        #expect(text.representations.map(\.type) == [ClipType.html, ClipType.plainText])
        #expect(text.copiedAt == Date(timeIntervalSince1970: 1_788_000_100))
        #expect(text.createdAt == Date(timeIntervalSince1970: 1_788_000_000))

        let files = try #require(history.snapshots.first { $0.sourceAppName == "Finder" })
        #expect(files.kind == .files)
        #expect(files.fileURLs.map(\.path) == ["/tmp/one.txt", "/tmp/two.txt"])

        #expect(history.snapshots.first { $0.sourceAppName == "Legacy" }?.plainText == "utf16 text")
        #expect(history.snapshots.first { $0.sourceAppName == "1Password" }?.isSensitive == true)
        #expect(history.snapshots.first { $0.sourceAppName == "Odd" }?.isEmpty == true)
    }

    @Test func importsOnceAndPinsSavedItems() async throws {
        let store = ClipStore(database: try makeTestDatabase())
        let importer = PastebotImporter(directory: directory)

        let first = try importer.importAll(importer.read(), into: store, indexSensitive: true)
        #expect(first == .init(inserted: 5, alreadyPresent: 0, skipped: 1))

        let second = try importer.importAll(importer.read(), into: store, indexSensitive: true)
        #expect(second == .init(inserted: 0, alreadyPresent: 5, skipped: 1))

        let summaries = try await store.summaries()
        #expect(summaries.count == 5)
        #expect(summaries.filter(\.isPinned).map(\.preview) == ["saved snippet"])
        #expect(summaries.first?.preview == "s3cret") // newest copy first
    }
}
#endif
