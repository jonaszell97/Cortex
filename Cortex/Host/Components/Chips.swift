import SwiftUI

/// The capsule around a chip: a value such as a keyword or a tag, or (dashed)
/// a field that adds one. The snippet and knowledge editors use them.
struct ChipStyle: ViewModifier {
    var dashed = false

    func body(content: Content) -> some View {
        content
            .font(.callout)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background {
                if dashed {
                    Capsule().strokeBorder(.tertiary, style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                } else {
                    Capsule().fill(.quaternary)
                }
            }
    }
}

extension View {
    func chip(dashed: Bool = false) -> some View {
        modifier(ChipStyle(dashed: dashed))
    }
}

/// Lays the chips out left to right, wrapping onto new lines.
struct ChipLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(for: subviews, width: proposal.width ?? .infinity)
        let width = rows.map { $0.reduce(0) { $0 + $1.width } + spacing * CGFloat(max($0.count - 1, 0)) }.max() ?? 0
        let height = rows.map { $0.map(\.height).max() ?? 0 }.reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        var index = 0
        for row in rows(for: subviews, width: bounds.width) {
            let height = row.map(\.height).max() ?? 0
            var x = bounds.minX
            for size in row {
                subviews[index].place(
                    at: CGPoint(x: x, y: y + height / 2), anchor: .leading, proposal: ProposedViewSize(size))
                x += size.width + spacing
                index += 1
            }
            y += height + spacing
        }
    }

    /// The subviews' sizes, split into rows that fit `width`.
    private func rows(for subviews: Subviews, width: CGFloat) -> [[CGSize]] {
        var rows: [[CGSize]] = [[]]
        var x: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + spacing + size.width > width {
                rows.append([])
                x = 0
            }
            x += (x > 0 ? spacing : 0) + size.width
            rows[rows.count - 1].append(CGSize(width: min(size.width, width), height: size.height))
        }
        return rows
    }
}
