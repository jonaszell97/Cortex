import SwiftUI
import CortexCore

/// The `::` scope: the SF Symbols in a grid over the whole panel, and below
/// it the selected symbol with its name.
struct SymbolsView: View {
    let scope: SymbolsScope

    var body: some View {
        PaletteGridLayout {
            PaletteGrid(
                grid: scope.grid,
                hasLoaded: scope.hasLoaded,
                empty: scope.isCatalogEmpty
                    ? PaletteEmptyState(
                        title: "No symbol data",
                        systemImage: "exclamationmark.triangle",
                        description: "This version of macOS keeps its list of SF Symbols somewhere Cortex does not look.")
                    : PaletteEmptyState(
                        title: "No matching symbols",
                        systemImage: "star.slash",
                        description: "Search looks at names like star.fill and at the system's keywords."),
                onSelect: { scope.select($0) },
                onActivate: { scope.choose($0) }
            ) { symbol in
                Image(systemName: symbol.name)
                    .font(.system(size: 22))
            }
        } detail: {
            let symbol = scope.selected
            DetailStrip(
                title: symbol?.name,
                caption: symbol.map(Self.details) ?? "",
                titleFont: .headline.monospaced()
            ) {
                Image(systemName: symbol?.name ?? "")
                    .font(.system(size: 30))
            }
        }
    }

    private static func details(_ symbol: SFSymbol) -> String {
        var parts: [String] = []
        if let version = symbol.macOSVersion { parts.append("macOS \(version)+") }
        if !symbol.keywords.isEmpty { parts.append(symbol.keywords.prefix(6).joined(separator: ", ")) }
        return parts.joined(separator: "   ")
    }
}
