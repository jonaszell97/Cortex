import AppKit
import Foundation
import Testing
@testable import Cortex
import CortexCore

/// The palette's `;` scope: searching snippets, pasting and the fill-in form.
@MainActor
@Suite struct SnippetsScopeTests {
    final class Source {
        var snippets: [Snippet]
        var loads = 0
        var delivered: [(name: String, action: PasteAction, fillIns: [String: String], restoring: Bool)] = []
        var edits: [SnippetEditRequest] = []
        init(_ snippets: [Snippet]) { self.snippets = snippets }
    }
    let source = Source([
        Snippet(id: 1, name: "Signature", keyword: ";sig", body: "Best regards", usageCount: 3),
        Snippet(id: 2, name: "Meeting notes", keyword: ";mtg", body: "With {Attendees} on {date:yyyy-MM-dd}", usageCount: 1),
        Snippet(id: 3, name: "Address", body: "Musterstraße 1"),
    ])
    let palette = FakePaletteHost()
    let scope: SnippetsScope

    init() {
        let (source, palette) = (source, palette)
        scope = SnippetsScope(
            load: {
                source.loads += 1
                return source.snippets
            },
            deliver: { snippet, action, fillIns, restoring, _ in
                source.delivered.append((snippet.name, action, fillIns, restoring))
                return true
            },
            edit: { source.edits.append($0) },
            palette: { palette })
    }

    func type(_ query: String) async {
        scope.search(query)
        await scope.loaded()
    }

    @Test func listsTheMostUsedFirst() async {
        await type("")
        #expect(scope.list.items.map(\.name) == ["Signature", "Meeting notes", "Address"])
        #expect(scope.list.selected?.name == "Signature")
    }

    @Test func searchesNamesAndKeywords() async {
        await type("addr")
        #expect(scope.list.items.map(\.name) == ["Address"])
        await type("mtg")
        #expect(scope.list.items.first?.name == "Meeting notes")
        #expect(scope.list.selected?.name == "Meeting notes", "the first match is selected as the query changes")
        await type(";mtg")
        #expect(scope.list.items.first?.name == "Meeting notes", "typing the keyword with its own ; also finds it")
    }

    @Test func movesSelectionWithinSnippets() async {
        await type("")
        scope.move(.vertical(1))
        #expect(scope.list.selected?.name == "Meeting notes")
        scope.move(.vertical(10))
        #expect(scope.list.selected?.name == "Address")
        scope.move(.sideways(-1))
        #expect(scope.list.selected?.name == "Address", "a list does not move sideways")
        scope.move(.vertical(-10))
        #expect(scope.list.selected?.name == "Signature")
    }

    @Test func loadsSnippetsOncePerShowUntilTheyChange() async {
        await type("")
        await type("s")
        await type("si")
        #expect(source.loads == 1)

        source.snippets.append(Snippet(id: 4, name: "Simple", body: "x"))
        scope.snippetsDidChange()
        await scope.loaded()
        #expect(source.loads == 2)
        #expect(scope.list.items.map(\.name).contains("Simple"))
        #expect(scope.list.selected?.name == "Signature", "a reload keeps the selection")

        scope.clear()
        #expect(scope.list.isEmpty)
        #expect(scope.list.selectedID == nil)
        scope.snippetsDidChange()
        await scope.loaded()
        #expect(source.loads == 2, "nothing is loaded while the palette is hidden")
        await type("")
        #expect(source.loads == 3)
    }

    @Test func returnPastesAsPlainTextAndOptionCopies() async {
        await type("")
        #expect(scope.activate(.shift, target: .selected))
        #expect(scope.activate(.option, target: .position(2)))
        await palette.delivered()
        #expect(source.delivered.map(\.name) == ["Signature", "Address"])
        #expect(source.delivered.map(\.action) == [.paste(.plainText), .copyOnly])
        #expect(source.delivered.allSatisfy { !$0.restoring })
        #expect(palette.closes == 2)
    }

    @Test func fillInsAskFirst() async throws {
        await type("mtg")
        #expect(scope.activate(.primary, target: .selected))
        let overlay = try #require(palette.overlays.first)
        #expect(source.delivered.isEmpty)
        #expect(overlay.escape == .dismiss)
        #expect(overlay.activationHints.map(\.label) == ["Paste", "Copy"])

        overlay.activate(.option)
        await palette.delivered()
        #expect(source.delivered.first?.action == .copyOnly)
        #expect(source.delivered.first?.fillIns == ["Attendees": ""])
    }

    @Test func fillInFormStartsWithDefaults() {
        let snippet = Snippet(id: 9, name: "Hi", body: "{argument name=\"who\" default=\"team\"} {topic} {who}")
        let form = FillInForm(snippet: snippet)
        #expect(form.fields.map(\.name) == ["who", "topic"])
        #expect(form.values == ["who": "team", "topic": ""])
    }

    @Test func fromKeywordExpansionEscClosesAndTheClipboardIsPutBack() async {
        let snippet = Snippet(id: 9, name: "Hi", body: "Hi {name}")
        let overlay = scope.fillInOverlay(for: snippet, fromExpansion: true)
        #expect(overlay.escape == .closePalette)
        overlay.activate(.primary)
        await palette.delivered()
        #expect(source.delivered.first?.restoring == true)
        #expect(source.delivered.first?.action == .paste(.plainText))
    }

    @Test func commandEEditsAndCommandNStartsANewSnippet() async throws {
        await type("addr")
        let keys = scope.keys
        #expect(keys.map(\.hint) == ["Edit", "New snippet"])
        #expect(keys[0].perform?() == true)
        #expect(keys[1].perform?() == true)
        #expect(source.edits == [.snippet(3), .new(body: nil)])
        #expect(palette.closes == 2)
    }
}
