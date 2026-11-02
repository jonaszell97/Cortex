import BackgroundTasks
import SwiftUI
import CortexCore

/// Opening the app's data, or why it failed.
enum AppLaunch {
    case ready(AppEnvironment)
    case failed(String)

    @MainActor
    static func open() -> AppLaunch {
        do {
            return .ready(try AppEnvironment())
        } catch {
            Log.logger("app").error("Cannot open the app's data: \(String(describing: error), privacy: .public)")
            return .failed(String(describing: error))
        }
    }
}

/// The app's data and services: the database and the knowledge folder in the
/// App Group container, the Keychain, and sync (plans/IOS.md, §2 and §4).
@MainActor
@Observable
final class AppEnvironment {
    /// The phone syncs in the background, while it may be locked; the items
    /// never leave this device (no iCloud Keychain, no backup).
    static let secrets = KeychainStore(accessibility: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
    /// Names the knowledge folder for sync instead of its absolute path,
    /// which the container may change.
    static let knowledgeFolderIdentity = "ios-app-group/knowledge"

    let database: AppDatabase
    let knowledge: KnowledgeStore
    let readingList: ReadingListModel
    let sync: MobileSyncService
    /// The note editor, one for the whole app, with its draft on disk.
    let editor: EditorPresenter
    /// The tab and the Knowledge tab's stack, moved by deep links.
    let navigator: AppNavigator
    /// Copy, share, Notes, Calendar and Reminders for an item.
    let actions: ItemActions
    /// Notes and to-dos in Spotlight.
    let spotlight: SpotlightIndexer

    /// Links the share extension and intents saved for the reading list.
    @ObservationIgnored private let outbox: ReadingListOutbox
    @ObservationIgnored private let widgets: WidgetUpdater
    @ObservationIgnored private let log = Log.logger("app")
    @ObservationIgnored private var started = false
    @ObservationIgnored private var inBackground = false
    /// Between `suspendDatabase()` and `resumeDatabase()`: writes fail.
    @ObservationIgnored private var isDatabaseSuspended = false
    /// A quick action that arrived while the app was still in the
    /// background (they come before it is active).
    @ObservationIgnored private var pendingQuickAction: QuickActions.Action?

    init() throws {
        let directory: URL
        do {
            directory = try SharedContainer.dataDirectory()
        } catch {
            // A build without the App Group entitlement (an unsigned simulator
            // build): the app's own container still works, unshared.
            log.error("No App Group container, using the app's own: \(String(describing: error), privacy: .public)")
            directory = try AppPaths.dataDirectory()
        }
        let defaults = SharedContainer.defaults

        // A plaintext header and suspension, or iOS kills the suspended app
        // for its SQLite locks in the shared container (0xdead10cc).
        database = try AppDatabase.open(
            at: directory.appending(path: "Cortex.sqlite"), secrets: Self.secrets, sharedContainer: true)
        knowledge = KnowledgeStore(folder: SharedContainer.knowledgeFolder(in: directory))
        readingList = ReadingListModel(
            store: ReadingListStore(database: database), settings: ReadingListSettings(defaults: defaults))
        sync = MobileSyncService(
            database: database, secrets: Self.secrets, defaults: defaults, knowledge: knowledge, readingList: readingList,
            knowledgeFolderIdentity: Self.knowledgeFolderIdentity)
        knowledge.onWrite = { [sync] in sync.knowledgeWritten() }
        knowledge.onOutsideWrites = { [sync] count in sync.knowledgeWritten(count: count) }
        editor = EditorPresenter(knowledge: knowledge, draftURL: directory.appending(path: "EditorDraft.json"))
        navigator = AppNavigator(editor: editor)
        actions = ItemActions(settings: ActionsSettings(defaults: defaults))
        outbox = SharedContainer.readingListOutbox(in: directory)
        spotlight = SpotlightIndexer(knowledge: knowledge, defaults: defaults, dataDirectory: directory)
        widgets = WidgetUpdater(
            url: SharedContainer.widgetSnapshotURL(in: directory), knowledge: knowledge, readingList: readingList)
        knowledge.onChange = { [spotlight, widgets] _ in
            spotlight.requestUpdate()
            widgets.requestUpdate()
        }
        readingList.onChange = { [widgets] in widgets.requestUpdate() }

        // Intents and quick actions that run in this process.
        IntentBridge.openLink = { [navigator] in navigator.open($0) }
        IntentBridge.didWrite = { [weak self] in
            Task { await self?.pickUpOutsideChanges() }
        }
        QuickActions.handler = { [weak self] action in
            guard let self else { return }
            if inBackground {
                pendingQuickAction = action
            } else {
                Task { await self.perform(action) }
            }
        }
    }

    /// Indexes the knowledge folder, loads the reading list (purging old
    /// read links first), then starts sync.
    func start() async {
        guard !started else { return }
        started = true
        await knowledge.start()
        // The editor was open when the app last went away.
        editor.restoreDraft()
        await readingList.purge()
        await readingList.apply(outbox)
        await readingList.reload()
        sync.start()
    }

    /// What the share extension, the widgets and intents wrote while the
    /// app was away: the reading list's outbox, and knowledge files, which
    /// count as writes for sync. Before `start()` there is nothing to do:
    /// it reads everything anyway.
    func pickUpOutsideChanges() async {
        guard started else { return }
        // An intent ran while the app is in the background: the links wait.
        if !isDatabaseSuspended { await readingList.apply(outbox) }
        await knowledge.refreshOutsideWrites()
    }

    func scenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .active:
            inBackground = false
            resumeDatabase()
            // Files may have changed while away: the extensions, widgets and
            // intents write them.
            Task { await pickUpOutsideChanges() }
            // The app may have stayed alive for days.
            Task { await readingList.purge() }
            sync.becameActive()
            if let action = pendingQuickAction {
                pendingQuickAction = nil
                Task { await perform(action) }
            }
        case .background:
            inBackground = true
            // iOS may end the app while it is away: the draft is on disk.
            editor.saveDraft()
            scheduleBackgroundRefresh()
            enterBackground()
        default:
            break
        }
    }

    /// Pushes what changed here within the time iOS gives, then suspends the
    /// database so no write lock is held when the app is suspended. If iOS
    /// ends the time first, the database is suspended then, and a write
    /// still running fails instead.
    private func enterBackground() {
        let background = BackgroundTask(name: "Cortex sync") { [weak self] in self?.suspendDatabase() }
        Task {
            await sync.enteredBackground()
            // Back in front before the push finished: stay resumed.
            if inBackground { suspendDatabase() }
            background.end()
        }
    }

    private func suspendDatabase() {
        isDatabaseSuspended = true
        database.suspend()
    }

    private func resumeDatabase() {
        isDatabaseSuspended = false
        database.resume()
    }

    // MARK: - Background refresh

    /// `BGTaskSchedulerPermittedIdentifiers` in the Info.plist.
    static let backgroundRefreshID = (Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers")
        as? [String])?.first ?? "refresh"
    /// The earliest the next background refresh may run; iOS picks the time.
    static let backgroundRefreshInterval: TimeInterval = 30 * 60

    private func scheduleBackgroundRefresh() {
        guard sync.isConfigured else { return }
        let request = BGAppRefreshTaskRequest(identifier: Self.backgroundRefreshID)
        request.earliestBeginDate = Date.now.addingTimeInterval(Self.backgroundRefreshInterval)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // The simulator refuses (BGTaskSchedulerErrorDomain 1).
            log.notice("Cannot schedule a background refresh: \(String(describing: error), privacy: .public)")
        }
    }

    /// iOS woke the app (or launched it) for a background refresh: pick up
    /// what the extensions wrote, run one cycle, and let the widgets and
    /// Spotlight follow. Then the next refresh is requested and the
    /// database suspended again, unless the app came to the front.
    func refreshInBackground() async {
        log.info("Background refresh")
        await start()
        resumeDatabase()
        await pickUpOutsideChanges()
        await sync.refreshInBackground { UIApplication.shared.applicationState == .active }
        scheduleBackgroundRefresh()
        if UIApplication.shared.applicationState != .active { suspendDatabase() }
    }

    // MARK: - Quick actions

    private func perform(_ action: QuickActions.Action) async {
        guard sync.isConfigured else { return }
        switch action {
        case .newNote: navigator.open(KnowledgeLink.new(.note, project: nil).url)
        case .newTodo: navigator.open(KnowledgeLink.new(.todo, project: nil).url)
        case .addLinkFromClipboard: await addLinkFromClipboard()
        }
    }

    /// Reading the pasteboard here (not through the paste button) makes
    /// iOS ask first.
    private func addLinkFromClipboard() async {
        navigator.tab = .readingList
        let pasteboard = UIPasteboard.general
        let text = pasteboard.hasURLs ? pasteboard.url?.absoluteString : pasteboard.string
        guard let text, !text.hasPrefix("file:"), pasteboard.hasURLs || ReadingItem.isPastedLink(text) else {
            actions.show("The clipboard has no web link.")
            return
        }
        do {
            try await readingList.add(text)
            actions.show("Added to the reading list")
        } catch {
            actions.show(error.localizedDescription)
        }
    }
}
