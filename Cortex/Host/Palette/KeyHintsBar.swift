import SwiftUI

/// The bottom of the palette: what the keys do in the active scope or
/// overlay.
struct KeyHintsBar: View {
    let hints: [PaletteHint]
    @Environment(\.paletteStyle) private var style

    var body: some View {
        HStack(spacing: style == .glass ? 14 : 16) {
            ForEach(hints, id: \.keys) { hint in
                HStack(spacing: 4) {
                    Text(hint.keys).fontWeight(.semibold).paletteKeycap(style)
                    Text(hint.label)
                }
            }
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .overlay(WindowDragArea())
    }
}
