import SwiftUI

extension EnvironmentValues {
    @Entry var paletteStyle: PaletteStyle = .classic
}

/// The colours of the app icon (Cortex/AppIcon.icon): the indigo to purple
/// background and the amber paperclip.
enum BrandColors {
    static let indigo = Color(red: 0.169, green: 0.165, blue: 0.478)
    static let purple = Color(red: 0.420, green: 0.247, blue: 0.627)
    static let amber = Color(red: 0.949, green: 0.702, blue: 0.239)

    /// Lighter versions for small, bright areas on the glass, such as the selection.
    static let violet = Color(red: 0.310, green: 0.270, blue: 0.760)
    static let orchid = Color(red: 0.560, green: 0.320, blue: 0.800)

    /// Amber that stays warm instead of turning olive over dark glass.
    static let brightAmber = Color(red: 1.0, green: 0.78, blue: 0.35)
    /// Amber that still shows on light glass.
    static let deepAmber = Color(red: 0.78, green: 0.50, blue: 0.08)

    static let selection = LinearGradient(colors: [violet, orchid], startPoint: .leading, endPoint: .trailing)

    /// For small accents such as the search field's magnifier.
    static func accent(_ colorScheme: ColorScheme) -> LinearGradient {
        colorScheme == .dark
            ? LinearGradient(colors: [orchid, amber], startPoint: .topLeading, endPoint: .bottomTrailing)
            : LinearGradient(colors: [purple, deepAmber], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

extension View {
    /// The palette's panel: glass in the given style's shape, with the
    /// icon's gradient over it in the glass style.
    func palettePane(_ style: PaletteStyle) -> some View {
        modifier(PalettePane(style: style))
    }

    /// In the glass style the preview sits on its own lighter pane, inset
    /// from the list next to it.
    func palettePreviewCard(_ style: PaletteStyle) -> some View {
        modifier(PreviewCard(style: style))
    }

    /// A key in the key hints; drawn as a keycap in the glass style.
    func paletteKeycap(_ style: PaletteStyle) -> some View {
        modifier(Keycap(style: style))
    }

    /// The search field's magnifier: grey, or in the icon's colours.
    func paletteSearchIcon(_ style: PaletteStyle) -> some View {
        modifier(SearchIcon(style: style))
    }

    /// The highlight behind a selected row or grid cell.
    func paletteSelection(_ isSelected: Bool, cornerRadius: CGFloat = 8) -> some View {
        modifier(PaletteSelection(isSelected: isSelected, cornerRadius: cornerRadius))
    }
}

private struct PalettePane: ViewModifier {
    let style: PaletteStyle
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        switch style {
        case .classic:
            content.glassPane(cornerRadius: 20)
        case .glass:
            // Circular corners, to match the frosted backdrop's mask exactly.
            let radius: CGFloat = 26
            let shape = RoundedRectangle(cornerRadius: radius)
            content
                .background(GlassGradient())
                .background(FrostedBackdrop(cornerRadius: radius))
                .clipShape(shape)
                // In light mode a faint dark hairline keeps the edge visible
                // over white windows (dark mode has the window's own outline);
                // the light rim on top of it catches the light.
                .overlay(shape.strokeBorder(.black.opacity(colorScheme == .dark ? 0 : 0.1), lineWidth: 0.5))
                .overlay(shape.strokeBorder(GlassRim.gradient, lineWidth: 1))
        }
    }
}

/// The icon's colours as soft light under the frosted surface: indigo in the
/// top left, purple on the right and an amber glow in the bottom right corner,
/// clear in the middle so the text stays readable. Dark mode keeps the colour
/// in the corners, where it would otherwise mix with the backdrop into brown;
/// light mode keeps it fainter behind the search field.
struct GlassGradient: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        MeshGradient(
            width: 3, height: 3,
            points: [
                [0, 0], [0.55, 0], [1, 0],
                [0, 0.5], [0.45, 0.55], [1, 0.45],
                [0, 1], [0.6, 1], [1, 1],
            ],
            colors: colorScheme == .dark ? Self.dark : Self.light)
            .opacity(colorScheme == .dark ? 0.5 : 0.32)
    }

    private static let dark: [Color] = [
        BrandColors.indigo, BrandColors.indigo.opacity(0.55), BrandColors.purple.opacity(0.8),
        BrandColors.indigo.opacity(0.35), .clear, BrandColors.purple.opacity(0.4),
        BrandColors.purple.opacity(0.3), BrandColors.brightAmber.opacity(0.06), BrandColors.brightAmber.opacity(0.3),
    ]

    private static let light: [Color] = [
        BrandColors.indigo.opacity(0.8), BrandColors.indigo.opacity(0.4), BrandColors.purple.opacity(0.8),
        BrandColors.indigo.opacity(0.35), .clear, BrandColors.purple.opacity(0.55),
        BrandColors.purple.opacity(0.45), BrandColors.amber.opacity(0.12), BrandColors.amber.opacity(0.55),
    ]
}

/// A light edge along the top left that fades out and picks up the icon's
/// purple at the bottom right, like light caught by the rim of a glass pane.
enum GlassRim {
    static let gradient = LinearGradient(
        colors: [.white.opacity(0.55), .white.opacity(0.08), BrandColors.orchid.opacity(0.45)],
        startPoint: .topLeading, endPoint: .bottomTrailing)
}

private struct PaletteSelection: ViewModifier {
    let isSelected: Bool
    let cornerRadius: CGFloat
    @Environment(\.paletteStyle) private var style
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        switch style {
        case .classic:
            content.background(isSelected ? Color.accentColor : .clear, in: .rect(cornerRadius: cornerRadius))
        case .glass:
            content
                // Glyph cells take the default style; rows set their own.
                .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                .background {
                    if isSelected {
                        let shape = RoundedRectangle(cornerRadius: cornerRadius + 2, style: .continuous)
                        // Slightly see-through, with light on its upper half,
                        // so it reads as tinted glass rather than paint.
                        shape
                            .fill(BrandColors.selection.opacity(colorScheme == .dark ? 0.95 : 0.94))
                            .overlay(shape.fill(LinearGradient(
                                colors: [.white.opacity(colorScheme == .dark ? 0.12 : 0.08), .clear], startPoint: .top, endPoint: .center)))
                            .overlay(shape.strokeBorder(
                                LinearGradient(colors: [.white.opacity(0.45), .white.opacity(0.05)], startPoint: .top, endPoint: .bottom),
                                lineWidth: 0.75))
                            .shadow(color: BrandColors.purple.opacity(0.3), radius: 6, y: 2)
                    }
                }
        }
    }
}

private struct PreviewCard: ViewModifier {
    let style: PaletteStyle
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        switch style {
        case .classic:
            content
        case .glass:
            let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
            let dark = colorScheme == .dark
            content
                .background(.white.opacity(dark ? 0.08 : 0.3), in: shape)
                .clipShape(shape)
                .overlay(shape.strokeBorder(
                    dark
                        ? AnyShapeStyle(LinearGradient(colors: [.white.opacity(0.22), .white.opacity(0.06)], startPoint: .top, endPoint: .bottom))
                        : AnyShapeStyle(.white.opacity(0.45)),
                    lineWidth: dark ? 0.75 : 0.5))
                .padding([.vertical, .trailing], 10)
                .padding(.leading, 2)
        }
    }
}

private struct Keycap: ViewModifier {
    let style: PaletteStyle
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        switch style {
        case .classic:
            content
        case .glass:
            let shape = RoundedRectangle(cornerRadius: 5, style: .continuous)
            let dark = colorScheme == .dark
            content
                .foregroundStyle(.primary)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(.white.opacity(dark ? 0.1 : 0.45), in: shape)
                .overlay(shape.strokeBorder(dark ? AnyShapeStyle(.white.opacity(0.16)) : AnyShapeStyle(.primary.opacity(0.18)), lineWidth: 0.5))
                // A raised key in light mode.
                .shadow(color: .black.opacity(dark ? 0 : 0.08), radius: 0, y: 0.5)
        }
    }
}

private struct SearchIcon: ViewModifier {
    let style: PaletteStyle
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        switch style {
        case .classic: content.foregroundStyle(.secondary)
        case .glass: content.foregroundStyle(BrandColors.accent(colorScheme))
        }
    }
}

/// A line between the palette's areas. In the glass style it is a faint
/// hairline, and under the search field it carries the icon's colours.
struct PaletteDivider: View {
    enum Kind { case plain, accent }

    var kind: Kind = .plain
    @Environment(\.paletteStyle) private var style
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        switch style {
        case .classic:
            Divider()
        case .glass:
            switch kind {
            case .plain where colorScheme == .dark:
                Rectangle().fill(.white.opacity(0.08)).frame(height: 1)
            case .plain:
                Divider().opacity(0.5)
            case .accent:
                LinearGradient(
                    colors: [
                        .clear, BrandColors.orchid.opacity(0.7),
                        (colorScheme == .dark ? BrandColors.amber : BrandColors.deepAmber).opacity(0.6), .clear,
                    ],
                    startPoint: .leading, endPoint: .trailing)
                    .frame(height: 1)
            }
        }
    }
}
