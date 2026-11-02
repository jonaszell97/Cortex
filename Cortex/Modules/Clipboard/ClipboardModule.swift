import AppKit
import SwiftUI
import CortexCore

/// The clipboard history: records what is copied (apart from what Cortex
/// writes or borrows itself), keeps it as long as the retention settings say,
/// and is what the palette shows without a trigger.
@MainActor
final class ClipboardModule: CortexModule, ClipboardAPI, SyncContributing {
    static let manifest = ModuleManifest(
        id: "clipboard", name: "Clipboard", summary: "Keeps a searchable history of what you copy.",
        symbol: "doc.on.clipboard", trigger: .default, placeholder: "clipboard",
        requirements: [.database], permissions: [.accessibility], order: 10)

    /// nil without the database.
    let service: ClipboardService?
    private let scope: ClipboardScope?

    init(context: ModuleContext) {
        let service = context.database.map { database in
            ClipboardService(
                database: database, settings: ClipboardSettings(defaults: context.defaults.store),
                pasting: context.pasting, pasteboardActivity: context.pasteboard)
        }
        self.service = service
        scope = service.map { service in
            ClipboardScope(
                service: service,
                snippets: { [context] in context.api(SnippetsAPI.self) },
                actions: { [context] in context.api(ActionsAPI.self) },
                palette: { [context] in context.palette })
        }
    }

    var palette: (any PaletteScope)? { scope }

    var options: [ModuleOption] {
        guard let settings = service?.settings else { return [] }
        let bindable = Bindable(settings)
        return [
            ModuleOption(id: "paused", title: "Pause recording", kind: .toggle(bindable.isPaused)),
            ModuleOption(
                id: "plainByDefault", title: "Paste as plain text by default",
                help: settings.pastePlainByDefault
                    ? "⏎ pastes plain text, ⇧⏎ pastes with formatting."
                    : "⏎ pastes with formatting, ⇧⏎ pastes plain text.",
                kind: .toggle(bindable.pastePlainByDefault)),
            ModuleOption(
                id: "recognizeImageText", title: "Search text in images",
                help: "Screenshots and other images are found by the text in them. It is read on this Mac, offline, and stays here.",
                kind: .toggle(bindable.recognizeImageText)),
        ]
    }

    var settingsView: AnyView? {
        service.map { AnyView(ClipboardSettingsView(settings: $0.settings, clipboard: $0)) }
    }

    /// Pause Recording and Clear History…
    func statusMenuItems() -> [StatusMenuItem] {
        guard let service else { return [] }
        let settings = service.settings
        return [
            StatusMenuItem("Pause Recording", state: settings.isPaused ? .on : .off) { settings.isPaused.toggle() },
            StatusMenuItem("Clear History…") { Self.confirmClearing(service) },
        ]
    }

    /// A pause symbol while recording is paused, so it is not forgotten.
    var statusIcon: StatusIcon? {
        guard service?.settings.isPaused == true,
              let image = NSImage(systemSymbolName: "pause.circle", accessibilityDescription: nil)
        else { return nil }
        return StatusIcon(image: image, accessibilityLabel: "Cortex (recording paused)", priority: 0)
    }

    private static func confirmClearing(_ service: ClipboardService) {
        let alert = NSAlert()
        alert.messageText = "Clear the clipboard history?"
        alert.informativeText = "Pinned items are kept. This cannot be undone."
        alert.addButton(withTitle: "Clear History")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        NSApp.activate()
        let confirmed = alert.runModal() == .alertFirstButtonReturn
        NSApp.yieldActivationIfNoWindows(besides: alert.window)
        if confirmed {
            Task { await service.clearHistory() }
        }
    }

    func start() async {
        guard let service else { return }
        service.onChange = { [weak scope] in scope?.historyDidChange() }
        service.start()
    }

    func stop() {
        service?.stop()
        service?.onChange = nil
        scope?.clear()
    }

    // MARK: - ClipboardAPI

    func recentTexts(upTo maxOffset: Int) async -> [Int: String] {
        await service?.recentTexts(upTo: maxOffset) ?? [:]
    }

    func recentTexts(limit: Int) async -> [RecentClipText] {
        await service?.recentTexts(limit: limit) ?? []
    }

    var detectsSensitiveText: Bool {
        service?.settings.detectSensitiveText ?? true
    }

    // MARK: - SyncContributing

    var syncContributions: [SyncContribution] {
        service.map { [Self.syncContribution(for: $0)] } ?? []
    }

    /// Clips, with the sensitive-clip and size settings; arriving clips
    /// refresh the palette.
    static func syncContribution(for service: ClipboardService) -> SyncContribution {
        let settings = service.settings
        let bindable = Bindable(settings)
        return SyncContribution(
            collection: .clip, title: "Clipboard history", toggleKey: "syncClips",
            options: [
                ModuleOption(
                    id: "sensitive", title: "Sensitive clips",
                    help: "Passwords and other sensitive clips stay on this Mac unless this is on (on both Macs). They are encrypted end to end like everything else.",
                    kind: .toggle(bindable.syncSensitive)),
                ModuleOption(
                    id: "maxClipMB", title: "Largest clip",
                    help: "Larger clips, copied files, retention purges and Clear History never leave this Mac.",
                    kind: .integer(bindable.syncMaxClipMB, range: ClipboardSettings.syncMaxClipMBRange, unit: "MB")),
            ],
            makeHandler: { ClipSyncHandler(store: service.store, options: settings.clipSyncOptions) },
            needsRestart: { old, new in
                (new.toggles["sensitive"] == true && old.toggles["sensitive"] != true)
                    || (new.integers["maxClipMB"] ?? 0) > (old.integers["maxClipMB"] ?? 0)
            },
            waitUntilReady: { await service.waitUntilReady() },
            didApplyRemoteChanges: { service.remoteChangesApplied() })
    }
}
