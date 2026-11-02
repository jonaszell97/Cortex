import SwiftUI

/// A row in a palette list: symbol, title, a caption below it, a badge (a
/// snippet's keyword) or a coloured tag (a project) and the ⌘1–9 number, in
/// the selection's colours when selected.
struct PaletteRow: View {
    let symbol: String
    let title: String
    var subtitle: String?
    var badge: String?
    /// Drawn instead of `badge`.
    var tag: TintedTag?
    let shortcutNumber: Int?
    let isSelected: Bool
    /// For a title that is typed, like `$port 3000`.
    var isTitleMonospaced = false
    /// Dimmed after the title: an example of what may follow it (`3000`
    /// in `$port 3000`), not something typed.
    var titleHint: String?
    /// The symbol's colour while not selected, instead of secondary.
    var symbolTint: Color?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(isSelected ? AnyShapeStyle(.white) : symbolTint.map(AnyShapeStyle.init) ?? AnyShapeStyle(.secondary))
                .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 2) {
                titleText
                    .fontDesign(isTitleMonospaced ? .monospaced : nil)
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .lineLimit(1)
                        .foregroundStyle(isSelected ? .white.opacity(0.8) : .secondary)
                }
            }

            Spacer(minLength: 4)

            if let tag {
                tag.selected(isSelected)
            } else if let badge {
                Text(badge)
                    .font(.caption.monospaced())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: .rect(cornerRadius: 4))
                    .foregroundStyle(isSelected ? .white : .secondary)
            }
            if let shortcutNumber {
                Text("⌘\(shortcutNumber)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(isSelected ? .white.opacity(0.8) : .secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .foregroundStyle(isSelected ? .white : .primary)
        .paletteSelection(isSelected)
    }

    private var titleText: Text {
        guard let titleHint, !titleHint.isEmpty else { return Text(title) }
        let hint = Text(" " + titleHint).foregroundStyle(isSelected ? AnyShapeStyle(.white.opacity(0.55)) : AnyShapeStyle(.tertiary))
        return Text("\(title)\(hint)")
    }

    /// The first line with something on it, for a caption.
    static func firstLine(of text: String) -> String {
        text.split(whereSeparator: \.isNewline).first { !$0.allSatisfy(\.isWhitespace) }.map(String.init) ?? ""
    }
}
