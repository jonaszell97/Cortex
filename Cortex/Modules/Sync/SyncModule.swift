import SwiftUI

/// Keeps clips, snippets, action files and the knowledge base in step across
/// Macs through the user's own server (docs/SYNC.md). A background add-on: it
/// carries what the active modules contribute (`SyncContributing`), tells
/// them when remote data arrived, and otherwise stays out of the way.
@MainActor
final class SyncModule: CortexModule {
    static let manifest = ModuleManifest(
        id: "sync", name: "Sync", summary: "Keeps clips, snippets, actions and notes in step across your Macs.",
        symbol: "arrow.triangle.2.circlepath", enabledByDefault: false, legacyEnabledKey: "syncEnabled",
        requirements: [.database], order: 70)

    /// nil without the database.
    let service: SyncService?
    private let context: ModuleContext
    private var isWatchingPalette = false

    init(context: ModuleContext) {
        self.context = context
        service = context.database.map { database in
            SyncService(
                database: database,
                settings: SyncSettings(defaults: context.defaults.store),
                secrets: context.secrets.store,
                contributions: { [context] in
                    context.apis(SyncContributing.self).flatMap(\.syncContributions)
                })
        }
    }

    var settingsView: AnyView? {
        service.map { AnyView(SyncSettingsView(sync: $0, secrets: context.secrets)) }
    }

    /// One line and "Sync Now", only while sync is set up. There are no
    /// alerts for sync errors: they show up here and in Settings (docs/SYNC.md,
    /// "The UI and status messages").
    func statusMenuItems() -> [StatusMenuItem] {
        guard let service, let line = service.status.menuLine(lastSuccess: service.lastSuccess) else { return [] }
        return [
            .line(line),
            StatusMenuItem("Sync Now", isEnabled: service.status != .syncing) { service.syncNow() },
        ]
    }

    func start() async {
        guard let service else { return }
        if !isWatchingPalette {
            isWatchingPalette = true
            context.palette.onShow { [weak service] in service?.paletteOpened() }
        }
        service.start()
    }

    func stop() {
        service?.stop()
    }
}
