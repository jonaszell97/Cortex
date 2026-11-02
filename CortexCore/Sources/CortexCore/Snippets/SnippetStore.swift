import Foundation
import GRDB

public enum SnippetStoreError: Error, Equatable, CustomStringConvertible, LocalizedError {
    case emptyName
    case duplicateName(String)
    case keywordContainsWhitespace(String)
    case duplicateKeyword(String, usedBy: String)

    public var description: String {
        switch self {
        case .emptyName:
            "A snippet needs a name."
        case .duplicateName(let name):
            "There is already a snippet named “\(name)”."
        case .keywordContainsWhitespace(let keyword):
            "The keyword “\(keyword)” contains a space; keywords are a single word."
        case .duplicateKeyword(let keyword, let usedBy):
            "The keyword “\(keyword)” is already used by “\(usedBy)”."
        }
    }

    public var errorDescription: String? { description }
}

/// Snippet storage on top of `AppDatabase`. Like `ClipStore`, the
/// synchronous methods block on the database; call them off the main actor.
public final class SnippetStore: Sendable {
    let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    // MARK: - Reading

    /// All snippets, by name.
    public func all() async throws -> [Snippet] {
        try await database.reader.read { db in
            try Snippet.order(sql: "name COLLATE NOCASE").fetchAll(db)
        }
    }

    public func snippet(id: Int64) async throws -> Snippet? {
        try await database.reader.read { db in try Snippet.fetchOne(db, key: id) }
    }

    /// Keyword → snippet ID, for keyword expansion.
    public func keywords() async throws -> [String: Int64] {
        try await database.reader.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT keyword, id FROM snippet WHERE keyword IS NOT NULL")
            return Dictionary(rows.map { ($0["keyword"], $0["id"]) }, uniquingKeysWith: { first, _ in first })
        }
    }

    public func count() async throws -> Int {
        try await database.reader.read { db in try Snippet.fetchCount(db) }
    }

    // MARK: - Editing

    /// Inserts a new snippet or updates an existing one (by ID). Name,
    /// keyword and tags are normalized first.
    @discardableResult
    public func save(_ snippet: Snippet, now: Date = .now) throws -> Snippet {
        try database.writer.write { db in try Self.save(snippet, now: now, db: db) }
    }

    /// Trims and normalizes name, keyword and tags, and rejects what can never
    /// be stored (no name, a keyword with whitespace). Shared by local edits
    /// and snippets arriving from the other Mac.
    static func normalized(_ snippet: Snippet) throws -> Snippet {
        var snippet = snippet
        snippet.name = snippet.name.trimmingCharacters(in: .whitespacesAndNewlines)
        snippet.keyword = Snippet.normalizedKeyword(snippet.keyword)
        snippet.tags = Snippet.normalizedTags(snippet.tags)
        guard !snippet.name.isEmpty else { throw SnippetStoreError.emptyName }
        if let keyword = snippet.keyword, keyword.contains(where: \.isWhitespace) {
            throw SnippetStoreError.keywordContainsWhitespace(keyword)
        }
        return snippet
    }

    static func save(_ snippet: Snippet, now: Date, db: Database) throws -> Snippet {
        var snippet = try normalized(snippet)

        if let keyword = snippet.keyword {
            if let other = try String.fetchOne(db, sql: "SELECT name FROM snippet WHERE keyword = ? AND id IS NOT ?",
                                               arguments: [keyword, snippet.id]) {
                throw SnippetStoreError.duplicateKeyword(keyword, usedBy: other)
            }
        }
        if let other = try String.fetchOne(db, sql: "SELECT name FROM snippet WHERE name = ? COLLATE NOCASE AND id IS NOT ?",
                                           arguments: [snippet.name, snippet.id]) {
            throw SnippetStoreError.duplicateName(other)
        }

        snippet.updatedAt = now
        if snippet.id == nil {
            snippet.createdAt = now
            try snippet.insert(db)
        } else {
            try snippet.update(db)
        }
        return snippet
    }

    public func delete(id: Int64) throws {
        _ = try database.writer.write { db in try Snippet.deleteOne(db, key: id) }
    }

    /// Counts a paste or an expansion.
    public func markUsed(id: Int64, at date: Date = .now) throws {
        try database.writer.write { db in
            try db.execute(sql: "UPDATE snippet SET usageCount = usageCount + 1, lastUsedAt = ? WHERE id = ?",
                           arguments: [date, id])
        }
    }

    /// Runs several edits in one transaction (imports).
    func write<T>(_ updates: (Database) throws -> T) throws -> T {
        try database.writer.write(updates)
    }
}
