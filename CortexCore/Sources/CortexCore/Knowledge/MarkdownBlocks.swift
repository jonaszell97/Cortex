import Foundation

/// A note's body as blocks for a native view: Foundation's Markdown parser
/// (`PresentationIntent`) does the parsing; this only groups its runs into
/// headings, paragraphs, list items, code blocks, rules, images and tables.
/// Inline styles (emphasis, code, links) stay in the attributed strings.
/// Used by the iOS app (plans/IOS.md, §2 "Markdown rendering").
public struct MarkdownBlock: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable {
        case heading(level: Int, AttributedString)
        case paragraph(AttributedString)
        /// `marker` is nil for a list item's second and later paragraphs.
        case listItem(AttributedString, depth: Int, marker: ListMarker?)
        case code(String, language: String?)
        /// An image alone in its paragraph: `source` as written.
        case image(source: String, alt: String)
        case table(header: [AttributedString], rows: [[AttributedString]])
        case rule
    }

    public enum ListMarker: Sendable, Equatable {
        case bullet
        case number(Int)
        /// A task list item: `- [ ]` or `- [x]`.
        case checkbox(isDone: Bool)
    }

    public var id: Int
    public var kind: Kind
    /// How many block quotes it is in.
    public var quoteDepth: Int

    public init(id: Int, kind: Kind, quoteDepth: Int = 0) {
        self.id = id
        self.kind = kind
        self.quoteDepth = quoteDepth
    }

    /// The blocks of `markdown`, in order. Text the parser can't make sense
    /// of comes out as paragraphs.
    public static func parse(_ markdown: String) -> [MarkdownBlock] {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false, interpretedSyntax: .full, failurePolicy: .returnPartiallyParsedIfPossible)
        guard let document = try? AttributedString(markdown: markdown, options: options) else {
            return markdown.isEmpty ? [] : [MarkdownBlock(id: 0, kind: .paragraph(AttributedString(markdown)))]
        }
        var builder = Builder()
        for (intent, range) in document.runs[\.presentationIntent] {
            guard let intent else { continue }
            builder.add(AttributedString(document[range]), intent: intent)
        }
        return builder.finish()
    }

    /// Which checklist item (`TodoChecklist` order, for `toggleChecklistItem`)
    /// each rendered checkbox is, by block ID. Matched in order by text, so
    /// a task line the parser doesn't show as one (in a code block) is
    /// passed over rather than shifting every tap to the wrong item. A
    /// checkbox without a match is left out.
    public static func checklistIndices(of blocks: [MarkdownBlock], body: String) -> [Int: Int] {
        let items = TodoChecklist(body: body).items.map { plainText(ofInlineMarkdown: $0.text) }
        var result: [Int: Int] = [:]
        var next = 0
        for block in blocks {
            guard case .listItem(let text, _, .checkbox?) = block.kind else { continue }
            let rendered = String(text.characters).trimmingCharacters(in: .whitespaces)
            guard let match = items[next...].firstIndex(of: rendered) else { continue }
            result[block.id] = match
            next = match + 1
        }
        return result
    }

    private static func plainText(ofInlineMarkdown text: String) -> String {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        let plain = (try? AttributedString(markdown: text, options: options)).map { String($0.characters) } ?? text
        return plain.trimmingCharacters(in: .whitespaces)
    }

    /// Collects runs: consecutive runs of the same leaf block are one block.
    private struct Builder {
        var blocks: [MarkdownBlock] = []
        var currentLeaf: Int?
        var lastListItem: Int?
        var table: (identity: Int, header: [Int: AttributedString], rows: [Int: [Int: AttributedString]], quoteDepth: Int)?

        mutating func add(_ text: AttributedString, intent: PresentationIntent) {
            // Innermost first, whatever order the parser hands them in.
            var components = intent.components
            if let first = components.first, !Self.isLeaf(first.kind), let last = components.last, Self.isLeaf(last.kind) {
                components.reverse()
            }
            guard let leaf = components.first else { return }
            let quoteDepth = components.count { if case .blockQuote = $0.kind { true } else { false } }

            if case .tableCell(let column) = leaf.kind {
                addTableCell(text, column: column, components: components, quoteDepth: quoteDepth)
                return
            }
            flushTable()

            if leaf.identity == currentLeaf, var block = blocks.popLast() {
                block.kind = Self.appending(text, to: block.kind)
                blocks.append(block)
                return
            }
            currentLeaf = leaf.identity

            let kind: Kind
            switch leaf.kind {
            case .header(let level):
                kind = .heading(level: level, text)
            case .codeBlock(let language):
                kind = .code(String(text.characters), language: language)
            case .thematicBreak:
                kind = .rule
            default:
                kind = listItem(text, components: components) ?? Self.paragraph(text)
            }
            blocks.append(MarkdownBlock(id: blocks.count, kind: kind, quoteDepth: quoteDepth))
        }

        mutating func finish() -> [MarkdownBlock] {
            flushTable()
            return blocks.map { block in
                var block = block
                if case .code(let code, let language) = block.kind {
                    block.kind = .code(code.trimmingCharacters(in: .newlines), language: language)
                }
                return block
            }
        }

        /// A paragraph in a list item, with its marker if it is the item's
        /// first.
        private mutating func listItem(_ text: AttributedString, components: [PresentationIntent.IntentType]) -> Kind? {
            guard let itemIndex = components.firstIndex(where: { if case .listItem = $0.kind { true } else { false } }),
                  case .listItem(let ordinal) = components[itemIndex].kind
            else { return nil }
            let depth = components.count {
                switch $0.kind {
                case .orderedList, .unorderedList: true
                default: false
                }
            }
            let item = components[itemIndex].identity
            defer { lastListItem = item }
            guard item != lastListItem else { return .listItem(text, depth: depth, marker: nil) }

            let isOrdered = components[(itemIndex + 1)...].first {
                switch $0.kind {
                case .orderedList, .unorderedList: true
                default: false
                }
            }.map { if case .orderedList = $0.kind { true } else { false } } ?? false
            if !isOrdered, let (isDone, rest) = Self.taskMarker(text) {
                return .listItem(rest, depth: depth, marker: .checkbox(isDone: isDone))
            }
            return .listItem(text, depth: depth, marker: isOrdered ? .number(ordinal) : .bullet)
        }

        private mutating func addTableCell(
            _ text: AttributedString, column: Int, components: [PresentationIntent.IntentType], quoteDepth: Int
        ) {
            guard let tableIdentity = components.first(where: { if case .table = $0.kind { true } else { false } })?.identity
            else { return }
            if table?.identity != tableIdentity {
                flushTable()
                table = (tableIdentity, [:], [:], quoteDepth)
            }
            currentLeaf = nil
            lastListItem = nil
            for component in components {
                switch component.kind {
                case .tableHeaderRow:
                    table?.header[column, default: AttributedString()] += text
                    return
                case .tableRow(let row):
                    table?.rows[row, default: [:]][column, default: AttributedString()] += text
                    return
                default:
                    continue
                }
            }
        }

        private mutating func flushTable() {
            guard let table else { return }
            self.table = nil
            let columns = max(table.header.keys.max() ?? -1, table.rows.values.compactMap { $0.keys.max() }.max() ?? -1) + 1
            let header = (0..<columns).map { table.header[$0] ?? AttributedString() }
            let rows = table.rows.keys.sorted().map { row in
                (0..<columns).map { table.rows[row]?[$0] ?? AttributedString() }
            }
            blocks.append(MarkdownBlock(id: blocks.count, kind: .table(header: header, rows: rows), quoteDepth: table.quoteDepth))
            currentLeaf = nil
        }

        private static func isLeaf(_ kind: PresentationIntent.Kind) -> Bool {
            switch kind {
            case .paragraph, .header, .codeBlock, .thematicBreak, .tableCell: true
            default: false
            }
        }

        /// An image alone in its paragraph becomes an image block.
        private static func paragraph(_ text: AttributedString) -> Kind {
            let runs = text.runs.filter { !text[$0.range].characters.allSatisfy(\.isWhitespace) }
            if runs.count == 1, let run = runs.first, let url = run.imageURL {
                return .image(source: url.relativeString, alt: String(text[run.range].characters))
            }
            return .paragraph(text)
        }

        private static func appending(_ text: AttributedString, to kind: Kind) -> Kind {
            switch kind {
            case .heading(let level, let existing): .heading(level: level, existing + text)
            case .paragraph(let existing): .paragraph(existing + text)
            case .listItem(let existing, let depth, let marker): .listItem(existing + text, depth: depth, marker: marker)
            case .code(let existing, let language): .code(existing + String(text.characters), language: language)
            case .image(let source, let alt): .paragraph(AttributedString(alt.isEmpty ? source : alt) + text)
            case .table, .rule: kind
            }
        }

        /// `[ ] rest` or `[x] rest`, which the parser leaves as text.
        private static func taskMarker(_ text: AttributedString) -> (Bool, AttributedString)? {
            let characters = String(text.characters.prefix(4))
            let isDone: Bool
            switch characters.prefix(3) {
            case "[ ]": isDone = false
            case "[x]", "[X]": isDone = true
            default: return nil
            }
            let drop = characters.count == 4 && characters.last?.isWhitespace == true ? 4 : 3
            let start = text.characters.index(text.startIndex, offsetBy: drop)
            return (isDone, AttributedString(text[start...]))
        }
    }
}
