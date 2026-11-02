import SwiftUI
import CortexCore

/// `:` in the palette: emoji in a grid, searched by name, keyword and
/// shortcode in English and the system language, pasted without touching the
/// clipboard history.
@MainActor
final class EmojiModule: CortexModule {
    static let manifest = ModuleManifest(
        id: "emoji", name: "Emoji", summary: "Search and paste emoji by name, keyword or shortcode.",
        symbol: "face.smiling", trigger: .prefix(":"), placeholder: "emoji",
        permissions: [.accessibility], order: 40)

    private let settings: EmojiSettings
    private let scope: EmojiScope

    init(context: ModuleContext) {
        let settings = EmojiSettings(defaults: context.defaults.store)
        self.settings = settings
        scope = EmojiScope(settings: settings) { [context] in context.palette }
    }

    var palette: (any PaletteScope)? { scope }

    var options: [ModuleOption] {
        let tones = [(value: "0", title: "\(EmojiSkinTone.noneSwatch) Default")]
            + EmojiSkinTone.allCases.map { (value: String($0.rawValue), title: $0.swatch) }
        let selection = Binding(
            get: { [settings] in String(settings.skinTone?.rawValue ?? 0) },
            set: { [settings] in settings.skinTone = Int($0).flatMap(EmojiSkinTone.init(rawValue:)) })
        return [
            ModuleOption(
                id: "skinTone", title: "Skin tone", help: "⇥ in the palette changes it too.",
                kind: .choice(selection, tones)),
        ]
    }

    func stop() {
        scope.clear()
    }
}
