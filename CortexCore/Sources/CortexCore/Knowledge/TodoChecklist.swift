import Foundation

/// A to-do's checklist: the Markdown task list in its body (`- [ ] …`,
/// `- [x] …`), which every editor and agent already understands.
public struct TodoChecklist: Sendable, Equatable {
    public struct Item: Sendable, Equatable {
        /// The line in the body, 0-based.
        public var line: Int
        public var text: String
        public var isDone: Bool
    }

    public var items: [Item]

    public init(body: String) {
        items = body.split(separator: "\n", omittingEmptySubsequences: false).enumerated().compactMap { index, line in
            guard let match = Self.match(line) else { return nil }
            return Item(line: index, text: match.text, isDone: match.isDone)
        }
    }

    public var isEmpty: Bool { items.isEmpty }
    public var doneCount: Int { items.count { $0.isDone } }

    /// The body with the item at `index` ticked or unticked; the rest of the
    /// text is left exactly as it was.
    public static func toggling(itemAt index: Int, in body: String) -> String {
        let checklist = TodoChecklist(body: body)
        guard checklist.items.indices.contains(index) else { return body }
        let item = checklist.items[index]
        var lines = body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let line = lines[item.line]
        guard let open = line.firstIndex(of: "[") else { return body }
        let mark = line.index(after: open)
        lines[item.line] = line.replacingCharacters(in: mark...mark, with: item.isDone ? " " : "x")
        return lines.joined(separator: "\n")
    }

    /// The body with `text` added as an open item after the last one (or at
    /// the end).
    public static func adding(_ text: String, to body: String) -> String {
        let entry = "- [ ] \(text)"
        let checklist = TodoChecklist(body: body)
        var lines = body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if let last = checklist.items.last {
            lines.insert(entry, at: last.line + 1)
            return lines.joined(separator: "\n")
        }
        let trimmed = body.trimmingCharacters(in: .newlines)
        return trimmed.isEmpty ? entry + "\n" : trimmed + "\n\n" + entry + "\n"
    }

    /// The body with its task list replaced by `items`: the new list goes
    /// where the first item was (or at the end), every other line stays.
    /// An empty `items` removes the list.
    public static func replacing(with items: [(text: String, isDone: Bool)], in body: String) -> String {
        let checklist = TodoChecklist(body: body)
        let entries = items.map { "- [\($0.isDone ? "x" : " ")] \($0.text.trimmingCharacters(in: .whitespacesAndNewlines))" }
        var lines = body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let first = checklist.items.first else {
            guard !entries.isEmpty else { return body }
            let trimmed = body.trimmingCharacters(in: .newlines)
            return (trimmed.isEmpty ? "" : trimmed + "\n\n") + entries.joined(separator: "\n") + "\n"
        }
        for item in checklist.items.reversed() { lines.remove(at: item.line) }
        lines.insert(contentsOf: entries, at: first.line)
        // A list removed from between two paragraphs leaves one blank line.
        if entries.isEmpty, first.line > 0, first.line < lines.count, lines[first.line - 1].isEmpty, lines[first.line].isEmpty {
            lines.remove(at: first.line)
        }
        return lines.joined(separator: "\n")
    }

    private static func match(_ line: Substring) -> (text: String, isDone: Bool)? {
        guard let match = line.wholeMatch(of: /\s*[-*+] \[([ xX])\](?: (.*))?\r?/) else { return nil }
        return (String(match.output.2 ?? "").trimmingCharacters(in: .whitespaces), match.output.1 != " ")
    }
}

/// What is typed after `!`: the to-dos to list and, unless it starts with
/// `done`, the to-do to add. `done` lists the done ones instead of the open
/// ones; `@project` and `#tag` narrow the list and say where a new to-do
/// goes.
public struct TodoQuery: Sendable, Equatable {
    public var query: KnowledgeQuery
    /// `!done …`: the done to-dos, nothing to add.
    public var showsDone: Bool

    public static func parse(_ raw: String) -> TodoQuery {
        var text = raw.drop { $0.isWhitespace }
        var showsDone = false
        if let word = text.split(whereSeparator: \.isWhitespace).first, word.lowercased() == "done" {
            showsDone = true
            text = text.dropFirst(word.count)
        }
        var query = KnowledgeQuery.parse(String(text))
        query.kinds = [.todo]
        query.status = showsDone ? .done : .open
        return TodoQuery(query: query, showsDone: showsDone)
    }

    /// The title of the to-do `⏎` adds: the words without `@` and `#`.
    public var newTitle: String? {
        guard !showsDone else { return nil }
        let title = query.text.trimmingCharacters(in: .whitespaces)
        return title.isEmpty ? nil : title
    }
}

public enum TodoList {
    /// Open to-dos as `!` lists them: the due ones on top, soonest first,
    /// then the rest by project (the order of `projects`, so the inbox
    /// first), each project's newest first. Newest by `created`, so ticking
    /// an item or closing a to-do does not move it.
    public static func ordered(_ items: [KnowledgeItem], projects: [String]) -> [KnowledgeItem] {
        let position = Dictionary(projects.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        return items.sorted { lhs, rhs in
            switch (lhs.due, rhs.due) {
            case let (left?, right?) where left != right: return left < right
            case (_?, nil): return true
            case (nil, _?): return false
            default: break
            }
            let left = position[lhs.project] ?? Int.max, right = position[rhs.project] ?? Int.max
            if left != right { return left < right }
            let leftDate = lhs.created ?? lhs.updated, rightDate = rhs.created ?? rhs.updated
            if leftDate != rightDate { return leftDate > rightDate }
            return lhs.path < rhs.path
        }
    }

    /// Done to-dos as `!done` lists them: the last done first.
    public static func orderedDone(_ items: [KnowledgeItem]) -> [KnowledgeItem] {
        items.sorted { lhs, rhs in
            let left = lhs.frontMatter.date("done") ?? lhs.updated, right = rhs.frontMatter.date("done") ?? rhs.updated
            return left != right ? left > right : lhs.path < rhs.path
        }
    }

    /// Whether a due day (`2026-10-30`) is before today.
    public static func isOverdue(_ due: String, now: Date = .now, timeZone: TimeZone = .current) -> Bool {
        due < FrontMatter.formatDay(now, timeZone: timeZone)
    }
}
