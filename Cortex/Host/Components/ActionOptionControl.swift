import SwiftUI
import CortexCore

/// The control for one action option: a segmented choice, a number field
/// or a short text field. The `>` pane's options and a `$` form use it.
struct ActionOptionControl: View {
    let option: ActionOption
    let value: String
    let onChange: (String) -> Void

    var body: some View {
        switch option.kind {
        case .choice(let choices):
            Picker(option.title, selection: binding()) {
                ForEach(choices, id: \.value) { choice in
                    Text(choice.title).tag(choice.value)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        case .number:
            TextField(option.title, text: binding(), prompt: Text(option.defaultValue))
                .labelsHidden()
                .font(.body.monospacedDigit())
                .frame(width: 72)
        case .text(let maxLength):
            TextField(option.title, text: binding(maxLength: maxLength), prompt: Text(option.defaultValue))
                .labelsHidden()
                .font(.body.monospaced())
                .frame(width: maxLength.map { $0 <= 3 ? 72 : 200 } ?? 200)
        }
    }

    /// Typing into a full field keeps the last characters, so a
    /// one-character field takes whatever is typed next.
    private func binding(maxLength: Int? = nil) -> Binding<String> {
        Binding(
            get: { value },
            set: { value in
                if let maxLength, value.count > maxLength {
                    onChange(String(value.suffix(maxLength)))
                } else {
                    onChange(value)
                }
            })
    }
}
