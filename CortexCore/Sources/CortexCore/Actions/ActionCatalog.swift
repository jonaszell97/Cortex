import Foundation

/// How often and how recently an action ran; the palette lists the usual
/// ones first.
public struct ActionUsage: Codable, Sendable, Equatable {
    public var count: Int
    public var lastUsedAt: Date

    public init(count: Int = 0, lastUsedAt: Date = .distantPast) {
        self.count = count
        self.lastUsedAt = lastUsedAt
    }
}

public enum ActionCatalog {
    /// The built-in actions: text, then files. The built-in commands are
    /// `CommandCatalog.builtIns` (`>` offers some through `CommandAction`).
    public static var builtIns: [any QuickAction] {
        #if os(macOS)
        TextAction.all + FileAction.all
        #else
        TextAction.all
        #endif
    }

    /// The actions that take `input`, ranked for `query`: every word must
    /// match the title, a keyword or a command's name. Without a query, the most
    /// used first, then in catalog order.
    public static func rank(
        _ actions: [any QuickAction],
        for input: ActionInput,
        query: String,
        usage: [String: ActionUsage] = [:]
    ) -> [any QuickAction] {
        rank(actions.filter { $0.accepts(input) }, query: query, usage: usage)
    }

    /// `actions` ranked for `query`, whatever their input.
    public static func rank(_ actions: [any QuickAction], query: String, usage: [String: ActionUsage]) -> [any QuickAction] {
        rank(actions, query: query, usage: usage) { action in
            Searchable(id: action.id, title: action.title, keywords: action.keywords, name: (action as? CommandAction)?.command.name)
        }
    }

    /// What ranking looks at: the words an item is found by.
    struct Searchable {
        var id: String
        var title: String
        var keywords: [String]
        /// A command's name.
        var name: String?
    }

    /// `items` ranked for `query`: the best match first, then the most used,
    /// then the most recent, then in the order given.
    static func rank<Item>(_ items: [Item], query: String, usage: [String: ActionUsage], searchable: (Item) -> Searchable) -> [Item] {
        let candidates = items.enumerated()
        let words = query.split(whereSeparator: \.isWhitespace).map { SnippetSearch.fold(String($0)) }

        let scored: [(offset: Int, item: Item, id: String, score: Int)] = candidates.compactMap { offset, item in
            let searchable = searchable(item)
            var total = 0
            for word in words {
                guard let score = score(word, for: searchable) else { return nil }
                total += score
            }
            return (offset, item, searchable.id, total)
        }
        return scored.sorted { a, b in
            if a.score != b.score { return a.score > b.score }
            let usageA = usage[a.id] ?? ActionUsage()
            let usageB = usage[b.id] ?? ActionUsage()
            if usageA.count != usageB.count { return usageA.count > usageB.count }
            if usageA.lastUsedAt != usageB.lastUsedAt { return usageA.lastUsedAt > usageB.lastUsedAt }
            return a.offset < b.offset
        }.map(\.item)
    }

    private static func score(_ word: String, for item: Searchable) -> Int? {
        let title = SnippetSearch.fold(item.title)
        let titleWords = title.split { !$0.isLetter && !$0.isNumber }
        let keywords = item.keywords.map(SnippetSearch.fold)
        let name = item.name.map { SnippetSearch.fold($0) }
        // `$kill` is Kill Process, even though Kill Process on Port has the
        // keyword too.
        if name == word { return 110 }
        if titleWords.contains(where: { $0 == word }) || keywords.contains(word) { return 100 }
        if title.hasPrefix(word) { return 80 }
        if name?.hasPrefix(word) == true { return 70 }
        if titleWords.contains(where: { $0.hasPrefix(word) }) { return 60 }
        if keywords.contains(where: { $0.hasPrefix(word) }) { return 50 }
        if title.contains(word) { return 30 }
        if isSubsequence(word, of: title) { return 10 }
        return nil
    }

    private static func isSubsequence(_ word: String, of text: String) -> Bool {
        var remaining = word[...]
        for character in text where character == remaining.first {
            remaining.removeFirst()
            if remaining.isEmpty { return true }
        }
        return remaining.isEmpty
    }
}
