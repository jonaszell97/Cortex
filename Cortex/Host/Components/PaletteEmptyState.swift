import SwiftUI

/// What an empty list or grid says instead: no history yet, no matches.
struct PaletteEmptyState: View {
    let title: String
    let systemImage: String
    let description: String

    var body: some View {
        ContentUnavailableView(title, systemImage: systemImage, description: Text(description))
    }
}
