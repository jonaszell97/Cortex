import SwiftUI
import CortexCore

/// A colour clip's swatch: the colour over a checkerboard (so transparency
/// shows), with a hairline border so white reads on a light background and
/// black on a dark one.
struct ColorSwatch: View {
    let color: ColorValue
    var cornerRadius: CGFloat = 4

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius)
        ZStack {
            if !color.isOpaque {
                Checkerboard()
            }
            Color(.sRGB, red: color.red, green: color.green, blue: color.blue, opacity: color.alpha)
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(.primary.opacity(0.2), lineWidth: 1))
    }
}

private struct Checkerboard: View {
    var body: some View {
        Canvas { context, size in
            let square: CGFloat = 6
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white))
            for row in 0..<Int((size.height / square).rounded(.up)) {
                for column in 0..<Int((size.width / square).rounded(.up)) where (row + column).isMultiple(of: 2) {
                    let rect = CGRect(x: CGFloat(column) * square, y: CGFloat(row) * square, width: square, height: square)
                    context.fill(Path(rect), with: .color(Color(white: 0.8)))
                }
            }
        }
    }
}

/// A colour clip in the preview pane: a large swatch and the colour in every
/// format, to select and copy.
struct ColorClipPreview: View {
    let color: ColorValue

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ColorSwatch(color: color, cornerRadius: 8)
                .frame(maxWidth: .infinity)
                .frame(height: 120)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                ForEach(Self.formats, id: \.self) { format in
                    GridRow {
                        Text(Self.label(format))
                            .foregroundStyle(.secondary)
                        Text(format.string(for: color))
                            .font(.body.monospaced())
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// Hex once; without `#` is the same value.
    static let formats: [ColorFormat] = [.hex, .rgb, .hsl, .swiftUI]

    static func label(_ format: ColorFormat) -> String {
        switch format {
        case .hex, .hexWithoutHash: "Hex"
        case .rgb: "RGB"
        case .hsl: "HSL"
        case .swiftUI: "SwiftUI"
        }
    }
}
