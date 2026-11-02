import SwiftUI
import CortexCore

/// The `:` scope: the emoji in a grid over the whole panel, and below it the
/// selected emoji large with its name, shortcodes and code points, and the
/// skin tone ⇥ cycles.
struct EmojiView: View {
    let scope: EmojiScope

    private var tone: EmojiSkinTone? { scope.settings.skinTone }

    var body: some View {
        PaletteGridLayout {
            PaletteGrid(
                grid: scope.grid,
                hasLoaded: scope.hasLoaded,
                empty: PaletteEmptyState(
                    title: "No matching emoji",
                    systemImage: "face.smiling",
                    description: "Search looks at names, keywords and shortcodes like :thumbsup:."),
                onSelect: { scope.select($0) },
                onActivate: { scope.choose($0) }
            ) { emoji in
                Text(emoji.character(tone: tone))
                    .font(.system(size: 28))
            }
        } detail: {
            let emoji = scope.selected
            DetailStrip(
                title: emoji?.name(in: scope.languages),
                caption: emoji.map(Self.details) ?? ""
            ) {
                Text(emoji?.character(tone: tone) ?? "")
                    .font(.system(size: 36))
            } accessory: {
                HStack(spacing: 6) {
                    Text("Skin tone")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(tone?.swatch ?? EmojiSkinTone.noneSwatch)
                        .font(.title3)
                }
            }
        }
    }

    private static func details(_ emoji: Emoji) -> String {
        // "+1" and "-1" are searchable but read oddly as a label.
        let shortcodes = emoji.shortcodes.filter { $0.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" } }
            .prefix(2).map { ":\($0):" }
        return (shortcodes + [emoji.codePoints]).joined(separator: "   ")
    }
}
