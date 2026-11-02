import Foundation

/// An item as other apps take it (plans/IOS.md, M4): Markdown to copy or
/// share, plain text for Apple Notes, reminders for Apple Reminders.
extension KnowledgeItem {
    /// The deep link that opens the item in the iOS app.
    public var link: URL { KnowledgeLink.item(path).url }

    /// The title as a heading, then the body; no front matter.
    public var markdown: String {
        let body = bodyWithoutTitle
        return "# \(title)" + (body.isEmpty ? "\n" : "\n\n\(body)\n")
    }

    /// For Notes: the title as the first line, which Notes makes the note's
    /// title, then the body as plain text.
    public var notesText: String {
        let body = MarkdownBlock.plainText(MarkdownBlock.parse(bodyWithoutTitle))
        return body.isEmpty ? title : "\(title)\n\n\(body)"
    }

    /// The body, without a first `# Title` heading that repeats the title
    /// (imported notes have one).
    var bodyWithoutTitle: String {
        let body = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = body.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        guard let first = lines.first, first.trimmingCharacters(in: .whitespaces) == "# \(title)" else { return body }
        return lines.count > 1 ? lines[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
    }
}

extension MarkdownBlock {
    /// Blocks as plain text, for apps that take no Markdown: headings and
    /// paragraphs as their text, `•` and numbers for lists, `☐` and `☑`
    /// for task items, links as "text (url)", images as their alt text,
    /// tables a row per line with tabs between the cells.
    public static func plainText(_ blocks: [MarkdownBlock]) -> String {
        var text = ""
        var previousWasListItem = false
        for block in blocks {
            let isListItem = if case .listItem = block.kind { true } else { false }
            guard let line = plainText(of: block.kind) else { continue }
            if !text.isEmpty { text += isListItem && previousWasListItem ? "\n" : "\n\n" }
            let quote = String(repeating: "> ", count: block.quoteDepth)
            text += line.split(separator: "\n", omittingEmptySubsequences: false).map { quote + $0 }.joined(separator: "\n")
            previousWasListItem = isListItem
        }
        return text
    }

    private static func plainText(of kind: Kind) -> String? {
        switch kind {
        case .heading(_, let text), .paragraph(let text):
            return inline(text)
        case .listItem(let text, let depth, let marker):
            let indent = String(repeating: "    ", count: max(depth - 1, 0))
            let mark = switch marker {
            case .bullet?: "• "
            case .number(let number)?: "\(number). "
            case .checkbox(let isDone)?: isDone ? "☑ " : "☐ "
            case nil: "  "
            }
            return indent + mark + inline(text)
        case .code(let code, _):
            return code
        case .image(_, let alt):
            return alt.isEmpty ? nil : alt
        case .table(let header, let rows):
            return ([header] + rows).map { $0.map(inline).joined(separator: "\t") }.joined(separator: "\n")
        case .rule:
            return "———"
        }
    }

    /// The text, with each link's address after it unless the text is the
    /// address.
    private static func inline(_ text: AttributedString) -> String {
        var result = ""
        for (link, range) in text.runs[\.link] {
            let part = String(text[range].characters)
            result += part
            guard let link else { continue }
            let address = link.absoluteString
            let shown = address.replacing(/^(https?:\/\/|mailto:)/, with: "")
            if part != address, part != shown { result += " (\(shown))" }
        }
        return result.trimmingCharacters(in: .whitespaces)
    }
}

/// What Add to Reminders writes for an item: one reminder, or one per
/// checklist item. The key tells reminders of the same item apart, so
/// adding again updates them. The notes end with the item's link: the
/// Reminders app doesn't show a URL that another app set, but it makes a
/// link in the notes tappable.
public struct KnowledgeReminder: Equatable, Sendable {
    /// `""` for the item's one reminder; a checklist item's text for its own.
    public var key: String
    public var title: String
    public var notes: String?
    /// The due day, without a time (an all-day reminder).
    public var due: DateComponents?
    public var isCompleted: Bool

    public init(key: String, title: String, notes: String?, due: DateComponents?, isCompleted: Bool) {
        self.key = key
        self.title = title
        self.notes = notes
        self.due = due
        self.isCompleted = isCompleted
    }

    /// The item as one reminder (its body as plain text in the notes), or
    /// with `perItem` each checklist item as one, ticked ones completed. A
    /// done to-do's reminders are all completed. Every reminder's notes end
    /// with the item's link.
    public static func reminders(for item: KnowledgeItem, perItem: Bool) -> [KnowledgeReminder] {
        let due = item.due.flatMap(dueComponents)
        let link = item.link.absoluteString
        let isDone = item.status == .done
        let checklist = TodoChecklist(body: item.body)
        guard perItem, !checklist.isEmpty else {
            let body = MarkdownBlock.plainText(MarkdownBlock.parse(item.bodyWithoutTitle))
            let notes = body.isEmpty ? link : "\(body)\n\n\(link)"
            return [KnowledgeReminder(key: "", title: item.title, notes: notes, due: due, isCompleted: isDone)]
        }
        var seen: [String: Int] = [:]
        return checklist.items.map { entry in
            let title = MarkdownBlock.plainText(MarkdownBlock.parse(entry.text))
            // The same text twice gets "(2)", so each keeps its reminder.
            seen[title, default: 0] += 1
            let key = seen[title]! > 1 ? "\(title) (\(seen[title]!))" : title
            return KnowledgeReminder(
                key: key, title: title, notes: "From “\(item.title)”\n\(link)", due: due, isCompleted: isDone || entry.isDone)
        }
    }

    /// `2026-10-30` as a year, month and day.
    public static func dueComponents(_ day: String) -> DateComponents? {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, (1...12).contains(parts[1]), (1...31).contains(parts[2]) else { return nil }
        return DateComponents(year: parts[0], month: parts[1], day: parts[2])
    }
}
