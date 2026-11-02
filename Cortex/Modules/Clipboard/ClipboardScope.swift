import AppKit
import SwiftUI
import CortexCore

/// The palette without a trigger: the clipboard history, newest first, and
/// the selected clip's full content. ⏎ pastes it in the richest type and ⇧⏎
/// as plain text (or the other way round, as Settings says), ⌥⏎ copies it.
/// Sensitive clips are masked while ⌥ is not held.
@MainActor
@Observable
final class ClipboardScope: PaletteScope {
    let list = ResultList<ClipSummary, Int64>(id: \.id)
    /// The selected clip's full content.
    private(set) var detail: ClipDetail?
    /// True while ⌥ is held: sensitive items are shown in clear.
    private(set) var isRevealing = false
    /// The query as last searched, for the empty state.
    private(set) var query = ""

    @ObservationIgnored private let service: ClipboardService
    @ObservationIgnored private let snippets: @MainActor () -> (any SnippetsAPI)?
    @ObservationIgnored private let actions: @MainActor () -> (any ActionsAPI)?
    @ObservationIgnored private let palette: @MainActor () -> any PaletteHost
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var detailTask: Task<Void, Never>?
    /// Reloads the selected clip's detail after the history changed.
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    /// nil while nothing is loaded (the palette is hidden).
    @ObservationIgnored private var loadedQuery: String?

    init(
        service: ClipboardService,
        snippets: @escaping @MainActor () -> (any SnippetsAPI)? = { nil },
        actions: @escaping @MainActor () -> (any ActionsAPI)? = { nil },
        palette: @escaping @MainActor () -> any PaletteHost
    ) {
        self.service = service
        self.snippets = snippets
        self.actions = actions
        self.palette = palette
        list.didSelect = { [weak self] item in self?.loadDetail(of: item?.id) }
    }

    /// The history changed (new copy, purge, import, sync): load it again if
    /// it is showing.
    func historyDidChange() {
        guard let loadedQuery else { return }
        search(loadedQuery)
        // The selected clip itself may have changed (its text was read);
        // the list only reloads the detail when the selection moves.
        let searchTask = searchTask
        refreshTask = Task { [weak self] in
            await searchTask?.value
            guard let self, let id = list.selectedID, detail?.item.id == id else { return }
            loadDetail(of: id)
        }
    }

    /// Waits for the search to finish (for tests).
    func loaded() async {
        await searchTask?.value
    }

    /// Waits for the selected clip's detail (for tests).
    func detailLoaded() async {
        await refreshTask?.value
        await detailTask?.value
    }

    // MARK: - PaletteScope

    func search(_ text: String) {
        query = text
        loadedQuery = text
        let store = service.store
        searchTask = list.load(query: text) { try await store.summaries(matching: text) }
    }

    func clear() {
        list.clear()
        refreshTask?.cancel()
        detailTask?.cancel()
        detail = nil
        isRevealing = false
        loadedQuery = nil
    }

    var body: AnyView { AnyView(ClipboardView(scope: self)) }

    func move(_ step: PaletteStep) {
        if case .vertical(let delta) = step { list.move(by: delta) }
    }

    func activate(_ activation: PaletteActivation, target: PaletteTarget) -> Bool {
        let item = switch target {
        case .selected: list.selected
        case .position(let index): list.item(at: index)
        }
        if let item { paste(item.id, action: pasteAction(activation)) }
        return true
    }

    var activationHints: [PaletteHint] {
        let plain = service.settings.pastePlainByDefault
        // An image with text pastes that text as plain text.
        let asText = selectedDetail?.item.imageText == nil ? "Paste as text" : "Paste text"
        return [
            PaletteHint(.primary, plain ? asText : "Paste"),
            PaletteHint(.shift, plain ? "Paste" : asText),
            PaletteHint(.option, "Copy"),
        ]
    }

    var keys: [PaletteKey] {
        let hasSnippets = snippets() != nil
        return [
            PaletteKey(.command("p"), hint: "Pin") { [unowned self] in
                if let item = list.selected {
                    Task { await service.setPinned(!item.isPinned, id: item.id) }
                }
                return true
            },
            PaletteKey(.command(.delete), hint: "Delete") { [unowned self] in
                if let id = list.selectedID {
                    Task { await service.delete(id: id) }
                }
                return true
            },
            PaletteKey(.command("e"), hint: hasSnippets ? "Save as snippet" : nil) { [unowned self] in
                guard let snippets = snippets(), let text = selectedDetail?.item.textForPlainPaste else { return true }
                palette().close()
                snippets.editSnippet(.new(body: text))
                return true
            },
            PaletteKey(.command("n")) { [unowned self] in
                guard let snippets = snippets() else { return true }
                palette().close()
                snippets.editSnippet(.new(body: nil))
                return true
            },
            PaletteKey(.command("k"), hint: actions() == nil ? nil : "Actions") { [unowned self] in
                guard let actions = actions(), let detail = selectedDetail else { return true }
                actions.showActions(on: .clip(detail))
                return true
            },
            PaletteKey(.modifierOnly(.option), hint: "Reveal"),
        ]
    }

    func modifiersChanged(_ flags: NSEvent.ModifierFlags) {
        isRevealing = flags.intersection(.deviceIndependentFlagsMask).contains(.option)
    }

    // MARK: - Pasting

    /// ⏎ pastes in the richest type and ⇧⏎ as plain text, or the other way
    /// round when "paste as plain text by default" is on. ⌥ only copies.
    func pasteAction(_ activation: PaletteActivation) -> PasteAction {
        if activation.isCopy { return .copyOnly }
        return .paste(activation.hasShift != service.settings.pastePlainByDefault ? .plainText : .rich)
    }

    /// A double click: as ⏎.
    func choose(_ item: ClipSummary) {
        paste(item.id, action: pasteAction(.primary))
    }

    private func paste(_ id: Int64, action: PasteAction) {
        let service = service
        palette().closeAndDeliver(action) { target in
            await service.perform(action, id: id, into: target)
        }
    }

    // MARK: - Detail

    /// The detail, once it is the selected clip's.
    private var selectedDetail: ClipDetail? {
        guard let detail, detail.item.id == list.selectedID else { return nil }
        return detail
    }

    private func loadDetail(of id: Int64?) {
        detailTask?.cancel()
        guard let id else {
            detail = nil
            return
        }
        let store = service.store
        detailTask = Task {
            let loaded = try? await store.detail(id: id)
            guard !Task.isCancelled else { return }
            detail = loaded
        }
    }
}
