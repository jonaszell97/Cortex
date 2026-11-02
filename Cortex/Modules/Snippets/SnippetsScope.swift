import AppKit
import SwiftUI
import CortexCore

/// `;` in the palette: the snippets, most used first, searched by name,
/// keyword, tags and text. ⏎ pastes the selected one as plain text, or asks
/// for its fill-ins first in an overlay; ⌥⏎ copies it. ⌘E and ⌘N open the
/// editor.
@MainActor
@Observable
final class SnippetsScope: PaletteScope {
    /// Pastes or copies a snippet with these fill-ins into the app (closing
    /// the palette is up to the caller). Returns false when a paste was
    /// wanted but Accessibility is missing.
    typealias Deliver = @MainActor (
        _ snippet: Snippet, _ action: PasteAction, _ fillIns: [String: String], _ restoringPasteboard: Bool,
        _ target: NSRunningApplication?
    ) async -> Bool

    let list = ResultList<Snippet, Int64?>(id: \.id)
    /// The query as last searched, for the empty state.
    private(set) var query = ""

    @ObservationIgnored private let load: @MainActor () async -> [Snippet]
    @ObservationIgnored private let deliver: Deliver
    @ObservationIgnored private let edit: @MainActor (SnippetEditRequest) -> Void
    @ObservationIgnored private let palette: @MainActor () -> any PaletteHost
    /// All snippets, loaded once per show; search runs over these.
    @ObservationIgnored private var snippetLoad: Task<[Snippet], Never>?
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    /// nil while nothing is loaded (the palette is hidden).
    @ObservationIgnored private var loadedQuery: String?

    init(
        load: @escaping @MainActor () async -> [Snippet],
        deliver: @escaping Deliver,
        edit: @escaping @MainActor (SnippetEditRequest) -> Void,
        palette: @escaping @MainActor () -> any PaletteHost
    ) {
        self.load = load
        self.deliver = deliver
        self.edit = edit
        self.palette = palette
    }

    /// Snippets were edited: load them again if they are showing.
    func snippetsDidChange() {
        snippetLoad = nil
        if let loadedQuery { search(loadedQuery) }
    }

    /// Waits for the search to finish (for tests).
    func loaded() async {
        await searchTask?.value
    }

    // MARK: - PaletteScope

    func search(_ text: String) {
        query = text
        loadedQuery = text
        // Shared by the searches while typing, so a cancelled search does not
        // throw away the loaded snippets.
        let load = snippetLoad ?? Task { await self.load() }
        snippetLoad = load
        searchTask = list.load(query: text) {
            SnippetSearch.rank(await load.value, query: text)
        }
    }

    func clear() {
        list.clear()
        snippetLoad?.cancel()
        snippetLoad = nil
        loadedQuery = nil
    }

    var body: AnyView { AnyView(SnippetsView(scope: self)) }

    func move(_ step: PaletteStep) {
        if case .vertical(let delta) = step { list.move(by: delta) }
    }

    func activate(_ activation: PaletteActivation, target: PaletteTarget) -> Bool {
        let snippet = switch target {
        case .selected: list.selected
        case .position(let index): list.item(at: index)
        }
        if let snippet { choose(snippet, copyOnly: activation.isCopy) }
        return true
    }

    var activationHints: [PaletteHint] {
        [PaletteHint(.primary, "Paste"), PaletteHint(.option, "Copy")]
    }

    var keys: [PaletteKey] {
        [
            PaletteKey(.command("e"), hint: "Edit") { [unowned self] in
                guard let id = list.selected?.id else { return true }
                palette().close()
                edit(.snippet(id))
                return true
            },
            PaletteKey(.command("n"), hint: "New snippet") { [unowned self] in
                palette().close()
                edit(.new(body: nil))
                return true
            },
        ]
    }

    // MARK: - Pasting

    /// Pastes (or copies) a snippet, or asks for its fill-ins first.
    func choose(_ snippet: Snippet, copyOnly: Bool = false) {
        if snippet.template.fillIns.isEmpty {
            paste(snippet, copyOnly: copyOnly, fillIns: [:], restoringPasteboard: false)
        } else {
            palette().present(fillInOverlay(for: snippet, fromExpansion: false))
        }
    }

    /// The form asking for a snippet's named fill-ins. Opened by keyword
    /// expansion, Esc closes the palette and pasting puts the previous
    /// clipboard back.
    func fillInOverlay(for snippet: Snippet, fromExpansion: Bool) -> PaletteOverlay {
        let form = FillInForm(snippet: snippet)
        return PaletteOverlay(
            body: AnyView(FillInFormView(form: form)),
            activationHints: [PaletteHint(.primary, "Paste"), PaletteHint(.option, "Copy")],
            keys: [PaletteKey(.tab, hint: "Next field")],
            activate: { [unowned self] activation in
                paste(snippet, copyOnly: activation.isCopy, fillIns: form.values, restoringPasteboard: fromExpansion)
            },
            escape: fromExpansion ? .closePalette : .dismiss)
    }

    /// Snippets paste as plain text whatever ⇧ says.
    private func paste(_ snippet: Snippet, copyOnly: Bool, fillIns: [String: String], restoringPasteboard: Bool) {
        let action: PasteAction = copyOnly ? .copyOnly : .paste(.plainText)
        let deliver = deliver
        palette().closeAndDeliver(action) { target in
            await deliver(snippet, action, fillIns, restoringPasteboard, target)
        }
    }
}

/// A snippet's named fill-ins and the values typed so far, starting with
/// their defaults.
@MainActor
@Observable
final class FillInForm {
    let snippet: Snippet
    let fields: [SnippetTemplate.FillIn]
    var values: [String: String]

    init(snippet: Snippet) {
        self.snippet = snippet
        fields = snippet.template.fillIns
        values = Dictionary(fields.map { ($0.name, $0.defaultValue ?? "") }, uniquingKeysWith: { first, _ in first })
    }
}
