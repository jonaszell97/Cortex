import SwiftUI
import CortexCore

/// `:` in the palette: the emoji in a grid, the frequently used first. ⏎
/// pastes the selected one in the chosen skin tone, ⌥⏎ copies it; either
/// way it stays out of the history and the clipboard is put back.
@MainActor
@Observable
final class EmojiScope: PaletteScope {
    nonisolated static let columns = 14

    private(set) var grid = ResultGrid<Emoji>(columns: EmojiScope.columns)
    private(set) var hasLoaded = false
    /// Languages the emoji names are shown and searched in, best first.
    private(set) var languages = ["en"]
    let settings: EmojiSettings

    @ObservationIgnored private let palette: @MainActor () -> any PaletteHost
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var loadedQuery: String?

    init(settings: EmojiSettings, palette: @escaping @MainActor () -> any PaletteHost) {
        self.settings = settings
        self.palette = palette
    }

    var selected: Emoji? { grid.selected }

    func select(_ position: GridPosition?) {
        grid.select(position)
    }

    // MARK: - PaletteScope

    func search(_ text: String) {
        task?.cancel()
        let usage = settings.usage
        task = Task {
            // Building the catalog (on first use) and searching it stay off
            // the main actor.
            let (languages, sections) = await Task.detached {
                let catalog = EmojiCatalog.shared
                let languages = catalog.languages()
                return (languages, EmojiScope.sections(in: catalog, query: text, languages: languages, usage: usage))
            }.value
            guard !Task.isCancelled else { return }
            self.languages = languages
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

    var body: AnyView { AnyView(EmojiView(scope: self)) }

    var navigation: PaletteNavigation { .grid(columns: Self.columns) }

    func move(_ step: PaletteStep) {
        switch step {
        case .vertical(let delta): grid.moveVertically(by: delta)
        case .sideways(let delta): grid.moveSideways(by: delta)
        }
    }

    func activate(_ activation: PaletteActivation, target: PaletteTarget) -> Bool {
        let emoji = switch target {
        case .selected: grid.selected
        case .position(let index): grid.item(atFlatIndex: index)
        }
        guard let emoji else { return true }
        choose(emoji, copyOnly: activation.isCopy)
        return true
    }

    var activationHints: [PaletteHint] {
        [PaletteHint(.primary, "Paste"), PaletteHint(.option, "Copy")]
    }

    var keys: [PaletteKey] {
        [PaletteKey(.tab, hint: "Skin tone") { [settings] in
            settings.cycleSkinTone()
            return true
        }]
    }

    /// Pastes (or copies) an emoji in the chosen skin tone and counts the
    /// use. Pasting one does not lose what was copied before; copying one
    /// replaces it and adds the emoji to the clipboard history.
    func choose(_ emoji: Emoji, copyOnly: Bool = false) {
        let text = emoji.character(tone: settings.skinTone)
        palette().closeAndDeliver(
            .text(text), copyOnly ? .copyOnly : .paste(.plainText),
            recording: copyOnly ? .record(sensitive: false) : .skip, restoringPasteboard: true, after: nil)
        settings.recordUse(of: emoji)
    }

    // MARK: - Sections

    /// Without a query: the frequently used emoji, then every category.
    /// With one: the matches, best first, in a single section.
    nonisolated static func sections(
        in catalog: EmojiCatalog, query: String, languages: [String], usage: UsageRanking
    ) -> [GridSection<Emoji>] {
        guard query.allSatisfy({ $0 == ":" || $0.isWhitespace }) else {
            let matches = catalog.search(query, languages: languages, usage: usage)
            return matches.isEmpty ? [] : [GridSection(id: 0, title: nil, items: matches)]
        }
        var sections: [GridSection<Emoji>] = []
        let frequent = usage.top(columns).compactMap { catalog.emoji(for: $0) }
        if !frequent.isEmpty {
            sections.append(GridSection(id: 0, title: "Frequently used", items: frequent))
        }
        for group in EmojiGroup.allCases where !catalog.group(group).isEmpty {
            sections.append(GridSection(id: group.rawValue + 1, title: group.title, items: catalog.group(group)))
        }
        return sections
    }
}
