import Foundation

/// What is typed after `?`: words to search for, `@project` (the folder
/// name, the project's name or a prefix of either) and `#tag` (a prefix).
public struct KnowledgeQuery: Sendable, Equatable {
    public var text: String
    public var project: String?
    /// Exactly this project folder (not a prefix): for agents, which name
    /// projects by ID.
    public var projectID: String?
    public var tags: [String]
    /// nil: every kind.
    public var kinds: Set<KnowledgeKind>?
    public var status: TodoStatus?

    public init(
        text: String = "", project: String? = nil, projectID: String? = nil, tags: [String] = [], kinds: Set<KnowledgeKind>? = nil,
        status: TodoStatus? = nil
    ) {
        self.text = text
        self.project = project
        self.projectID = projectID
        self.tags = tags
        self.kinds = kinds
        self.status = status
    }

    /// `@server docker #cli` is "docker" in projects starting with "server",
    /// tagged with a tag starting with "cli". A lone `@` or `#` (being typed)
    /// is ignored; the last `@` wins.
    public static func parse(_ raw: String) -> KnowledgeQuery {
        var query = KnowledgeQuery()
        var words: [Substring] = []
        for word in raw.split(whereSeparator: \.isWhitespace) {
            if word.hasPrefix("@") {
                if word.count > 1 { query.project = word.dropFirst().lowercased() }
            } else if word.hasPrefix("#") {
                let tag = KnowledgeTag.normalize(String(word))
                if !tag.isEmpty { query.tags.append(tag) }
            } else {
                words.append(word)
            }
        }
        query.text = words.joined(separator: " ")
        return query
    }

    /// No words: listed by date rather than by match.
    public var hasText: Bool { !text.trimmingCharacters(in: .whitespaces).isEmpty }
}

/// A search result: the item and, for a text search, the part of its body
/// that matched.
public struct KnowledgeHit: Sendable, Equatable, Identifiable {
    public var item: KnowledgeItem
    /// One line around the match, `…` where it was cut.
    public var snippet: String?

    public var id: String { item.path }

    public init(item: KnowledgeItem, snippet: String? = nil) {
        self.item = item
        self.snippet = snippet
    }
}

extension KnowledgeProject {
    /// Whether `@prefix` picks this project.
    public func matches(prefix: String) -> Bool {
        let prefix = prefix.lowercased()
        return id.lowercased().hasPrefix(prefix) || name.lowercased().hasPrefix(prefix)
            || KnowledgeSlug.make(name).hasPrefix(prefix)
    }
}
