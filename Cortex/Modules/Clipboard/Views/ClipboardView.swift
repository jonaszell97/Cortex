import SwiftUI
import CortexCore

/// The clipboard scope: the history on the left, the selected clip's
/// content on the right.
struct ClipboardView: View {
    let scope: ClipboardScope

    var body: some View {
        PaletteSplitLayout {
            PaletteList(
                list: scope.list,
                empty: scope.query.isEmpty
                    ? PaletteEmptyState(
                        title: "No clipboard history yet", systemImage: "clipboard",
                        description: "Copy something and it shows up here.")
                    : PaletteEmptyState(
                        title: "No matches", systemImage: "magnifyingglass",
                        description: "Try fewer or shorter words."),
                onActivate: { scope.choose($0) }
            ) { item, shortcutNumber, isSelected in
                ClipRowView(item: item, shortcutNumber: shortcutNumber, isSelected: isSelected, isRevealing: scope.isRevealing)
            }
        } preview: {
            ClipPreviewView(detail: scope.detail, isRevealing: scope.isRevealing)
        }
    }
}
