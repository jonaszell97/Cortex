import AppKit
import KeyboardShortcuts
import SwiftUI
import CortexCore

struct StorageInfo {
    var path: String?
    var cipherVersion: String?
    var migrations: [String] = []
    var error: String?

    @MainActor
    init(database: AppDatabase?, error: (any Error)?) {
        self.error = error.map { String(describing: $0) }
        guard let database else { return }
        path = database.url.path
        do {
            cipherVersion = try database.cipherVersion()
            migrations = try database.appliedMigrations()
        } catch {
            self.error = String(describing: error)
        }
    }
}

/// Settings → General: the host's own settings. Permissions lists only what
/// an active module asks for.
struct GeneralSettingsView: View {
    static let automationSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!

    let accessibility: AccessibilityPermission
    let launchAtLogin: LaunchAtLogin
    @Bindable var keepAwake: KeepAwake
    let storage: StorageInfo
    @Bindable var paletteSettings: PaletteSettings
    let host: ModuleHost

    /// What the active modules ask for.
    private var permissions: Set<ModulePermission> { host.activePermissions }
    /// What is wrong with the module manifests (docs/ARCHITECTURE.md, "The
    /// registry and manifest validation").
    private var moduleProblems: [String] { host.problems }

    var body: some View {
        Form {
            if !moduleProblems.isEmpty {
                Section("Modules") {
                    ForEach(moduleProblems, id: \.self) { problem in
                        Label(problem, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
            }

            Section("Palette") {
                ShortcutRecorder("Open palette:", name: .togglePalette)
                PaletteStylePicker(selection: $paletteSettings.style)
                LabeledContent("Position") {
                    Button("Reset to Centre") { paletteSettings.position = nil }
                        .disabled(paletteSettings.position == nil)
                }
                Text("Drag the palette by its search bar or the key hints at the bottom to move it. It opens where you leave it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("General") {
                Toggle("Launch at login", isOn: Binding(
                    get: { launchAtLogin.isEnabled },
                    set: { launchAtLogin.setEnabled($0) }))
                if launchAtLogin.requiresApproval {
                    HStack {
                        Text("Approve Cortex in Login Items to finish.")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Open Login Items") { launchAtLogin.openLoginItemsSettings() }
                    }
                }
                if let error = launchAtLogin.lastError {
                    Text(error).foregroundStyle(.red)
                }
                Toggle("Keep awake while running", isOn: $keepAwake.isEnabled)
                Text("Stops the Mac from going to sleep on its own while Cortex is running. The display can still turn off.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let error = keepAwake.lastError {
                    Text(error).foregroundStyle(.red)
                }
            }

            if !permissions.isEmpty {
                Section("Permissions") {
                    if permissions.contains(.accessibility) {
                        LabeledContent("Accessibility") {
                            if accessibility.isGranted {
                                Label("Granted", systemImage: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                            } else {
                                Button("Open System Settings") {
                                    accessibility.openSystemSettings()
                                }
                            }
                        }
                    }
                    if permissions.contains(.finderAutomation) {
                        LabeledContent("Finder automation") {
                            Button("Open System Settings") {
                                NSWorkspace.shared.open(Self.automationSettingsURL)
                            }
                        }
                        Text("macOS asks the first time quick actions read the files selected in Finder.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if permissions.contains(.screenRecording) {
                        LabeledContent("Screen Recording") {
                            if ScreenRecordingPermission.isGranted {
                                Label("Granted", systemImage: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                            } else {
                                Button("Open System Settings") { ScreenRecordingPermission.request() }
                            }
                        }
                        Text("Needed to read text on the screen. macOS applies it once Cortex is quit and opened again.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Storage") {
                if let path = storage.path {
                    LabeledContent("Database") {
                        HStack {
                            Text(path)
                                .truncationMode(.middle)
                                .lineLimit(1)
                                .textSelection(.enabled)
                            Button {
                                NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: path)])
                            } label: {
                                Image(systemName: "magnifyingglass.circle")
                            }
                            .buttonStyle(.borderless)
                            .help("Show in Finder")
                        }
                    }
                    LabeledContent("Encryption", value: storage.cipherVersion.map { "SQLCipher \($0)" } ?? "unknown")
                    LabeledContent("Schema", value: storage.migrations.last ?? "empty")
                }
                if let error = storage.error {
                    Text(error).foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
    }
}
