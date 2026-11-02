import Foundation

/// Ranks snippets for the palette: fuzzy on name and keyword, plain
/// substring on tags and body. Snippets are few, so this runs in memory.
public enum SnippetSearch {
    /// Every word of the query must match somewhere. Without a query, the
    /// most used snippets come first.
    public static func rank(_ snippets: [Snippet], query: String) -> [Snippet] {
        let words = query.split(whereSeparator: \.isWhitespace).map { fold(String($0)) }
        guard !words.isEmpty else {
            return snippets.sorted(by: byUsage)
        }
        let scored: [(Snippet, Int)] = snippets.compactMap { snippet in
            let fields = Fields(snippet)
            var total = 0
            for word in words {
                guard let score = fields.score(word) else { return nil }
                total += score
            }
            return (snippet, total)
        }
        return scored
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : byUsage($0.0, $1.0) }
            .map(\.0)
    }

    private static func byUsage(_ a: Snippet, _ b: Snippet) -> Bool {
        if a.usageCount != b.usageCount { return a.usageCount > b.usageCount }
        if a.lastUsedAt != b.lastUsedAt { return (a.lastUsedAt ?? .distantPast) > (b.lastUsedAt ?? .distantPast) }
        return a.name.localizedStandardCompare(b.name) == .orderedAscending
    }

    /// Case, accents and width ignored, for search and triggers.
    public static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    private struct Fields {
        var name: String
        var nameWords: [Substring]
        /// The keyword, and the keyword without leading punctuation (`;sig`
        /// is found by typing `sig`).
        var keywords: [String]
        var tags: [String]
        var body: String

        init(_ snippet: Snippet) {
            name = fold(snippet.name)
            nameWords = name.split { !$0.isLetter && !$0.isNumber }
            if let keyword = snippet.keyword.map(fold) {
                let bare = String(keyword.drop { !$0.isLetter && !$0.isNumber })
                keywords = bare.isEmpty || bare == keyword ? [keyword] : [keyword, bare]
            } else {
                keywords = []
            }
            tags = snippet.tags.map(fold)
            body = fold(snippet.body)
        }

        func score(_ word: String) -> Int? {
            if keywords.contains(word) { return 100 }
            if keywords.contains(where: { $0.hasPrefix(word) }) { return 80 }
            if name.hasPrefix(word) { return 70 }
            if nameWords.contains(where: { $0.hasPrefix(word) }) { return 60 }
            if tags.contains(where: { $0.hasPrefix(word) }) { return 50 }
            if name.contains(word) { return 40 }
            if isSubsequence(word, of: name) { return 30 }
            if body.contains(word) { return 10 }
            return nil
        }

        private func isSubsequence(_ word: String, of text: String) -> Bool {
            var remaining = word[...]
            for character in text where character == remaining.first {
                remaining.removeFirst()
                if remaining.isEmpty { return true }
            }
            return remaining.isEmpty
        }
    }
}
