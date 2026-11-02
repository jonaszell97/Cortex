import SwiftUI
import CortexCore

/// `::` in the palette: this Mac's SF Symbols in a grid, the frequently used
/// first. ⏎ pastes the name (`star.fill`), ⇧⏎ a picture of the symbol, ⌥
/// only copies; neither is recorded and the clipboard is put back.
@MainActor
@Observable
final class SymbolsScope: PaletteScope {
    nonisolated static let columns = 14

    private(set) var grid = ResultGrid<SFSymbol>(columns: SymbolsScope.columns)
    private(set) var hasLoaded = false
    let settings: SymbolsSettings

    @ObservationIgnored private let catalog: @Sendable () -> SymbolCatalog
    @ObservationIgnored private let palette: @MainActor () -> any PaletteHost
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var loadedQuery: String?

    init(
        settings: SymbolsSettings,
        catalog: @escaping @Sendable () -> SymbolCatalog = { SymbolCatalog.shared },
        palette: @escaping @MainActor () -> any PaletteHost
    ) {
        self.settings = settings
        self.catalog = catalog
        self.palette = palette
    }

    var selected: SFSymbol? { grid.selected }

    func select(_ position: GridPosition?) {
        grid.select(position)
    }

    /// No symbol data on this Mac (a later macOS moved it).
    var isCatalogEmpty: Bool {
        hasLoaded && catalog().isEmpty
    }

    // MARK: - PaletteScope

    func search(_ text: String) {
        task?.cancel()
        let usage = settings.usage
        let catalog = catalog
        task = Task {
            let sections = await Task.detached {
                SymbolsScope.sections(in: catalog(), query: text, usage: usage)
            }.value
            guard !Task.isCancelled else { return }
            grid.replace(with: sections, keepingSelection: text == loadedQuery)
            loadedQuery = text
            hasLoaded = true
        }
    }

    /// Waits for the search to finish (for tests).
    func loaded() async {
        await task?.value
    }

    func clear() {
        task?.cancel()
        grid.clear()
        loadedQuery = nil
        hasLoaded = false
    }

    var body: AnyView { AnyView(SymbolsView(scope: self)) }

    var navigation: PaletteNavigation { .grid(columns: Self.columns) }

    func move(_ step: PaletteStep) {
        switch step {
        case .vertical(let delta): grid.moveVertically(by: delta)
        case .sideways(let delta): grid.moveSideways(by: delta)
        }
    }

    func activate(_ activation: PaletteActivation, target: PaletteTarget) -> Bool {
        let symbol = switch target {
        case .selected: grid.selected
        case .position(let index): grid.item(atFlatIndex: index)
        }
        guard let symbol else { return true }
        choose(symbol, copyOnly: activation.isCopy, asImage: activation.hasShift)
        return true
    }

    var activationHints: [PaletteHint] {
        [
            PaletteHint(.primary, "Paste name"), PaletteHint(.shift, "Paste image"),
            PaletteHint(.option, "Copy name"), PaletteHint(.optionShift, "Copy image"),
        ]
    }

    /// Nothing else: ⇥ does nothing here rather than leave the search field.
    var keys: [PaletteKey] {
        [PaletteKey(.tab) { true }]
    }

    /// Pastes (or copies) a symbol's name or a picture of it and counts the
    /// use. A copy is added to the clipboard history.
    func choose(_ symbol: SFSymbol, copyOnly: Bool = false, asImage: Bool = false) {
        let content: PasteContent
        if asImage {
            guard let png = SymbolImage.png(for: symbol.name) else { return }
            content = .image(png)
        } else {
            content = .text(symbol.name)
        }
        palette().closeAndDeliver(
            content, copyOnly ? .copyOnly : .paste(.plainText),
            recording: copyOnly ? .record(sensitive: false) : .skip, restoringPasteboard: true, after: nil)
        settings.recordUse(of: symbol.name)
    }

    // MARK: - Sections

    /// Without a query: the frequently used symbols, then all of them in the
    /// order of SF Symbols. With one: the matches, best first.
    nonisolated static func sections(in catalog: SymbolCatalog, query: String, usage: UsageRanking) -> [GridSection<SFSymbol>] {
        guard query.allSatisfy({ $0 == ":" || $0.isWhitespace }) else {
            let matches = catalog.search(query, usage: usage)
            return matches.isEmpty ? [] : [GridSection(id: 0, title: nil, items: matches)]
        }
        var sections: [GridSection<SFSymbol>] = []
        let frequent = usage.top(columns).compactMap { catalog.symbol(named: $0) }
        if !frequent.isEmpty {
            sections.append(GridSection(id: 0, title: "Frequently used", items: frequent))
        }
        if !catalog.isEmpty {
            sections.append(GridSection(id: 1, title: "All symbols", items: catalog.symbols))
        }
        return sections
    }
}
