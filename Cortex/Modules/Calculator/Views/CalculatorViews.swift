import SwiftUI
import CortexCore

/// The `=` scope: the ways to write the result, and how the query was read.
struct CalculatorView: View {
    let scope: CalculatorScope

    var body: some View {
        PaletteSplitLayout {
            PaletteList(list: scope.list, empty: emptyState, onActivate: { scope.choose($0) }) { row, shortcutNumber, isSelected in
                PaletteRow(
                    symbol: row.kind == .recent ? "clock.arrow.circlepath" : "equal",
                    title: row.text, subtitle: row.subtitle,
                    shortcutNumber: shortcutNumber, isSelected: isSelected)
            }
        } preview: {
            CalculatorPreviewView(scope: scope)
        }
    }

    private var emptyState: PaletteEmptyState {
        if let error = scope.error {
            return PaletteEmptyState(title: "No result", systemImage: "exclamationmark.triangle", description: error)
        }
        return PaletteEmptyState(
            title: scope.query.trimmingCharacters(in: .whitespaces).isEmpty ? "Calculate" : "Keep typing",
            systemImage: "plus.forwardslash.minus",
            description: "Arithmetic or a conversion: 1920/1080, sqrt(2) * pi, 3 in to cm, 20 °C to F.")
    }
}

/// The selected result large, with how the query was read and the exact
/// value; or why there is no result.
struct CalculatorPreviewView: View {
    let scope: CalculatorScope

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let error = scope.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.title3)
                    .foregroundStyle(.red)
            } else if let row = scope.list.selected {
                switch row.kind {
                case .recent:
                    caption(row.text)
                    if let subtitle = row.subtitle { result(subtitle) }
                case .value:
                    if let understood = scope.understood { caption(understood) }
                    result(row.text)
                    if let exact = scope.exact, exact != row.text {
                        Text("Exactly \(exact)")
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(3)
    }

    private func result(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 28, weight: .semibold).monospacedDigit())
            .lineLimit(2)
            .minimumScaleFactor(0.5)
            .textSelection(.enabled)
    }
}
