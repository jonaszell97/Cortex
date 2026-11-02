import SwiftUI

/// A small label in a colour of its own (a project's): symbol and title on a
/// muted, glassy tint of the colour, so a list of them stays calm. On a
/// selected palette row it turns white like the row's text.
///
/// Shared with the iOS app (project.yml), so SwiftUI only.
struct TintedTag: View {
    let title: String
    var symbol: String?
    let tint: Color
    var isSelected = false

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 4) {
            if let symbol {
                Image(systemName: symbol)
                    .imageScale(.small)
                    .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(tint))
            }
            Text(title)
                .lineLimit(1)
                .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(textColor))
        }
        .font(.caption)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background { TintedTagBackground(tint: isSelected ? .white : tint, isDark: colorScheme == .dark, isSelected: isSelected) }
    }

    func selected(_ isSelected: Bool) -> TintedTag {
        var tag = self
        tag.isSelected = isSelected
        return tag
    }

    /// The colour pulled towards the text colour, so it reads as a hint.
    private var textColor: Color {
        tint.mix(with: colorScheme == .dark ? .white : .black, by: 0.45)
    }
}

/// A faint wash of the tint, a highlight along the top edge and a hairline
/// rim: glass without the cost (or the blur on blur) of a material per row.
struct TintedTagBackground: View {
    let tint: Color
    let isDark: Bool
    var isSelected = false

    var body: some View {
        Capsule()
            .fill(tint.opacity(isSelected ? 0.2 : isDark ? 0.2 : 0.13))
            .overlay {
                Capsule().fill(LinearGradient(
                    colors: [.white.opacity(isDark ? 0.1 : 0.35), .white.opacity(0)],
                    startPoint: .top, endPoint: .center))
            }
            .overlay {
                Capsule().strokeBorder(tint.opacity(isSelected ? 0.35 : isDark ? 0.3 : 0.25), lineWidth: 0.5)
            }
    }
}
