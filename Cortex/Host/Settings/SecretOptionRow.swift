import SwiftUI

/// The state of one `.secret` option: whether it is saved, and what is being
/// typed. The saved value is never read back into the field.
@MainActor
@Observable
final class SecretOption {
    let key: ModuleSecretKey
    /// What is typed, until it is saved.
    var draft = ""
    private(set) var isSet: Bool
    /// Why the Keychain refused the last save or removal.
    private(set) var error: String?
    @ObservationIgnored private let secrets: ModuleSecrets

    init(key: ModuleSecretKey, secrets: ModuleSecrets) {
        self.key = key
        self.secrets = secrets
        isSet = secrets.isSet(key)
    }

    /// Saves what was typed, without surrounding whitespace. Nothing typed
    /// saves nothing (Remove clears a value).
    func save() {
        let value = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        do {
            try secrets.set(value, for: key)
            draft = ""
            error = nil
        } catch {
            self.error = "The Keychain refused it: \(error.localizedDescription)"
        }
        isSet = secrets.isSet(key)
    }

    func remove() {
        do {
            try secrets.remove(key)
            error = nil
        } catch {
            self.error = "The Keychain refused it: \(error.localizedDescription)"
        }
        isSet = secrets.isSet(key)
    }
}

/// A secure field with "Saved" or "Not set", Save and Remove.
struct SecretOptionRow: View {
    let title: String
    @State private var option: SecretOption

    init(title: String, key: ModuleSecretKey, secrets: ModuleSecrets) {
        self.title = title
        _option = State(initialValue: SecretOption(key: key, secrets: secrets))
    }

    var body: some View {
        LabeledContent(title) {
            HStack {
                SecureField(title, text: $option.draft, prompt: Text(option.isSet ? "Saved" : "Not set"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
                    .onSubmit { option.save() }
                Button("Save") { option.save() }
                    .disabled(option.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Remove", role: .destructive) { option.remove() }
                    .disabled(!option.isSet)
            }
        }
        if let error = option.error {
            Text(error)
                .font(.caption)
                .foregroundStyle(.red)
        }
    }
}
