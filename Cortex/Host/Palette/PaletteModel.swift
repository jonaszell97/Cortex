import AppKit

/// State of the palette: the query, which module's scope it goes to
/// (`PaletteRouting`), and an overlay over the scope. Everything else
/// belongs to the scopes.
@MainActor
@Observable
final class PaletteModel {
    /// The enabled modules' routes, in manifest order.
    private(set) var routes: [PaletteRoute]
    /// "Search clipboard · ;snippets · …"
    private(set) var placeholder: String

    var query = "" {
        didSet { if query != oldValue { route() } }
    }

    /// The module the query goes to; nil when no trigger matches and there
    /// is no default module.
    private(set) var activeModule: ModuleID?
    /// The query without the trigger (or the escaping backslash).
    private(set) var searchText = ""
    /// Takes over the pane: the search field is disabled until it is gone.
    /// Whatever takes an overlay away (Esc, another module, showing or
    /// hiding the palette) tells it through `dismissed`, once.
    var overlay: PaletteOverlay? {
        didSet {
            guard let oldValue else { return }
            if overlay == nil { focusRequest += 1 }
            oldValue.dismissed?()
        }
    }
    /// Bumped to move focus back to the search field.
    private(set) var focusRequest = 0
    /// The scopes searched since the palette was shown, cleared when it hides.
    @ObservationIgnored private var usedScopes: [ModuleID: any PaletteScope] = [:]

    /// The active module's scope; nil when no trigger matches and there is
    /// no default module.
    var activeScope: (any PaletteScope)? {
        routes.first { $0.id == activeModule }?.scope
    }

    /// Bumped on every show so the view moves focus back to the search field.
    private(set) var showCount = 0

    /// Files dropped onto the palette: true if a module took them.
    @ObservationIgnored var onDropFiles: (([URL]) -> Bool)?

    init(routes: [PaletteRoute]) {
        self.routes = routes
        placeholder = PaletteRouting.placeholder(for: routes)
        route()
    }

    /// Modules were switched on or off while the palette is hidden: drops
    /// what the scopes loaded and routes the query again, without searching.
    func setRoutes(_ routes: [PaletteRoute]) {
        clear()
        self.routes = routes
        placeholder = PaletteRouting.placeholder(for: routes)
        let (route, text) = PaletteRouting.resolve(query, in: routes)
        activeModule = route?.id
        searchText = text
    }

    func prepareForShow() {
        overlay = nil
        showCount += 1
        if query.isEmpty {
            reload()
        } else {
            query = ""
        }
    }

    /// Shows a module's scope: the query becomes its trigger followed by
    /// `text`, or the scope searches again if it already is.
    func open(_ id: ModuleID, searching text: String = "") {
        overlay = nil
        guard let route = routes.first(where: { $0.id == id }) else { return }
        let trigger = switch route.trigger {
        case .default: ""
        case .prefix(let prefix): prefix
        }
        if query == trigger + text {
            reload()
        } else {
            query = trigger + text
        }
    }

    private func route() {
        let (route, text) = PaletteRouting.resolve(query, in: routes)
        if route?.id != activeModule {
            activeScope?.didLeave()
        }
        activeModule = route?.id
        searchText = text
        reload()
    }

    // MARK: - Keys

    /// A key for the active module's scope or the overlay. false: the
    /// search field gets it.
    func handle(_ event: PaletteKeyEvent) -> Bool {
        if let overlay {
            switch event {
            case .activate(let activation, _):
                overlay.activate(activation)
                return true
            case .combo(let combo):
                if Self.perform(combo, in: overlay.keys) { return true }
                guard let activation = combo.returnActivation else { return false }
                overlay.activate(activation)
                return true
            case .move(let step):
                return overlay.move?(step) ?? false
            }
        }
        guard let scope = activeScope else { return false }
        switch event {
        case .combo(let combo):
            if Self.perform(combo, in: scope.keys) { return true }
            guard let activation = combo.returnActivation else { return false }
            return scope.activate(activation, target: .selected)
        case .move(.sideways) where scope.navigation == .list:
            return false
        case .move(let step):
            scope.move(step)
            return true
        case .activate(let activation, let target):
            return scope.activate(activation, target: target)
        }
    }

    private static func perform(_ combo: KeyCombo, in keys: [PaletteKey]) -> Bool {
        guard let key = keys.first(where: { $0.combo == combo }), let perform = key.perform else { return false }
        return perform()
    }

    /// Esc: leaves the overlay or whatever the scope has open. false: close
    /// the palette.
    func cancel() -> Bool {
        if let overlay {
            guard overlay.escape == .dismiss else { return false }
            self.overlay = nil
            return true
        }
        return activeScope?.cancel() ?? false
    }

    func modifiersChanged(_ flags: NSEvent.ModifierFlags) {
        activeScope?.modifiersChanged(flags)
    }

    /// What the hints bar shows for the overlay or the active scope.
    var hints: [PaletteHint] {
        if let overlay {
            return (overlay.currentHints?() ?? overlay.activationHints) + overlay.keys.compactMap(Self.hint)
                + [.escape(overlay.escape == .dismiss ? "Back" : "Close")]
        }
        guard let scope = activeScope else { return [] }
        var hints = scope.activationHints + scope.keys.compactMap(Self.hint)
        if case .grid = scope.navigation { hints.append(.move) }
        return hints
    }

    private static func hint(_ key: PaletteKey) -> PaletteHint? {
        key.hint.map { PaletteHint(keys: key.combo.label, label: $0) }
    }

    /// Back to the search field.
    func focusSearch() {
        focusRequest += 1
    }

    /// Drops everything loaded, so no clip content stays in memory while the
    /// palette is hidden.
    func clear() {
        overlay = nil
        for scope in usedScopes.values { scope.clear() }
        usedScopes = [:]
    }

    private func reload() {
        guard let activeModule, let scope = activeScope else { return }
        usedScopes[activeModule] = scope
        scope.search(searchText)
    }
}
