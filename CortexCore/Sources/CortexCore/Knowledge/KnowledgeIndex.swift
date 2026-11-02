import Foundation
import GRDB

/// The knowledge base's search index: an in-memory SQLite database with
/// FTS5, rebuilt from the files at every launch. No migrations, no key, no
/// second source of truth.
///
/// Titles weigh most, then tags, then a skill's description or a project's
/// summary, then the body. Every word must match as a prefix.
public final class KnowledgeIndex: Sendable {
    private let database: DatabaseQueue

    public init() throws {
        database = try DatabaseQueue()
        try database.write { db in
            try db.create(table: "item") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("path", .text).notNull().unique()
                t.column("project", .text).notNull().indexed()
                t.column("kind", .text).notNull()
                t.column("status", .text)
                t.column("title", .text).notNull()
                // Space-separated, for matching; `itemTag` for filtering.
                t.column("tags", .text).notNull()
                t.column("summary", .text).notNull()
                t.column("body", .text).notNull()
                t.column("updated", .double).notNull()
                // The file as read, so an item comes back exactly as parsed.
                t.column("source", .text).notNull()
                t.column("modified", .double).notNull()
            }
            try db.create(table: "itemTag") { t in
                t.belongsTo("item", onDelete: .cascade).notNull()
                t.column("tag", .text).notNull()
            }
            try db.create(table: "project") { t in
                t.primaryKey("id", .text)
                t.column("position", .integer).notNull()
                t.column("data", .blob).notNull()
            }
            try db.create(virtualTable: "itemFTS", using: FTS5()) { t in
                t.synchronize(withTable: "item")
                t.tokenizer = .unicode61(diacritics: .remove)
                t.column("title")
                t.column("tags")
                t.column("summary")
                t.column("body")
            }
        }
    }

    // MARK: - Writing

    /// Adds or replaces items (by path) and removes others, in one transaction.
    public func apply(upserting items: [KnowledgeItem], sources: [String: (text: String, modified: Date)], removing paths: [String]) throws {
        try database.write { db in
            for path in paths {
                try db.execute(sql: "DELETE FROM item WHERE path = ?", arguments: [path])
            }
            for item in items {
                guard let source = sources[item.path] else { continue }
                try db.execute(sql: "DELETE FROM item WHERE path = ?", arguments: [item.path])
                try db.execute(sql: """
                    INSERT INTO item (path, project, kind, status, title, tags, summary, body, updated, source, modified)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [
                        item.path, item.project, item.kind.rawValue, item.status?.rawValue, item.title,
                        item.tags.joined(separator: " "), item.summary ?? "", item.body,
                        item.updated.timeIntervalSinceReferenceDate, source.text, source.modified.timeIntervalSinceReferenceDate,
                    ])
                let id = db.lastInsertedRowID
                for tag in Set(item.tags) {
                    try db.execute(sql: "INSERT INTO itemTag (itemID, tag) VALUES (?, ?)", arguments: [id, tag])
                }
            }
        }
    }

    /// Replaces the project list, in this order.
    public func setProjects(_ projects: [KnowledgeProject]) throws {
        let encoder = JSONEncoder()
        try database.write { db in
            try db.execute(sql: "DELETE FROM project")
            for (position, project) in projects.enumerated() {
                try db.execute(
                    sql: "INSERT INTO project (id, position, data) VALUES (?, ?, ?)",
                    arguments: [project.id, position, try encoder.encode(StoredProject(project))])
            }
        }
    }

    // MARK: - Reading

    public func projects() throws -> [KnowledgeProject] {
        let decoder = JSONDecoder()
        return try database.read { db in
            try Data.fetchAll(db, sql: "SELECT data FROM project ORDER BY position")
        }.map { try decoder.decode(StoredProject.self, from: $0).project }
    }

    /// Items per project.
    public func counts() throws -> [String: Int] {
        try database.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT project, COUNT(*) AS count FROM item WHERE kind != 'project' GROUP BY project")
            return Dictionary(uniqueKeysWithValues: rows.map { ($0["project"] as String, $0["count"] as Int) })
        }
    }

    /// Open to-dos per project.
    public func openTodoCounts() throws -> [String: Int] {
        try database.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT project, COUNT(*) AS count FROM item WHERE kind = 'todo' AND status = 'open' GROUP BY project
                """)
            return Dictionary(uniqueKeysWithValues: rows.map { ($0["project"] as String, $0["count"] as Int) })
        }
    }

    /// Every tag with the number of items that have it, most used first.
    public func tags() throws -> [(tag: String, count: Int)] {
        try database.read { db in
            try Row.fetchAll(db, sql: "SELECT tag, COUNT(*) AS count FROM itemTag GROUP BY tag ORDER BY count DESC, tag")
                .map { ($0["tag"] as String, $0["count"] as Int) }
        }
    }

    /// The paths of every item of a kind, sorted.
    public func paths(of kind: KnowledgeKind) throws -> [String] {
        try database.read { db in
            try String.fetchAll(db, sql: "SELECT path FROM item WHERE kind = ? ORDER BY path", arguments: [kind.rawValue])
        }
    }

    public func count() throws -> Int {
        try database.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM item") ?? 0 }
    }

    public func item(at path: String) throws -> KnowledgeItem? {
        try database.read { db in
            try Row.fetchOne(db, sql: "SELECT path, source, modified FROM item WHERE path = ?", arguments: [path])
        }.flatMap(Self.item(from:))
    }

    /// Every path with the modification date it was indexed at.
    public func modificationDates() throws -> [String: Date] {
        try database.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT path, modified FROM item")
            return Dictionary(uniqueKeysWithValues: rows.map {
                ($0["path"] as String, Date(timeIntervalSinceReferenceDate: $0["modified"] as Double))
            })
        }
    }

    /// With words: best match first, with a snippet of the body. Without:
    /// most recently updated first.
    public func search(_ query: KnowledgeQuery, limit: Int = 50) throws -> [KnowledgeHit] {
        var conditions: [String] = []
        var arguments: StatementArguments = []

        if let prefix = query.project {
            let ids = try projects().filter { $0.matches(prefix: prefix) }.map(\.id)
            guard !ids.isEmpty else { return [] }
            conditions.append("item.project IN (\(ids.map { _ in "?" }.joined(separator: ", ")))")
            arguments += StatementArguments(ids)
        }
        if let id = query.projectID {
            conditions.append("item.project = ?")
            arguments += [id]
        }
        if let kinds = query.kinds {
            guard !kinds.isEmpty else { return [] }
            let kinds = kinds.map(\.rawValue).sorted()
            conditions.append("item.kind IN (\(kinds.map { _ in "?" }.joined(separator: ", ")))")
            arguments += StatementArguments(kinds)
        }
        if let status = query.status {
            conditions.append("item.status = ?")
            arguments += [status.rawValue]
        }
        for tag in query.tags {
            conditions.append("EXISTS (SELECT 1 FROM itemTag WHERE itemTag.itemID = item.id AND itemTag.tag LIKE ? ESCAPE '\\')")
            arguments += [Self.likePrefix(tag)]
        }

        let pattern = query.hasText ? FTS5Pattern(matchingAllPrefixesIn: query.text) : nil
        if query.hasText, pattern == nil { return [] }

        return try database.read { db in
            let rows: [Row]
            if let pattern {
                let filter = conditions.map { " AND " + $0 }.joined()
                rows = try Row.fetchAll(db, sql: """
                    SELECT item.path, item.source, item.modified, snippet(itemFTS, 3, '', '', '…', 12) AS snippet
                    FROM item JOIN itemFTS ON itemFTS.rowid = item.id
                    WHERE itemFTS MATCH ?\(filter)
                    ORDER BY bm25(itemFTS, 10.0, 5.0, 3.0, 1.0), item.updated DESC
                    LIMIT ?
                    """, arguments: [pattern] + arguments + [limit])
            } else {
                let filter = conditions.isEmpty ? "" : " WHERE " + conditions.joined(separator: " AND ")
                rows = try Row.fetchAll(db, sql: """
                    SELECT item.path, item.source, item.modified FROM item\(filter)
                    ORDER BY item.updated DESC LIMIT ?
                    """, arguments: arguments + [limit])
            }
            return rows.compactMap { row in
                Self.item(from: row).map { KnowledgeHit(item: $0, snippet: (row["snippet"] as String?).map(Self.oneLine)) }
            }
        }
    }

    /// Items that share any word with `text`, best match first: the
    /// candidates `$tidy` offers to merge an inbox note into.
    public func similar(
        to text: String, kinds: Set<KnowledgeKind>, excludingProject project: String, limit: Int
    ) throws -> [KnowledgeItem] {
        let words = text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).filter { $0.count >= 3 }.map(String.init)
        guard !kinds.isEmpty, let pattern = FTS5Pattern(matchingAnyTokenIn: words.joined(separator: " ")) else { return [] }
        let kinds = kinds.map(\.rawValue).sorted()
        return try database.read { db in
            try Row.fetchAll(db, sql: """
                SELECT item.path, item.source, item.modified
                FROM item JOIN itemFTS ON itemFTS.rowid = item.id
                WHERE itemFTS MATCH ? AND item.project <> ? AND item.kind IN (\(kinds.map { _ in "?" }.joined(separator: ", ")))
                ORDER BY bm25(itemFTS, 10.0, 5.0, 3.0, 1.0)
                LIMIT ?
                """, arguments: [pattern, project] + StatementArguments(kinds) + [limit])
                .compactMap(Self.item(from:))
        }
    }

    // MARK: - Helpers

    private static func item(from row: Row) -> KnowledgeItem? {
        KnowledgeItem.parse(
            path: row["path"], text: row["source"], modified: Date(timeIntervalSinceReferenceDate: row["modified"]))
    }

    private static func likePrefix(_ text: String) -> String {
        text.replacing("\\", with: "\\\\").replacing("%", with: "\\%").replacing("_", with: "\\_") + "%"
    }

    /// Whitespace and Markdown line starts collapsed into single spaces.
    static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private struct StoredProject: Codable {
        var id: String
        var name: String
        var summary: String?
        var symbol: String?
        var color: ProjectColor?
        var folders: [String]
        var about: String

        init(_ project: KnowledgeProject) {
            id = project.id
            name = project.name
            summary = project.summary
            symbol = project.symbol
            color = project.color
            folders = project.folders
            about = project.about
        }

        var project: KnowledgeProject {
            KnowledgeProject(id: id, name: name, summary: summary, symbol: symbol, color: color, folders: folders, about: about)
        }
    }
}
