import AppKit
import SwiftUI
import Testing
@testable import Cortex

/// A scope that records what the router asks of it.
@MainActor
final class FakeScope: PaletteScope {
    var searches: [String] = []
    var moves: [PaletteStep] = []
    var activations: [(PaletteActivation, PaletteTarget)] = []
    var clears = 0
    var leaves = 0
    var navigation: PaletteNavigation = .list
    var keys: [PaletteKey] = []
    var cancels = false

    func search(_ text: String) { searches.append(text) }
    func didLeave() { leaves += 1 }
    func clear() { clears += 1 }
    var body: AnyView { AnyView(EmptyView()) }
    func move(_ step: PaletteStep) { moves.append(step) }
    func activate(_ activation: PaletteActivation, target: PaletteTarget) -> Bool {
        activations.append((activation, target))
        return true
    }
    var activationHints: [PaletteHint] { [PaletteHint(.primary, "Paste")] }
    func cancel() -> Bool { cancels }
}

/// Which module a query goes to, and what the router does with keys.
@MainActor
@Suite struct PaletteRouterTests {
    func route(_ id: ModuleID, _ trigger: PaletteTrigger, scope: any PaletteScope = FakeScope()) -> PaletteRoute {
        PaletteRoute(id: id, trigger: trigger, placeholder: id.rawValue, scope: scope)
    }

    var routes: [PaletteRoute] {
        [
            route("clipboard", .default), route("snippets", .prefix(";")), route("actions", .prefix(">")),
            route("commands", .prefix("$")), route("emoji", .prefix(":")), route("symbols", .prefix("::")),
        ]
    }

    func resolve(_ query: String, in routes: [PaletteRoute]? = nil) -> (ModuleID?, String) {
        let (route, text) = PaletteRouting.resolve(query, in: routes ?? self.routes)
        return (route?.id, text)
    }

    @Test func withoutATriggerTheDefaultGetsTheWholeQuery() {
        #expect(resolve("") == ("clipboard", ""))
        #expect(resolve("hello ;x") == ("clipboard", "hello ;x"))
        #expect(resolve("port 3000") == ("clipboard", "port 3000"))
    }

    @Test func aTriggerGoesToItsModuleWithoutThePrefix() {
        #expect(resolve(";sig") == ("snippets", "sig"))
        #expect(resolve(">") == ("actions", ""))
        #expect(resolve("$port 3000") == ("commands", "port 3000"))
        #expect(resolve(":smile") == ("emoji", "smile"))
    }

    @Test func theLongestPrefixWins() {
        #expect(resolve("::star") == ("symbols", "star"))
        #expect(resolve(":::") == ("symbols", ":"))
        #expect(resolve(":star") == ("emoji", "star"))
    }

    @Test func aBackslashEscapesEveryTrigger() {
        for prefix in [";", ">", ":", "::", "\\", "@", "$"] {
            #expect(resolve("\\" + prefix + "x") == ("clipboard", prefix + "x"), "\\\(prefix)")
        }
        #expect(resolve("\\") == ("clipboard", ""))
    }

    @Test func aDisabledModulesTriggerSearchesTheDefault() {
        let withoutEmoji = routes.filter { $0.id != "emoji" }
        #expect(resolve(":smile", in: withoutEmoji) == ("clipboard", ":smile"))
        #expect(resolve("::star", in: withoutEmoji) == ("symbols", "star"))
    }

    @Test func withoutTheDefaultModuleOnlyTriggersRoute() {
        let withoutClipboard = routes.filter { $0.id != "clipboard" }
        #expect(resolve("hello", in: withoutClipboard) == (nil, "hello"))
        #expect(resolve(";sig", in: withoutClipboard) == ("snippets", "sig"))
        #expect(resolve("\\;sig", in: withoutClipboard) == (nil, ";sig"))
    }

    @Test func placeholderShowsTheDefaultAndTheTriggerSymbols() {
        #expect(PaletteRouting.placeholder(for: routes)
            == "Search clipboard · ;snippets · >actions · $commands · :emoji · ::symbols")
        #expect(PaletteRouting.placeholder(for: routes.filter { $0.id != "clipboard" && $0.id != "emoji" })
            == "Search ;snippets · >actions · $commands · ::symbols")
    }

    // MARK: - The model

    @Test func typingSearchesTheActiveScopeAndLeavesTheOldOne() {
        let emoji = FakeScope()
        let symbols = FakeScope()
        let model = PaletteModel(routes: [route("clipboard", .default), route("emoji", .prefix(":"), scope: emoji),
                                          route("symbols", .prefix("::"), scope: symbols)])
        model.query = ":"
        model.query = ":fi"
        #expect(model.activeModule == "emoji")
        #expect(emoji.searches == ["", "fi"])
        model.query = "::"
        #expect(emoji.leaves == 1)
        #expect(symbols.searches == [""])

        model.clear()
        #expect(emoji.clears == 1 && symbols.clears == 1, "every scope used since the palette opened")
        model.clear()
        #expect(emoji.clears == 1)
    }

    @Test func openSetsTheTriggerOrSearchesAgain() {
        let scope = FakeScope()
        let model = PaletteModel(routes: [route("clipboard", .default), route("actions", .prefix(">"), scope: scope)])
        model.query = "abc"
        model.open("actions")
        #expect(model.query == ">")
        model.open("actions")
        #expect(scope.searches == ["", ""])
    }

    @Test func keysGoToTheScope() {
        let scope = FakeScope()
        var pinned = 0
        scope.keys = [
            PaletteKey(.command("p"), hint: "Pin") { pinned += 1; return true },
            PaletteKey(.modifierOnly(.option), hint: "Reveal"),
            PaletteKey(.command("e")) { false },
        ]
        let model = PaletteModel(routes: [route("clipboard", .default, scope: scope)])

        #expect(model.handle(.combo(.command("p"))))
        #expect(pinned == 1)
        #expect(!model.handle(.combo(.command("e"))), "the scope let it through")
        #expect(!model.handle(.combo(.command("x"))))
        #expect(!model.handle(.move(.sideways(1))), "←→ stay with the search field in a list")
        #expect(model.handle(.move(.vertical(1))))
        #expect(model.handle(.activate(.option, .position(2))))
        #expect(scope.moves == [.vertical(1)])
        #expect(scope.activations.first?.0 == .option && scope.activations.first?.1 == .position(2))
        #expect(model.hints == [
            PaletteHint(.primary, "Paste"), PaletteHint(keys: "⌘P", label: "Pin"), PaletteHint(keys: "⌥", label: "Reveal"),
        ])

        scope.navigation = .grid(columns: 4)
        #expect(model.handle(.move(.sideways(1))))
        #expect(model.hints.last == .move)
    }

    @Test func anOverlayTakesTheKeysAndEscLeavesIt() {
        let scope = FakeScope()
        let model = PaletteModel(routes: [route("clipboard", .default, scope: scope)])
        var activated: [PaletteActivation] = []
        model.overlay = PaletteOverlay(
            body: AnyView(EmptyView()), activationHints: [PaletteHint(.primary, "Paste")],
            keys: [PaletteKey(.tab, hint: "Next field")],
            activate: { activated.append($0) }, escape: .dismiss)

        #expect(model.handle(.activate(.shift, .selected)))
        #expect(activated == [.shift])
        #expect(!model.handle(.move(.vertical(1))))
        #expect(!model.handle(.combo(.tab)), "a hint only: the form's fields move on")
        #expect(scope.moves.isEmpty)
        #expect(model.hints == [PaletteHint(.primary, "Paste"), PaletteHint(keys: "⇥", label: "Next field"), .escape("Back")])
        let focus = model.focusRequest

        #expect(model.cancel())
        #expect(model.overlay == nil)
        #expect(model.focusRequest == focus + 1, "back to the search field")
        #expect(!model.cancel(), "Esc again closes the palette")
        scope.cancels = true
        #expect(model.cancel())

        model.overlay = PaletteOverlay(
            body: AnyView(EmptyView()), activationHints: [], activate: { _ in }, escape: .closePalette)
        #expect(!model.cancel())
    }

    @Test func everyWayAnOverlayGoesTellsItOnce() {
        let model = PaletteModel(routes: [route("clipboard", .default), route("commands", .prefix("$"))])
        var dismissals = 0
        func present() {
            model.overlay = PaletteOverlay(
                body: AnyView(EmptyView()), activationHints: [], activate: { _ in }, escape: .dismiss,
                dismissed: { dismissals += 1 })
        }

        present()
        #expect(model.cancel())
        #expect(dismissals == 1, "Esc")
        #expect(!model.cancel())
        #expect(dismissals == 1, "not again")

        present()
        model.open("commands", searching: "kill")
        #expect(model.overlay == nil && dismissals == 2, "another module opens")

        present()
        model.prepareForShow()
        #expect(model.overlay == nil && dismissals == 3, "the palette is shown again")

        present()
        model.clear()
        #expect(model.overlay == nil && dismissals == 4, "the palette hides")

        present()
        present()
        #expect(dismissals == 5, "one overlay replaces another")
        model.overlay = nil
        #expect(dismissals == 6)
    }

    @Test func anOverlayMayTakeTheArrowKeys() {
        let scope = FakeScope()
        let model = PaletteModel(routes: [route("commands", .prefix("$"), scope: scope)])
        var moves: [PaletteStep] = []
        model.overlay = PaletteOverlay(
            body: AnyView(EmptyView()), activationHints: [], activate: { _ in }, escape: .dismiss,
            move: { step in
                moves.append(step)
                return step == .vertical(1)
            })
        #expect(model.handle(.move(.vertical(1))), "into the suggestions")
        #expect(!model.handle(.move(.vertical(-1))), "the field gets it")
        #expect(moves == [.vertical(1), .vertical(-1)])
        #expect(scope.moves.isEmpty)
    }

    @Test func newRoutesDropWhatWasLoadedAndRouteWithoutSearching() {
        let clipboard = FakeScope(), emoji = FakeScope()
        let model = PaletteModel(routes: [route("clipboard", .default, scope: clipboard), route("emoji", .prefix(":"), scope: emoji)])
        model.query = ":smile"
        #expect(model.activeModule == "emoji")

        // Emoji switched off: the query now goes to the clipboard.
        model.setRoutes([route("clipboard", .default, scope: clipboard)])
        #expect(emoji.clears == 1 && clipboard.clears == 1)
        #expect(model.activeModule == "clipboard" && model.searchText == ":smile")
        #expect(model.placeholder == "Search clipboard")
        #expect(clipboard.searches == [""], "no search until the palette shows")

        // Clipboard switched off as well: the landing view.
        model.setRoutes([])
        #expect(model.activeModule == nil && model.activeScope == nil)
    }

    @Test func modulesWithoutATriggerGetNoRoute() {
        let host = ModuleHost(ModuleList.all, services: ModuleServices(
            defaults: UserDefaults(suiteName: "CortexTests-\(UUID().uuidString)")!, secrets: MemorySecrets()))
        // Without a database, Clipboard and Snippets are off.
        #expect(host.paletteRoutes.map(\.id) == ["knowledge", "todos", "actions", "commands", "emoji", "calculator", "symbols"])
    }
}
