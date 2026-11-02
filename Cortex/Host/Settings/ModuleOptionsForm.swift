import AppKit
import SwiftUI

/// A module's declared options as rows of a grouped form, each with its
/// caption below.
struct ModuleOptionsForm: View {
    let options: [ModuleOption]
    /// For `.secret` options.
    let secrets: ModuleSecrets

    var body: some View {
        ForEach(options) { option in
            Group {
                row(option)
                if let help = option.help {
                    Text(help)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .disabled(!option.isEnabled())
        }
    }

    @ViewBuilder
    private func row(_ option: ModuleOption) -> some View {
        switch option.kind {
        case .toggle(let isOn):
            Toggle(option.title, isOn: isOn)
        case .integer(let value, let range, let unit):
            Stepper(value: value, in: range) {
                Text("\(option.title): \(value.wrappedValue)\(unit.map { " \($0)" } ?? "")")
            }
        case .choice(let selection, let choices):
            Picker(option.title, selection: selection) {
                ForEach(choices, id: \.value) { choice in
                    Text(choice.title).tag(choice.value)
                }
            }
        case .text(let text, let prompt):
            TextField(option.title, text: text, prompt: prompt.map { Text($0) })
        case .secret(let key):
            // A new account (AI's key follows its vendor) is a new row, not
            // the old one's state.
            SecretOptionRow(title: option.title, key: key, secrets: secrets)
                .id(key)
        case .folder(let url):
            LabeledContent(option.title) {
                HStack {
                    Text(url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .truncationMode(.middle)
                        .lineLimit(1)
                        .textSelection(.enabled)
                    Button {
                        NSWorkspace.shared.open(url)
                    } label: {
                        Image(systemName: "folder")
                    }
                    .buttonStyle(.borderless)
                    .help("Open the folder")
                }
            }
        case .button(let label, let role, let action):
            LabeledContent(option.title) {
                Button(label, role: role, action: action)
            }
        }
    }
}
