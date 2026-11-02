import Foundation

/// Orders and searches the reading list for the palette. The list is small,
/// so this runs in memory.
public enum ReadingListSearch {
    /// Without a query: the unread links, newest first, then (if `includeRead`)
    /// the read ones, most recently read first. With one, every word must
    /// match the title, host, URL or note, and read links are always
    /// included: titles first, then hosts, then the rest.
    public static func rank(_ items: [ReadingItem], query: String, includeRead: Bool = true) -> [ReadingItem] {
        let words = query.split(whereSeparator: \.isWhitespace).map { SnippetSearch.fold(String($0)) }
        guard !words.isEmpty else {
            return items.filter { includeRead || !$0.isRead }.sorted(by: inListOrder)
        }
        let scored: [(ReadingItem, Int)] = items.compactMap { item in
            let fields = Fields(item)
            var total = 0
            for word in words {
                guard let score = fields.score(word) else { return nil }
                total += score
            }
            return (item, total)
        }
        return scored
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : inListOrder($0.0, $1.0) }
            .map(\.0)
    }

    /// Unread before read; unread by when they were added, read by when they
    /// were read, newest first.
    static func inListOrder(_ a: ReadingItem, _ b: ReadingItem) -> Bool {
        switch (a.readAt, b.readAt) {
        case (nil, nil): a.addedAt > b.addedAt
        case (nil, _?): true
        case (_?, nil): false
        case (let x?, let y?): x != y ? x > y : a.addedAt > b.addedAt
        }
    }

    private struct Fields {
        var title: String
        var titleWords: [Substring]
        var host: String
        var rest: String

        init(_ item: ReadingItem) {
            title = SnippetSearch.fold(item.title ?? "")
            titleWords = title.split { !$0.isLetter && !$0.isNumber }
            host = SnippetSearch.fold(item.host)
            rest = SnippetSearch.fold(item.url + "\n" + (item.note ?? ""))
        }

        /// nil: the word matches nowhere.
        func score(_ word: String) -> Int? {
            if title.hasPrefix(word) { return 100 }
            if titleWords.contains(where: { $0.hasPrefix(word) }) { return 80 }
            if title.contains(word) { return 60 }
            if host.hasPrefix(word) { return 50 }
            if host.contains(word) { return 40 }
            if rest.contains(word) { return 20 }
            return nil
        }
    }
}
