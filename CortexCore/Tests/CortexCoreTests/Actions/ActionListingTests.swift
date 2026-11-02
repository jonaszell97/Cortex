import Foundation
import Testing
@testable import CortexCore

/// Typed input and what `>` lists.
@Suite struct ActionListingTests {
    // MARK: - Typed input

    let home = URL(filePath: "/Users/me")
    let existing: Set<String> = ["/tmp/a.txt", "/tmp/b c.png", "/Users/me/Desktop/x.mov", "/tmp"]

    func typed(_ text: String) -> ActionInput {
        let existing = existing
        return .typed(text, home: home) { existing.contains($0) }
    }

    @Test func pathsToExistingFilesAreFiles() {
        #expect(typed("/tmp/a.txt") == .files([URL(filePath: "/tmp/a.txt")]))
        #expect(typed("~/Desktop/x.mov") == .files([URL(filePath: "/Users/me/Desktop/x.mov")]))
        #expect(typed("/tmp/a.txt '/tmp/b c.png'") == .files([URL(filePath: "/tmp/a.txt"), URL(filePath: "/tmp/b c.png")]))
        #expect(typed(#"/tmp/b\ c.png"#) == .files([URL(filePath: "/tmp/b c.png")]))
        #expect(typed("\"/tmp/b c.png\" /tmp") == .files([URL(filePath: "/tmp/b c.png"), URL(filePath: "/tmp")]))
        #expect(typed("/tmp/b c.png") == .files([URL(filePath: "/tmp/b c.png")]), "one path as copied, spaces unquoted")
    }

    @Test func everythingElseIsText() {
        #expect(typed("3000") == .text("3000"))
        #expect(typed("  owner/repo ") == .text("owner/repo"))
        #expect(typed("/tmp/missing.txt") == .text("/tmp/missing.txt"), "every path must exist")
        #expect(typed("/tmp/a.txt and more") == .text("/tmp/a.txt and more"))
        #expect(typed("'/tmp/a.txt") == .text("'/tmp/a.txt"), "an open quote")
        #expect(typed("") == .none)
        #expect(typed("   ") == .none)
    }

    @Test func aBackslashKeepsPathsText() {
        #expect(typed(#"\/tmp/a.txt"#) == .text("/tmp/a.txt"))
        #expect(typed(#"\n"#) == .text(#"\n"#), "not before a path: kept as typed")
    }

    // MARK: - Listing

    struct Fake: QuickAction {
        let id: String
        var title: String { id }
        let symbol = "circle"
        var keywords: [String] = []
        var takes: Set<ActionInput.Kind> = [.text]
        func accepts(_ input: ActionInput) -> Bool {
            takes.contains(input.kind) && (input.text.map { !$0.isEmpty } ?? true)
        }
        func run(_ input: ActionInput, context: ActionContext) async throws -> ActionOutput { .done("") }
    }

    struct FakeCommand: Command {
        let id: String
        let name: String
        var title: String { id }
        let symbol = "circle"
        var keywords: [String] = []
        var portLike = false
        var argument: CommandArgument? { CommandArgument(title: "X", placeholder: "x") }
        func matches(_ input: ActionInput) -> Bool {
            portLike && input.text?.allSatisfy(\.isNumber) == true
        }
        func resolve(_ invocation: CommandInvocation) async throws -> CommandOutcome { .value(.text("")) }
    }

    let actions: [any QuickAction] = [
        Fake(id: "upper", keywords: ["case"]),
        Fake(id: "shrink", takes: [.files]),
        Fake(id: "uuid", takes: [.none]),
        CommandAction(FakeCommand(id: "port", name: "port", keywords: ["kill"], portLike: true)),
        CommandAction(FakeCommand(id: "kill", name: "kill")),
    ]

    func list(_ query: String, _ listing: ActionListing) -> [String] {
        ActionCatalog.list(actions, query: query, for: listing).map(\.id)
    }

    @Test func onlyWhatTakesTheInputAndIsMeantForIt() {
        #expect(list("", .context(.text("hello"))) == ["upper"])
        #expect(list("", .context(.text("3000"))) == ["upper", "port"], "a copied port number")
        #expect(list("", .context(.none)) == ["uuid"])
        #expect(list("", .context(.files([URL(filePath: "/a")]))) == ["shrink"])
    }

    @Test func whatIsTypedOnlySearches() {
        #expect(list("kill", .context(.text("hello"))).isEmpty, "commands wait for $")
        #expect(list("kill", .context(.text("3000"))) == ["port"])
        #expect(list("up", .context(.files([URL(filePath: "/a")]))).isEmpty)
    }

    @Test func aHandedInInputListsTheSame() {
        #expect(list("", .handedIn(.text("hello"))) == ["upper"])
        #expect(list("kill", .handedIn(.text("hello"))).isEmpty)
        #expect(list("", .handedIn(.text("3000"))) == ["upper", "port"])
    }

    @Test func actionsMatchAnyInputTheyTake() {
        #expect(Fake(id: "upper").matches(.text("x")))
        #expect(!FakeCommand(id: "kill", name: "kill").matches(.text("x")))
    }
}
