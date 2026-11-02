import SwiftUI

/// The palette styles side by side, each as a small sketch of the palette.
struct PaletteStylePicker: View {
    @Binding var selection: PaletteStyle

    var body: some View {
        LabeledContent("Style") {
            HStack(spacing: 14) {
                ForEach(PaletteStyle.allCases) { style in
                    Button {
                        selection = style
                    } label: {
                        VStack(spacing: 6) {
                            PaletteSketch(style: style)
                                .frame(width: 112, height: 70)
                                .overlay {
                                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                                        .strokeBorder(Color.accentColor, lineWidth: 2.5)
                                        .padding(-4)
                                        .opacity(selection == style ? 1 : 0)
                                }
                            Text(style.title)
                                .font(.caption)
                                .foregroundStyle(selection == style ? .primary : .secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(style.title)
                    .accessibilityAddTraits(selection == style ? .isSelected : [])
                }
            }
            .padding(.vertical, 4)
        }
    }
}

/// A search bar, a list with its selection, and a preview, in the style's colours.
private struct PaletteSketch: View {
    let style: PaletteStyle

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        VStack(alignment: .leading, spacing: 4) {
            bar(width: 70, opacity: 0.35)
            if style == .glass {
                LinearGradient(colors: [.clear, BrandColors.orchid, BrandColors.amber, .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(height: 1)
                    .opacity(0.7)
            } else {
                Divider()
            }
            HStack(alignment: .top, spacing: 5) {
                VStack(alignment: .leading, spacing: 3) {
                    selectedRow
                    bar(width: 40, opacity: 0.2)
                    bar(width: 46, opacity: 0.2)
                    bar(width: 36, opacity: 0.2)
                }
                .frame(width: 52, alignment: .leading)
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(.primary.opacity(style == .glass ? 0.1 : 0.06))
            }
        }
        .padding(7)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            switch style {
            case .classic:
                shape.fill(.background.secondary)
            case .glass:
                shape.fill(.background.secondary).overlay(GlassGradient().clipShape(shape))
            }
        }
        .overlay(shape.strokeBorder(style == .glass ? AnyShapeStyle(GlassRim.gradient) : AnyShapeStyle(.separator), lineWidth: 1))
    }

    @ViewBuilder
    private var selectedRow: some View {
        let row = RoundedRectangle(cornerRadius: 3, style: .continuous)
        switch style {
        case .classic: row.fill(Color.accentColor).frame(width: 50, height: 7)
        case .glass: row.fill(BrandColors.selection).frame(width: 50, height: 7)
        }
    }

    private func bar(width: CGFloat, opacity: Double) -> some View {
        Capsule().fill(.primary.opacity(opacity)).frame(width: width, height: 4)
    }
}
