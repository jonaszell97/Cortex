/// The last few characters typed, to spot snippet keywords. Lives only in
/// memory, is short, and is cleared whenever the cursor may have moved.
struct KeywordBuffer {
    static let minimumCapacity = 20

    private(set) var text = ""
    /// Characters kept; at least the longest keyword plus the one before it.
    private(set) var capacity = minimumCapacity
    /// Whether the start of `text` is a word boundary. True after a reset
    /// (nothing is known about what comes before), false once the buffer had
    /// to drop characters.
    private var startsAtBoundary = true

    mutating func setKeywords(_ keywords: some Collection<String>) {
        capacity = max(Self.minimumCapacity, (keywords.map(\.count).max() ?? 0) + 1)
        reset()
    }

    mutating func reset() {
        text = ""
        startsAtBoundary = true
    }

    mutating func type(_ characters: String) {
        text += characters
        if text.count > capacity {
            text = String(text.suffix(capacity))
            startsAtBoundary = false
        }
    }

    mutating func deleteBackward() {
        if !text.isEmpty { text.removeLast() }
    }

    /// The keyword the typed text ends with, if a word boundary comes before
    /// it (`;sig` expands after a space but not inside `foo;sig`). The
    /// longest one wins.
    func match(in keywords: some Collection<String>) -> String? {
        keywords
            .filter { !$0.isEmpty && text.hasSuffix($0) && isBoundary(beforeLast: $0.count) }
            .max { $0.count < $1.count }
    }

    private func isBoundary(beforeLast count: Int) -> Bool {
        guard let start = text.index(text.endIndex, offsetBy: -count, limitedBy: text.startIndex),
              start > text.startIndex
        else { return startsAtBoundary }
        let before = text[text.index(before: start)]
        return !before.isLetter && !before.isNumber
    }
}
