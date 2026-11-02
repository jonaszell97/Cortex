import Foundation

/// `::` in the palette: this Mac's SF Symbols in a grid, pasted as their name
/// or as a picture.
@MainActor
final class SymbolsModule: CortexModule {
    static let manifest = ModuleManifest(
        id: "symbols", name: "SF Symbols", summary: "Search SF Symbols and paste a name or a picture.",
        symbol: "star.square.on.square", trigger: .prefix("::"), placeholder: "symbols",
        permissions: [.accessibility], order: 50)

    private let scope: SymbolsScope

    init(context: ModuleContext) {
        scope = SymbolsScope(settings: SymbolsSettings(defaults: context.defaults.store)) { [context] in context.palette }
    }

    var palette: (any PaletteScope)? { scope }

    func stop() {
        scope.clear()
    }
}
