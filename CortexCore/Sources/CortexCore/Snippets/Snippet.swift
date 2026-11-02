import Foundation
import GRDB

/// A named text template, pasted from the palette or expanded from its
/// keyword. The body may contain placeholders, see `SnippetTemplate`.
public struct Snippet: Codable, Sendable, Identifiable, Hashable, FetchableRecord, MutablePersistableRecord {
    public var id: Int64?
    /// Unique, ignoring ASCII case.
    public var name: String
    /// Typed anywhere to expand the snippet (when keyword expansion is on).
    /// Unique, no whitespace; nil when the snippet has none.
    public var keyword: String?
    public var body: String
    public var tags: [String]
    public var usageCount: Int
    public var lastUsedAt: Date?
    public var createdAt: Date
    public var updatedAt: Date

    public static let databaseTableName = "snippet"

    public init(
        id: Int64? = nil,
        name: String,
        keyword: String? = nil,
        body: String,
        tags: [String] = [],
        usageCount: Int = 0,
        lastUsedAt: Date? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.keyword = keyword
        self.body = body
        self.tags = tags
        self.usageCount = usageCount
        self.lastUsedAt = lastUsedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    public var template: SnippetTemplate { SnippetTemplate(body) }

    /// Empty or whitespace-only keywords mean "no keyword".
    public static func normalizedKeyword(_ keyword: String?) -> String? {
        guard let trimmed = keyword?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    /// Tags trimmed, empty ones dropped, duplicates (ignoring case) removed.
    public static func normalizedTags(_ tags: [String]) -> [String] {
        var seen = Set<String>()
        return tags
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }
}
