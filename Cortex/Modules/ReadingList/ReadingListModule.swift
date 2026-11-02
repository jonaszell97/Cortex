import AppKit
import SwiftUI
import CortexCore

/// `+` in the palette: links saved to read later. Paste a link after `+` to
/// add it, or add the one on the clipboard with ⌘N or from the status menu;
/// ⏎ opens a link in the browser and marks it read. Links sync between Macs
/// with the other data.
@MainActor
final class ReadingListModule: CortexModule, SyncContributing {
    static let manifest = ModuleManifest(
        id: "reading-list", name: "Reading List", summary: "Keeps links to read later and opens them from the palette.",
        symbol: "books.vertical", trigger: .prefix("+"), placeholder: "reading",
        requirements: [.database], order: 25)

    /// nil without the database.
    let service: ReadingListService?
    private let scope: ReadingListScope?
    private let context: ModuleContext
    private var isObservingRevision = false

    init(context: ModuleContext) {
        self.context = context
        let service = context.database.map { database in
            ReadingListService(database: database, settings: ReadingListSettings(defaults: context.defaults))
        }
        self.service = service
        scope = service.map { service in
            ReadingListScope(service: service, moduleID: context.id, palette: { [context] in context.palette })
        }
    }

    var palette: (any PaletteScope)? { scope }

    var options: [ModuleOption] {
        guard let service else { return [] }
        let settings = Bindable(service.settings)
        return [
            ModuleOption(
                id: "listRead", title: "List read links", help: "Below the unread ones. Searching always finds them.",
                kind: .toggle(settings.listRead)),
            ModuleOption(
                id: "deleteReadAfterDays", title: "Delete read links after",
                help: "0 keeps them. Only on this Mac: the other Mac keeps its own.",
                kind: .integer(settings.deleteReadAfterDays, range: 0...365, unit: "days")),
        ]
    }

    func statusMenuItems() -> [StatusMenuItem] {
        guard service != nil else { return [] }
        return [
            StatusMenuItem("Reading List") { [context] in context.palette.open(context.id) },
            StatusMenuItem("Add Link from Clipboard") { [weak self] in self?.addLinkFromClipboard() },
        ]
    }

    func start() async {
        guard let service, !service.isRunning else { return }
        service.start()
        observeRevision()
    }

    func stop() {
        service?.stop()
        isObservingRevision = false
        scope?.clear()
    }

    /// Changed links show up in the open palette.
    private func observeRevision() {
        isObservingRevision = true
        withObservationTracking {
            _ = service?.revision
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.isObservingRevision else { return }
                self.scope?.itemsDidChange()
                self.observeRevision()
            }
        }
    }

    /// From the status menu, over whatever app is in front.
    private func addLinkFromClipboard() {
        guard let service else { return }
        let source = NSWorkspace.shared.frontmostApplication
            .flatMap { $0.bundleIdentifier == Bundle.main.bundleIdentifier ? nil : $0.localizedName }
        let notifier = context.notifier
        Task {
            if let item = await service.addLink(sourceAppName: source) {
                notifier.post(title: "Added to Reading List", body: item.displayTitle)
            } else {
                notifier.post(title: "No link on the clipboard", body: "Copy a web link first.")
            }
        }
    }

    // MARK: - SyncContributing

    var syncContributions: [SyncContribution] {
        service.map { [Self.syncContribution(for: $0)] } ?? []
    }

    /// Links; arriving ones refresh the open palette. Links this Mac's purge
    /// would delete are not stored.
    static func syncContribution(for service: ReadingListService) -> SyncContribution {
        SyncContribution(
            collection: .reading, title: "Reading list", toggleKey: "syncReadingList",
            makeHandler: { ReadingListSyncHandler(store: service.store, deleteReadBefore: service.purgeCutoff()) },
            didApplyRemoteChanges: { service.reloadAfterSync() })
    }
}
