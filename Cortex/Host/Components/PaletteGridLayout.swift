import SwiftUI

/// A grid over the full width with a detail strip below it (emoji,
/// symbols).
struct PaletteGridLayout<Grid: View, Detail: View>: View {
    @ViewBuilder let grid: () -> Grid
    @ViewBuilder let detail: () -> Detail

    var body: some View {
        VStack(spacing: 0) {
            grid()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            detail()
        }
    }
}
