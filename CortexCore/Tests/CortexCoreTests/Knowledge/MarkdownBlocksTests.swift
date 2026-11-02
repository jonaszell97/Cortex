import Foundation
import Testing
import CortexCore

@Suite struct MarkdownBlocksTests {
    /// The blocks as plain text, for comparing.
    func outline(_ markdown: String) -> [String] {
        MarkdownBlock.parse(markdown).map { block in
            let quote = String(repeating: "> ", count: block.quoteDepth)
            switch block.kind {
            case .heading(let level, let text): return quote + "h\(level) " + String(text.characters)
            case .paragraph(let text): return quote + "p " + String(text.characters)
            case .listItem(let text, let depth, let marker):
                let mark = switch marker {
                case .bullet?: "•"
                case .number(let n)?: "\(n)."
                case .checkbox(let done)?: done ? "[x]" : "[ ]"
                case nil: "…"
                }
                return quote + String(repeating: "  ", count: depth - 1) + mark + " " + String(text.characters)
            case .code(let code, let language): return quote + "code(\(language ?? "")) " + code
            case .image(let source, let alt): return quote + "img \(source) \(alt)"
            case .table(let header, let rows):
                return quote + "table " + ([header] + rows).map { $0.map { String($0.characters) }.joined(separator: "|") }
                    .joined(separator: " / ")
            case .rule: return quote + "rule"
            }
        }
    }

    @Test func headingsParagraphsAndRules() {
        #expect(outline("# Title\n\nSome *text*\non two lines.\n\n---\n\n## Next") == [
            "h1 Title", "p Some text on two lines.", "rule", "h2 Next",
        ])
    }

    @Test func listsKeepTheirDepthNumbersAndTasks() {
        let markdown = """
            - one
              - nested
            - [ ] open task
            - [x] done task

            1. first
            2. second

               more of second
            """
        #expect(outline(markdown) == [
            "• one", "  • nested", "[ ] open task", "[x] done task", "1. first", "2. second", "… more of second",
        ])
    }

    @Test func codeKeepsItsLinesAndLanguage() {
        #expect(outline("```swift\nlet a = 1\nlet b = 2\n```\n\nAfter") == [
            "code(swift) let a = 1\nlet b = 2", "p After",
        ])
    }

    @Test func quotesAndImagesAndTables() {
        let markdown = """
            > quoted

            ![A diagram](assets/diagram.png)

            | Name | Value |
            | --- | --- |
            | a | 1 |
            | b | 2 |
            """
        #expect(outline(markdown) == [
            "> p quoted", "img assets/diagram.png A diagram", "table Name|Value / a|1 / b|2",
        ])
    }

    @Test func inlineStylesStayInTheText() throws {
        let blocks = MarkdownBlock.parse("Use `make test` and see [docs](https://example.dev).")
        guard case .paragraph(let text) = try #require(blocks.first).kind else {
            Issue.record("expected a paragraph")
            return
        }
        #expect(text.runs.contains { $0.link == URL(string: "https://example.dev") })
        #expect(text.runs.contains { $0.inlinePresentationIntent == .code })
    }

    @Test func emptyTextHasNoBlocks() {
        #expect(MarkdownBlock.parse("").isEmpty)
    }

    @Test func checkboxesFindTheirChecklistItems() {
        let body = """
            - [ ] **Back up** the database
            - [x] one

            ```
            - [ ] not a task, in code
            ```

            - [ ] two
            - [ ] [link](https://example.com) text
            """
        let blocks = MarkdownBlock.parse(body)
        let boxes = blocks.filter { if case .listItem(_, _, .checkbox?) = $0.kind { true } else { false } }.map(\.id)
        #expect(boxes.count == 4)
        let indices = MarkdownBlock.checklistIndices(of: blocks, body: body)
        #expect(boxes.map { indices[$0] } == [0, 1, 3, 4], "the line in the code block is passed over")
    }
}
