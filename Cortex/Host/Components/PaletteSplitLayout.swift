import SwiftUI

/// A list on the left and a preview card on the right (clips, snippets,
/// actions).
struct PaletteSplitLayout<List: View, Preview: View>: View {
    @ViewBuilder let list: () -> List
    @ViewBuilder let preview: () -> Preview
    @Environment(\.paletteStyle) private var style

    var body: some View {
        HStack(spacing: 0) {
            list()
                .frame(width: 440)
            if style == .classic { Divider() }
            preview()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .palettePreviewCard(style)
        }
    }
}
