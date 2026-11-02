import AppKit
import SwiftUI
import CortexCore

/// `>` in the palette (docs/modules/COMMANDS.md, "What `>` loses"). An action's
/// main input is
///
/// - handed in: ⌘K on a clip, a drop, Services, the selection hotkey;
/// - otherwise what the palette finds when `>` opens: the Finder selection
///   over Finder, else the clipboard.
///
/// What is typed after `>` only searches; typed input is `$`'s. ⏎ runs the
/// selected action and pastes a text or image result, ⌥⏎ only copies it.
/// Instant actions are previewed.
@MainActor
@Observable
final class ActionsScope: PaletteScope {
    let list = ResultList<any QuickAction, String>(id: { $0.id })
    /// What the palette found or was handed; kept until the palette hides.
    private(set) var context: ResolvedActionInput?
    private(set) var isHandedIn = false
    /// The selected instant action's result.
    private(set) var preview: ActionPreview?
    /// The selected action's option values, shown below the preview.
    private(set) var options = ActionOptionValues()
    /// The query as last searched, for the empty state.
    private(set) var searchText = ""

    @ObservationIgnored let service: ActionsService
    @ObservationIgnored private let resolveInput: @MainActor () -> ResolvedActionInput
    @ObservationIgnored private let palette: @MainActor () -> any PaletteHost
    @ObservationIgnored private var previewTask: Task<Void, Never>?
    /// The action `options` belong to.
    @ObservationIgnored private var optionsID: String?
    /// nil while nothing is loaded (the palette is hidden).
    @ObservationIgnored private var loadedQuery: String?

    init(
        service: ActionsService,
        resolveInput: @escaping @MainActor () -> ResolvedActionInput,
        palette: @escaping @MainActor () -> any PaletteHost
    ) {
        self.service = service
        self.resolveInput = resolveInput
        self.palette = palette
        list.didSelect = { [weak self] _ in
            self?.updatePreview()
        }
    }

    /// Works on `input` instead of the Finder selection or the clipboard,
    /// until the palette hides. Typing then only searches.
    func handIn(_ input: ResolvedActionInput) {
        context = input
        isHandedIn = true
        if loadedQuery != nil { relist() }
    }

    /// The user's action files changed: list them again if they are showing.
    func actionsDidChange() {
        if let loadedQuery { search(loadedQuery) }
    }

    func select(_ id: String?) {
        list.select(id)
    }

    /// What the actions run on: the handed-in input or the context.
    var input: ResolvedActionInput? { context }

    /// Changes one of the selected action's options: remembered at once,
    /// and the preview follows.
    func setOption(_ option: ActionOption, to value: String) {
        guard let action = list.selected, action.id == optionsID, options[option] != value else { return }
        options[option] = value
        service.setOptions(options, for: action)
        updatePreview()
    }

    /// Waits for a preview computed off the main thread (for tests).
    func previewLoaded() async {
        await previewTask?.value
    }

    // MARK: - PaletteScope

    func search(_ text: String) {
        searchText = text
        loadedQuery = text
        relist()
    }

    private func relist() {
        let context = context ?? resolveInput()
        self.context = context
        let listing: ActionListing = isHandedIn ? .handedIn(context.input) : .context(context.input)
        var actions = service.list(query: searchText, for: listing)
        // Sensitive input is never sent anywhere.
        if context.isSensitive { actions.removeAll(where: \.isRemote) }
        list.replace(with: actions, query: searchText)
        updatePreview()
    }

    func didLeave() {
        previewTask?.cancel()
    }

    func clear() {
        context = nil
        isHandedIn = false
        list.clear()
        previewTask?.cancel()
        preview = nil
        options = ActionOptionValues()
        optionsID = nil
        loadedQuery = nil
    }

    var body: AnyView { AnyView(ActionsView(scope: self)) }

    func move(_ step: PaletteStep) {
        if case .vertical(let delta) = step { list.move(by: delta) }
    }

    func activate(_ activation: PaletteActivation, target: PaletteTarget) -> Bool {
        let action = switch target {
        case .selected: list.selected
        case .position(let index): list.item(at: index)
        }
        if let action { run(action, copyOnly: activation.isCopy) }
        return true
    }

    var activationHints: [PaletteHint] {
        [PaletteHint(.primary, "Run and paste"), PaletteHint(.option, "Run and copy"), .positions("Run")]
    }

    /// The key view loop moves into the option fields, and ⇧⇥ back.
    var keys: [PaletteKey] {
        guard list.selected?.options.isEmpty == false else { return [] }
        return [PaletteKey(.tab, hint: "Options")]
    }

    // MARK: - Running

    /// ⏎ and ⇧⏎ run the action and paste a text or image result, ⌥⏎ only
    /// copies it. File results do not depend on the key. A result for
    /// selected text replaces the selection.
    func run(_ action: any QuickAction, copyOnly: Bool = false) {
        guard let resolved = input, action.accepts(resolved.input) else {
            Beep.play()
            return
        }
        let (service, preview) = (service, preview)
        palette().closeAndDeliver(copyOnly ? .copyOnly : .paste(.plainText)) { target in
            await service.run(
                action, input: resolved.input, isSensitive: resolved.isSensitive, preview: preview,
                delivery: Self.delivery(copyOnly: copyOnly, source: resolved.source, target: target))
        }
    }

    static func delivery(copyOnly: Bool, source: ResolvedActionInput.Source, target: NSRunningApplication?) -> ActionsService.Delivery {
        if copyOnly { return .copy }
        return source == .selection ? .replaceSelection(target) : .paste(target)
    }

    // MARK: - Preview

    private func updatePreview() {
        if list.selected?.id != optionsID {
            options = list.selected.map(service.options(for:)) ?? ActionOptionValues()
            optionsID = list.selected?.id
            // An option field of the previous action may have had focus.
            if loadedQuery != nil { palette().focusSearch() }
        }
        // A preview for the previous selection is no longer wanted.
        previewTask?.cancel()
        guard let action = list.selected, let resolved = input else {
            preview = nil
            return
        }
        let (input, options) = (resolved.input, options)
        guard action.accepts(input) else {
            preview = nil
            return
        }
        if let preview, preview.actionID == action.id, preview.input == input, preview.options == options { return }
        if action is TextAction, (input.text?.utf8.count ?? 0) <= ActionsService.syncPreviewLimit {
            preview = service.preview(action, input: input, options: options)
            return
        }
        guard action.isInstant else {
            preview = nil
            return
        }
        // With new options, the previous result stays until the new one is there.
        if preview?.actionID != action.id { preview = nil }
        let service = service
        previewTask = Task {
            let result = await service.previewAsync(action, input: input, options: options)
            guard !Task.isCancelled else { return }
            preview = result
        }
    }
}
