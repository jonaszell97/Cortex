import Foundation
import GRDB
import Testing
@testable import CortexCore

@Suite struct AppDatabaseTests {
    let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appending(path: "CortexCoreTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    var databaseURL: URL { directory.appending(path: "test.sqlite") }

    @Test func createsEncryptedDatabaseWithMigrations() throws {
        let database = try AppDatabase.open(at: databaseURL, key: .generate())

        #expect(try database.appliedMigrations() == ["v1_metadata", "v2_clips", "v3_snippets", "v4_sync", "v5_sync_synced", "v6_sync_capped", "v7_sync_authenticated", "v8_reading-list_items", "v9_clipboard_recognized-text", "v10_sync_devices"])
        #expect(try database.metadata("createdAt") != nil)
        #expect(try database.cipherVersion()?.isEmpty == false)

        // A plaintext SQLite file starts with "SQLite format 3\0".
        let header = try FileHandle(forReadingFrom: databaseURL).read(upToCount: 16)
        #expect(header != Data("SQLite format 3\0".utf8))
    }

    @Test func reopensWithSameKey() throws {
        let key = DatabaseKey.generate()
        _ = try AppDatabase.open(at: databaseURL, key: key)
        let reopened = try AppDatabase.open(at: databaseURL, key: key)
        #expect(try reopened.appliedMigrations() == ["v1_metadata", "v2_clips", "v3_snippets", "v4_sync", "v5_sync_synced", "v6_sync_capped", "v7_sync_authenticated", "v8_reading-list_items", "v9_clipboard_recognized-text", "v10_sync_devices"])
    }

    @Test func rejectsWrongKey() throws {
        _ = try AppDatabase.open(at: databaseURL, key: .generate())
        #expect {
            try AppDatabase.open(at: databaseURL, key: .generate())
        } throws: { error in
            if case AppDatabaseError.cannotDecrypt = error { true } else { false }
        }
    }

    @Test func supportsFTS5() throws {
        let database = try AppDatabase.open(at: databaseURL, key: .generate())
        let matches = try database.writer.write { db in
            try db.create(virtualTable: "doc", using: FTS5()) { t in
                t.column("body")
            }
            try db.execute(sql: "INSERT INTO doc (body) VALUES ('clipboard history'), ('snippets')")
            return try String.fetchAll(db, sql: "SELECT body FROM doc WHERE doc MATCH 'clip*'")
        }
        #expect(matches == ["clipboard history"])
    }

    @Test func moveAsideKeepsOldFile() throws {
        _ = try AppDatabase.open(at: databaseURL, key: .generate())
        let moved = try AppDatabase.moveAside(databaseAt: databaseURL)
        #expect(!FileManager.default.fileExists(atPath: databaseURL.path))
        #expect(FileManager.default.fileExists(atPath: moved.path))
    }
}

/// Databases in an iOS App Group container. Serialized: suspending is a
/// notification that reaches every such database in the process.
@Suite(.serialized) struct SharedContainerDatabaseTests {
    let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appending(path: "CortexCoreTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    var databaseURL: URL { directory.appending(path: "test.sqlite") }

    func header(_ url: URL) throws -> Data? {
        try FileHandle(forReadingFrom: url).read(upToCount: 16)
    }

    @Test func aSharedContainerDatabaseHasAPlaintextHeaderAndStaysEncrypted() throws {
        let key = DatabaseKey.generate()
        do {
            let database = try AppDatabase.open(at: databaseURL, key: key, sharedContainer: true)
            try database.writer.write { db in
                try db.execute(sql: "INSERT INTO metadata (key, value) VALUES ('probe', 'secret value')")
            }
        }
        #expect(try header(databaseURL) == Data("SQLite format 3\0".utf8))
        let bytes = try Data(contentsOf: databaseURL) + ((try? Data(contentsOf: URL(filePath: databaseURL.path + "-wal"))) ?? Data())
        #expect(bytes.range(of: Data("secret value".utf8)) == nil)

        let reopened = try AppDatabase.open(at: databaseURL, key: key, sharedContainer: true)
        #expect(try reopened.metadata("probe") == "secret value")
        #expect {
            try AppDatabase.open(at: databaseURL, key: .generate(), sharedContainer: true).metadata("probe")
        } throws: { _ in true }
    }

    @Test func convertsADatabaseWithAnEncryptedHeaderKeepingItsData() throws {
        let key = DatabaseKey.generate()
        do {
            let database = try AppDatabase.open(at: databaseURL, key: key)
            try database.writer.write { db in
                try db.execute(sql: "INSERT INTO metadata (key, value) VALUES ('probe', 'kept')")
            }
            // Still open, so the write may sit in the WAL.
            try AppDatabase.convertToPlaintextHeader(at: databaseURL, key: key)
        }
        #expect(try header(databaseURL) == Data("SQLite format 3\0".utf8))
        #expect(!FileManager.default.fileExists(atPath: databaseURL.path + ".converting"))

        let converted = try AppDatabase.open(at: databaseURL, key: key, sharedContainer: true)
        #expect(try converted.metadata("probe") == "kept")
        #expect(try converted.appliedMigrations().contains("v8_reading-list_items"))
        // Opening again converts nothing.
        try AppDatabase.convertToPlaintextHeader(at: databaseURL, key: key)
        #expect(try converted.metadata("probe") == "kept")
    }

    @Test func convertingWithTheWrongKeyChangesNothing() throws {
        _ = try AppDatabase.open(at: databaseURL, key: .generate())
        let before = try Data(contentsOf: databaseURL)
        #expect {
            try AppDatabase.open(at: databaseURL, key: .generate(), sharedContainer: true)
        } throws: { error in
            if case AppDatabaseError.cannotDecrypt = error { true } else { false }
        }
        #expect(try Data(contentsOf: databaseURL).prefix(16) == before.prefix(16))
    }

    @Test func aSuspendedDatabaseRefusesWritesUntilResumed() throws {
        let database = try AppDatabase.open(at: databaseURL, key: .generate(), sharedContainer: true)
        database.suspend()
        #expect(throws: DatabaseError.self) {
            try database.writer.write { db in
                try db.execute(sql: "INSERT INTO metadata (key, value) VALUES ('probe', 'x')")
            }
        }
        #expect(try database.metadata("createdAt") != nil, "reads go on")
        database.resume()
        try database.writer.write { db in
            try db.execute(sql: "INSERT INTO metadata (key, value) VALUES ('probe', 'x')")
        }
    }
}

@Suite struct DatabaseKeyTests {
    final class MemoryStore: SecretStore, @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String: Data] = [:]

        func data(for account: String) throws -> Data? { lock.withLock { items[account] } }
        func set(_ data: Data, for account: String) throws { lock.withLock { items[account] = data } }
        func delete(_ account: String) throws { lock.withLock { items[account] = nil } }
    }

    @Test func createsKeyOnceAndReusesIt() throws {
        let store = MemoryStore()
        let first = try DatabaseKey.loadOrCreate(in: store, databaseExists: false)
        let second = try DatabaseKey.loadOrCreate(in: store, databaseExists: true)
        #expect(first.rawValue == second.rawValue)
        #expect(first.rawValue.count == 32)
    }

    @Test func refusesToReplaceKeyOfExistingDatabase() {
        #expect {
            try DatabaseKey.loadOrCreate(in: MemoryStore(), databaseExists: true)
        } throws: { error in
            if case AppDatabaseError.keyMissing = error { true } else { false }
        }
    }

    @Test func rawKeySyntax() throws {
        let key = try DatabaseKey(rawValue: Data(repeating: 0xAB, count: 32))
        #expect(key.sqlCipherPassphrase == "x'" + String(repeating: "AB", count: 32) + "'")
    }
}
