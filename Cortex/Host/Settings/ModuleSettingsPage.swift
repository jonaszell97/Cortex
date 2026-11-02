import KeyboardShortcuts
import SwiftUI

/// A module's page in Settings: what it is and its switch, its hotkeys, its
/// options and its own view. While the module is off or cannot run, its
/// settings are greyed out but stay visible, so they can be set before
/// switching it on; the page says why it cannot run.
struct ModuleSettingsPage: View {
    let module: any CortexModule
    let host: ModuleHost

    private var manifest: ModuleManifest { ModuleHost.manifest(of: module) }

    /// Shown while the module is switched on but cannot run, or can never run
    /// here (no database).
    private var unavailableReason: String? {
        guard host.isEnabled(manifest.id) || !host.canEnable(manifest.id) else { return nil }
        return host.unavailableReason(manifest.id)
    }

    var body: some View {
        let isActive = host.isActive(manifest.id)
        Form {
            Section {
                ModuleSettingsHeader(manifest: manifest, unavailableReason: unavailableReason)
                Toggle("Enabled", isOn: Binding(
                    get: { host.isEnabled(manifest.id) && host.canEnable(manifest.id) },
                    set: { host.setEnabled(manifest.id, $0) }))
                    .disabled(!host.canEnable(manifest.id))
            }
            Group {
                let hotkeys = module.hotkeys
                if !hotkeys.isEmpty {
                    Section("Shortcuts") {
                        ForEach(hotkeys, id: \.name.rawValue) { hotkey in
                            ShortcutRecorder(hotkey.title, name: hotkey.name)
                            if let help = hotkey.help {
                                Text(help)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                let options = module.options
                if !options.isEmpty {
                    Section {
                        ModuleOptionsForm(options: options, secrets: host.secrets(for: manifest.id))
                    }
                }
                module.settingsView
            }
            .disabled(!isActive)
        }
        .formStyle(.grouped)
    }
}

/// Symbol, name, summary and trigger, and why the module cannot run.
private struct ModuleSettingsHeader: View {
    let manifest: ModuleManifest
    let unavailableReason: String?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: manifest.symbol)
                .font(.title2)
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(Color.accentColor.gradient, in: .rect(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 3) {
                Text(manifest.name)
                    .font(.headline)
                Text(manifest.summary)
                    .foregroundStyle(.secondary)
                if let trigger = triggerText {
                    Text(trigger)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let unavailableReason {
                    Label(unavailableReason, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var triggerText: String? {
        let more = manifest.subscopes.map { " \($0.trigger) for \($0.placeholder ?? "more")" }.joined(separator: ",")
        return switch manifest.trigger {
        case .default: "Shown when the palette opens."
        case .prefix(let prefix) where more.isEmpty: "Type \(prefix) in the palette."
        case .prefix(let prefix): "Type \(prefix) in the palette,\(more)."
        case nil: nil
        }
    }
}
