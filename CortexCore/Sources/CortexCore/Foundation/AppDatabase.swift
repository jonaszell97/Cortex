import Foundation
import GRDB

public enum AppDatabaseError: Error, CustomStringConvertible {
    /// A database file exists but the Keychain has no key for it.
    case keyMissing
    /// The key in the Keychain does not open the database.
    case cannotDecrypt(underlying: DatabaseError)
    case malformedKey(byteCount: Int)

    public var description: String {
        switch self {
        case .keyMissing:
            "The database exists but its encryption key is missing from the Keychain."
        case .cannotDecrypt(let underlying):
            "The database cannot be decrypted with the key from the Keychain (\(underlying.resultCode))."
        case .malformedKey(let byteCount):
            "The database key in the Keychain has \(byteCount) bytes instead of \(DatabaseKey.byteCount)."
        }
    }
}

/// The app's SQLCipher-encrypted SQLite database.
public final class AppDatabase: Sendable {
    public let writer: any DatabaseWriter
    public var reader: any DatabaseReader { writer }
    public let url: URL
    /// Encrypted payload files, in a `Blobs` directory next to the database.
    public let blobs: BlobStore

    private init(writer: any DatabaseWriter, url: URL, key: DatabaseKey) throws {
        self.writer = writer
        self.url = url
        self.blobs = BlobStore(
            directory: url.deletingLastPathComponent().appending(path: "Blobs", directoryHint: .isDirectory),
            databaseKey: key)
        try Self.migrator.migrate(writer)
    }

    /// Opens (or creates) the database in the app's data directory, with the
    /// key from the Keychain.
    public static func openDefault(secrets: some SecretStore = KeychainStore.app)throws -> AppDatabase {
        try open(at: try AppPaths.databaseURL(), secrets: secrets)
    }

    /// Opens (or creates) the database at `url`, with the key from `secrets`
    /// (created with the database). See `open(at:key:sharedContainer:)`.
    public static func open(at url: URL, secrets: some SecretStore, sharedContainer: Bool = false) throws -> AppDatabase {
        let exists = FileManager.default.fileExists(atPath: url.path)
        let key = try DatabaseKey.loadOrCreate(in: secrets, databaseExists: exists)
        return try open(at: url, key: key, sharedContainer: sharedContainer)
    }

    /// `sharedContainer` is for a database in an iOS App Group container.
    /// iOS kills an app that is suspended while it holds a lock on a file
    /// there (`0xdead10cc`), except SQLite's WAL locks, which it recognizes
    /// by the file's plaintext "SQLite format 3" header. SQLCipher encrypts
    /// that header too, so such a database keeps its first 32 bytes in the
    /// clear (`cipher_plaintext_header_size`; the salt comes from the key).
    /// A database with an encrypted header is converted on opening. It also
    /// observes GRDB's suspension notifications: see `suspend()`.
    public static func open(at url: URL, key: DatabaseKey, sharedContainer: Bool = false) throws -> AppDatabase {
        if sharedContainer { try convertToPlaintextHeader(at: url, key: key) }
        var config = Configuration()
        config.label = "Cortex"
        let passphrase = sharedContainer ? key.sqlCipherPassphraseWithSalt : key.sqlCipherPassphrase
        config.prepareDatabase { db in
            try db.usePassphrase(passphrase)
            if sharedContainer { try db.execute(sql: "PRAGMA cipher_plaintext_header_size = 32") }
        }
        config.observesSuspensionNotifications = sharedContainer

        do {
            let pool = try DatabasePool(path: url.path, configuration: config)
            let database = try AppDatabase(writer: pool, url: url, key: key)
            Log.database.info("Opened database at \(url.path, privacy: .public)")
            return database
        } catch let error as DatabaseError where error.resultCode == .SQLITE_NOTADB {
            throw AppDatabaseError.cannotDecrypt(underlying: error)
        }
    }

    /// The first bytes of a SQLite file whose header is in the clear.
    static let plaintextHeader = Data("SQLite format 3\0".utf8)

    static func hasPlaintextHeader(_ url: URL) throws -> Bool {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return try handle.read(upToCount: plaintextHeader.count) == plaintextHeader
    }

    /// Rewrites a database with an encrypted header into one with a
    /// plaintext header (`sqlcipher_export`), then swaps the files. Does
    /// nothing without a file, or for one that is already converted. The old
    /// file stays until the new one is complete, so an interruption leaves
    /// the old one in place, to be converted on the next opening.
    static func convertToPlaintextHeader(at url: URL, key: DatabaseKey) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path), try !hasPlaintextHeader(url) else { return }
        let converted = URL(filePath: url.path + ".converting")
        for file in [converted.path, converted.path + "-wal", converted.path + "-shm"] where fileManager.fileExists(atPath: file) {
            try fileManager.removeItem(atPath: file)
        }

        var config = Configuration()
        let passphrase = key.sqlCipherPassphrase
        config.prepareDatabase { db in try db.usePassphrase(passphrase) }
        do {
            let queue = try DatabaseQueue(path: url.path, configuration: config)
            try queue.writeWithoutTransaction { db in
                // Everything in the main file, so the old WAL can go.
                try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
                // The hex key has no quotes to escape.
                try db.execute(sql: "ATTACH DATABASE ? AS converted KEY \"\(key.sqlCipherPassphraseWithSalt)\"", arguments: [converted.path])
                try db.execute(sql: "PRAGMA converted.cipher_plaintext_header_size = 32")
                try db.execute(sql: "SELECT sqlcipher_export('converted')")
                try db.execute(sql: "DETACH DATABASE converted")
            }
            try queue.close()
        } catch let error as DatabaseError where error.resultCode == .SQLITE_NOTADB {
            throw AppDatabaseError.cannotDecrypt(underlying: error)
        }

        for suffix in ["-wal", "-shm"] where fileManager.fileExists(atPath: url.path + suffix) {
            try fileManager.removeItem(atPath: url.path + suffix)
        }
        _ = try fileManager.replaceItemAt(url, withItemAt: converted)
        Log.database.notice("Converted the database at \(url.path, privacy: .public) to a plaintext header")
    }

    // MARK: - Suspension

    /// Before the app is suspended: a database opened with `sharedContainer`
    /// takes no new write locks (writes fail with `SQLITE_ABORT` or
    /// `SQLITE_INTERRUPT`; reads go on, WAL locks are allowed), so iOS has
    /// no reason to kill the app. `resume()` when it is back. Both are GRDB
    /// notifications, so they reach every such database in the process.
    public func suspend() {
        NotificationCenter.default.post(name: Database.suspendNotification, object: self)
    }

    public func resume() {
        NotificationCenter.default.post(name: Database.resumeNotification, object: self)
    }

    /// Renames an unreadable database (and its WAL files) so a fresh one can
    /// be created. Nothing is deleted. Returns the new location.
    @discardableResult
    public static func moveAside(databaseAt url: URL, fileManager: FileManager = .default) throws -> URL {
        let stamp = Date.now.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))
            .replacing(":", with: "")
        let destination = url.deletingPathExtension()
            .appendingPathExtension("unreadable-\(stamp).sqlite")
        try fileManager.moveItem(at: url, to: destination)
        for suffix in ["-wal", "-shm"] {
            let sidecar = URL(filePath: url.path + suffix)
            if fileManager.fileExists(atPath: sidecar.path) {
                try fileManager.moveItem(at: sidecar, to: URL(filePath: destination.path + suffix))
            }
        }
        Log.database.notice("Moved unreadable database to \(destination.path, privacy: .public)")
        return destination
    }

    // MARK: - Schema

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1_metadata") { db in
            try db.create(table: "metadata") { t in
                t.primaryKey("key", .text)
                t.column("value", .text).notNull()
            }
            try db.execute(
                sql: "INSERT INTO metadata (key, value) VALUES ('createdAt', ?)",
                arguments: [Date.now.ISO8601Format()])
        }

        migrator.registerMigration("v2_clips") { db in
            try db.create(table: "clipItem") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("contentHash", .text).notNull().unique()
                t.column("kind", .text).notNull()
                t.column("preview", .text).notNull()
                t.column("plainText", .text)
                t.column("searchText", .text).notNull()
                t.column("isSensitive", .boolean).notNull().defaults(to: false)
                t.column("isPinned", .boolean).notNull().defaults(to: false)
                t.column("sourceBundleID", .text)
                t.column("sourceAppName", .text)
                t.column("byteSize", .integer).notNull()
                t.column("thumbnail", .blob)
                t.column("createdAt", .datetime).notNull()
                t.column("lastCopiedAt", .datetime).notNull().indexed()
            }
            try db.create(table: "clipRepresentation") { t in
                t.autoIncrementedPrimaryKey("id")
                t.belongsTo("clipItem", onDelete: .cascade).notNull()
                t.column("position", .integer).notNull()
                t.column("type", .text).notNull()
                t.column("data", .blob)
                t.column("blobID", .text)
                t.column("byteSize", .integer).notNull()
            }
            try db.create(virtualTable: "clipItemFTS", using: FTS5()) { t in
                t.synchronize(withTable: "clipItem")
                t.tokenizer = .unicode61(diacritics: .remove)
                t.column("searchText")
            }
        }

        migrator.registerMigration("v3_snippets") { db in
            try db.create(table: "snippet") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull().unique().collate(.nocase)
                t.column("keyword", .text).unique()
                t.column("body", .text).notNull()
                // JSON array of strings.
                t.column("tags", .text).notNull().defaults(to: "[]")
                t.column("usageCount", .integer).notNull().defaults(to: 0)
                t.column("lastUsedAt", .datetime)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
        }

        migrator.registerMigration("v4_sync", migrate: SyncSchema.migrate)
        migrator.registerMigration("v5_sync_synced", migrate: SyncSchema.migrateSynced)
        migrator.registerMigration("v6_sync_capped", migrate: SyncSchema.migrateCapped)
        migrator.registerMigration("v7_sync_authenticated", migrate: SyncSchema.migrateAuthenticated)

        migrator.registerMigration("v8_reading-list_items") { db in
            try db.create(table: "readingItem") { t in
                t.autoIncrementedPrimaryKey("id")
                // Normalized; also the sync key.
                t.column("url", .text).notNull().unique()
                t.column("title", .text)
                t.column("note", .text)
                t.column("sourceAppName", .text)
                t.column("addedAt", .datetime).notNull().indexed()
                t.column("readAt", .datetime)
            }
            try SyncSchema.migrateReadingList(db)
        }

        migrator.registerMigration("v9_clipboard_recognized-text") { db in
            try db.alter(table: "clipItem") { t in
                t.add(column: "recognizedText", .text)
            }
        }

        migrator.registerMigration("v10_sync_devices", migrate: SyncDevices.migrate)

        return migrator
    }

    // MARK: - Introspection

    public func appliedMigrations() throws -> [String] {
        try reader.read { db in try Self.migrator.appliedMigrations(db) }
    }

    public func cipherVersion() throws -> String? {
        try reader.read { db in try String.fetchOne(db, sql: "PRAGMA cipher_version") }
    }

    public func metadata(_ key: String) throws -> String? {
        try reader.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM metadata WHERE key = ?", arguments: [key])
        }
    }
}
