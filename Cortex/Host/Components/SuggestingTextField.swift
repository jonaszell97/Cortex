import SwiftUI

/// What was typed into a `SuggestingTextField` and which suggestion is
/// highlighted. The palette hands the arrow keys to the overlay before the
/// field sees them, so the owner keeps this and moves it.
struct SuggestingFieldState: Equatable {
    /// What was typed; the suggestions are filtered by it.
    private(set) var typed: String
    /// Index into the filtered suggestions; the field shows its value.
    private(set) var highlighted: Int?

    init(typed: String = "") {
        self.typed = typed
    }

    /// Typing replaces the highlighted value with what is in the field.
    mutating func type(_ text: String) {
        typed = text
        highlighted = nil
    }

    /// ↓ from the field moves into the `count` suggestions, ↑ past the
    /// first goes back to what was typed. false: nowhere to go, so the
    /// field gets the key.
    mutating func move(by delta: Int, count: Int) -> Bool {
        guard let highlighted else {
            guard delta > 0, count > 0 else { return false }
            self.highlighted = 0
            return true
        }
        let next = highlighted + delta
        if next < 0 {
            self.highlighted = nil
        } else {
            self.highlighted = min(next, count - 1)
        }
        return true
    }

    /// A click on a suggestion.
    mutating func pick(_ index: Int) {
        highlighted = index
    }

    /// The fewer suggestions after filtering: a highlight past them goes.
    mutating func clamp(to count: Int) {
        if let highlighted, highlighted >= count { self.highlighted = nil }
    }
}

/// A text field with suggestions listed under it (a `$` form's argument):
/// ↓ moves the highlight into the list and puts the highlighted value into
/// the field, typing filters the list, ↑ past the first goes back to what was
/// typed. The keys come from the owner's `SuggestingFieldState`; a click
/// picks a suggestion.
struct SuggestingTextField<Field: Hashable>: View {
    struct Suggestion: Identifiable, Equatable {
        var id: String
        /// Shown on one line.
        var title: String
        /// Where it is from: "Clipboard", "History · 2 min ago".
        var detail: String?
    }

    let title: String
    @Binding var text: String
    let prompt: String
    /// Several lines (a prompt) instead of one.
    var isMultiline = false
    /// A required field ⏎ found empty.
    var isMarked = false
    let suggestions: [Suggestion]
    let highlighted: Int?
    let focus: FocusState<Field?>.Binding
    let field: Field
    let onPick: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            textField
                .textFieldStyle(.plain)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(.background.opacity(0.6), in: .rect(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(isMarked ? AnyShapeStyle(.red) : AnyShapeStyle(.separator), lineWidth: isMarked ? 1.5 : 1))
                .focused(focus, equals: field)
            if !suggestions.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, suggestion in
                        row(suggestion, isHighlighted: index == highlighted)
                            .contentShape(.rect)
                            .onTapGesture { onPick(index) }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var textField: some View {
        if isMultiline {
            TextField(title, text: $text, prompt: Text(prompt), axis: .vertical)
                .lineLimit(3...6)
        } else {
            TextField(title, text: $text, prompt: Text(prompt))
        }
    }

    private func row(_ suggestion: Suggestion, isHighlighted: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: isHighlighted ? "arrowtriangle.right.fill" : "arrowtriangle.right")
                .font(.caption2)
                .foregroundStyle(isHighlighted ? AnyShapeStyle(.white) : AnyShapeStyle(.tertiary))
            Text(suggestion.title)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            if let detail = suggestion.detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(isHighlighted ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(.secondary))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .foregroundStyle(isHighlighted ? .white : .primary)
        .paletteSelection(isHighlighted)
    }
}
