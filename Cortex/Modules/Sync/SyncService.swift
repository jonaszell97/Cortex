import AppKit
import Network
import CortexCore

/// Runs the sync in the background and shows its state (docs/SYNC.md,
/// "Scheduling"). Every trigger only *requests* a cycle; requests that arrive
/// while one runs are merged into one follow-up. Nothing here is awaited by the
/// palette, the pasteboard monitor or the snippet expander: with the server down,
/// the app behaves as if sync didn't exist.
@MainActor
@Observable
final class SyncService {
    typealias Credentials = SyncCredentials

    /// Delays of the triggers, in seconds.
    enum Delay {
        static let launch: TimeInterval = 2
        static let wake: TimeInterval = 10
        static let networkChange: TimeInterval = 10
        static let localChange: TimeInterval = 5
        /// Another device's change usually arrives through waiting for
        /// changes; this is how soon it arrives when that doesn't work (an
        /// older server, a request that failed).
        static let periodic: TimeInterval = 120
        static let staleSuccess: TimeInterval = 120
        static let sleepBudget: TimeInterval = 5
    }

    let settings: SyncSettings
    private(set) var status: SyncStatus = .off
    private(set) var lastSuccess: Date?
    /// Whether the sync key and token are in the Keychain.
    private(set) var isConfigured = false
    /// Every device's last report, this Mac first (plans/IOS.md, M6).
    private(set) var devices: [SyncDevice] = []

    @ObservationIgnored private let database: AppDatabase
    @ObservationIgnored private let secrets: any SecretStore
    /// The active modules' contributions: what is synced, and what to do
    /// after remote records arrived. A switched-off module has none, so its
    /// records are neither sent nor applied.
    @ObservationIgnored private let contributionsOfActiveModules: @MainActor () -> [SyncContribution]
    /// false in tests: cycles run only when asked for.
    @ObservationIgnored private let usesTriggers: Bool
    /// Whether cycles carry this Mac's report (`device`); off in tests that
    /// count records.
    @ObservationIgnored private let reportsDevice: Bool
    @ObservationIgnored private let makeTransport: @Sendable (URL, String) -> any SyncTransport
    @ObservationIgnored private let log = Log.logger("sync")

    @ObservationIgnored private var cachedCredentials: Credentials?
    /// Each collection's switch and options as last applied; a collection is
    /// recorded the first time it is seen.
    @ObservationIgnored private var appliedFilters: [SyncCollection: SyncFilterValues] = [:]
    @ObservationIgnored private var backoff = SyncBackoff()
    /// Triggers that aren't forced wait at least until here after a failure.
    @ObservationIgnored private var retryNotBefore: Date?
    @ObservationIgnored private var scheduled: (task: Task<Void, Never>, due: Date)?
    @ObservationIgnored private var cycleTask: Task<SyncCycleReport, any Error>?
    @ObservationIgnored private var rerunRequested = false
    @ObservationIgnored private var lastSyncedStatus: SyncStatus?
    /// For this Mac's report.
    @ObservationIgnored private var lastFailure: SyncDevice.Failure?
    /// Set for the push before sleep, cleared on wake.
    @ObservationIgnored private var asleepSince: Date?
    @ObservationIgnored private var devicesObservation: SyncObservation?

    @ObservationIgnored private var triggersRunning = false
    /// Bumped by `stop()`, so the settings observation of an earlier
    /// `start()` ends.
    @ObservationIgnored private var observationGeneration = 0
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []
    @ObservationIgnored private var pathMonitor: NWPathMonitor?
    @ObservationIgnored private var lastPath: NWPath?
    @ObservationIgnored private var pendingObservation: SyncObservation?
    @ObservationIgnored private var folderWatchers: [URL: DirectoryWatcher] = [:]
    @ObservationIgnored private var periodicTask: Task<Void, Never>?
    /// Waits on the server for the other devices' changes between cycles.
    @ObservationIgnored private var changeWaiter: Task<Void, Never>?

    init(
        database: AppDatabase,
        settings: SyncSettings,
        secrets: any SecretStore = KeychainStore.app,
        contributions: @escaping @MainActor () -> [SyncContribution],
        usesTriggers: Bool = true,
        reportsDevice: Bool = true,
        makeTransport: @escaping @Sendable (URL, String) -> any SyncTransport = { SyncAPI(baseURL: $0, token: $1) }
    ) {
        self.database = database
        self.settings = settings
        self.secrets = secrets
        contributionsOfActiveModules = contributions
        self.usesTriggers = usesTriggers
        self.reportsDevice = reportsDevice
        self.makeTransport = makeTransport
        isConfigured = credentials() != nil
        lastSuccess = (try? database.syncState())?.lastSuccess
        devicesObservation = database.observeSyncDevices { [weak self] devices in
            MainActor.assumeIsolated { self?.devices = devices }
        }
    }

    /// Between `start()` and `stop()`: the Sync module is on.
    private(set) var isRunning = false

    /// Switched on and set up.
    var isActive: Bool { isRunning && isConfigured }

    /// What the active modules contribute, in list order (Settings → Sync).
    var contributions: [SyncContribution] { contributionsOfActiveModules() }

    // MARK: - Lifecycle

    /// The Sync module was switched on: starts the triggers if this Mac is set
    /// up. The first cycle waits until every contribution is ready.
    func start() {
        guard !isRunning else { return }
        isRunning = true
        observeSettings()
        settingsChanged()
        guard isActive else { return }
        status = lastSyncedStatus ?? .waiting
        startTriggers()
        let contributions = contributions
        Task {
            // After the clipboard's orphan sweep and purge, like recording.
            for contribution in contributions { await contribution.waitUntilReady() }
            schedule(after: Delay.launch)
        }
    }

    /// The Sync module was switched off: no more cycles until it is on again.
    func stop() {
        guard isRunning else { return }
        isRunning = false
        observationGeneration += 1
        stopTriggers()
        status = .off
    }

    private func observeSettings() {
        let generation = observationGeneration
        withObservationTracking {
            _ = currentFilters()
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.observationGeneration == generation else { return }
                self.settingsChanged()
                self.observeSettings()
            }
        }
    }

    private func currentFilters() -> [(SyncContribution, SyncFilterValues)] {
        contributions.map { ($0, settings.filterValues(of: $0)) }
    }

    /// Re-offers what a wider filter lets in (also for changes made while
    /// sync was switched off), and watches the folders of the contributions
    /// there are now.
    private func settingsChanged() {
        var changed = false
        for (contribution, filters) in currentFilters() {
            let applied = appliedFilters.updateValue(filters, forKey: contribution.collection)
            guard let applied, applied != filters else { continue }
            changed = true
            guard SyncFilterValues.needsRestart(contribution, from: applied, to: filters) else { continue }
            do {
                try database.restartSync(for: contribution.collection)
            } catch {
                log.error("Could not re-offer \(contribution.collection.rawValue, privacy: .public): \(error, privacy: .public)")
            }
        }
        if triggersRunning { updateFolderWatchers() }
        if changed, isActive { schedule(after: 2) }
    }

    // MARK: - Requests

    /// "Sync Now": by hand, from the status menu or Settings.
    func syncNow() {
        guard isActive else { return }
        backoff.reset()
        retryNotBefore = nil
        schedule(after: 0, force: true)
    }

    /// The palette opened: sync if the last success is old. Never waits.
    func paletteOpened(now: Date = .now) {
        guard isActive, cycleTask == nil else { return }
        if let lastSuccess, now.timeIntervalSince(lastSuccess) < Delay.staleSuccess { return }
        schedule(after: 0)
    }

    /// Asks for a cycle after `delay`. Of several requests the earliest wins.
    /// After a failure the ones that aren't `force`d wait for the backoff.
    func schedule(after delay: TimeInterval, force: Bool = false) {
        guard isActive else { return }
        var due = Date.now.addingTimeInterval(delay)
        if force {
            retryNotBefore = nil
        } else if let notBefore = retryNotBefore {
            due = max(due, notBefore)
        }
        if let scheduled, scheduled.due <= due { return }
        scheduled?.task.cancel()
        let wait = max(0, due.timeIntervalSinceNow)
        let task = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled, let self else { return }
            self.scheduled = nil
            await self.runCycle()
        }
        scheduled = (task, due)
    }

    // MARK: - Running a cycle

    /// The switched-on collections of the active modules, and this Mac's
    /// report.
    private func makeHandlers() -> [any SyncEntityHandler] {
        let handlers = contributions
            .filter { settings.isSyncing($0.toggleKey) }
            .map { $0.makeHandler() }
        guard reportsDevice else { return handlers }
        return handlers + [DeviceSyncHandler(
            database: database, name: DeviceStats.computerName(),
            collections: DeviceSyncHandler.collections(of: handlers), lastFailure: lastFailure,
            asleepSince: asleepSince)]
    }

    private func makeEngine(_ credentials: Credentials, handlers: [any SyncEntityHandler]) -> SyncEngine {
        SyncEngine(
            database: database, transport: makeTransport(credentials.url, credentials.token), key: credentials.key,
            handlers: handlers,
            onRemoteChanges: { [weak self] report in
                Task { @MainActor in
                    guard let self else { return }
                    for contribution in self.contributions where report.changedCollections.contains(contribution.collection) {
                        contribution.didApplyRemoteChanges()
                    }
                }
            })
    }

    /// One cycle, if none is running (then a follow-up is requested). Failures
    /// land in `status`; nothing is thrown and nothing is shown but the status.
    func runCycle(_ mode: SyncMode = .full, timeout: TimeInterval? = nil) async {
        guard isActive, let credentials = credentials() else { return }
        guard cycleTask == nil else {
            rerunRequested = true
            return
        }
        status = .syncing
        // The cycle pulls; waiting starts again from its cursor.
        changeWaiter?.cancel()
        changeWaiter = nil
        let engine = makeEngine(credentials, handlers: makeHandlers())
        let task = Task { try await engine.runCycle(mode) }
        cycleTask = task
        let watchdog = timeout.map { seconds in
            Task {
                try? await Task.sleep(for: .seconds(seconds))
                task.cancel()
            }
        }
        let result = await task.result
        watchdog?.cancel()
        cycleTask = nil

        guard isActive else {
            status = .off
            return
        }
        switch result {
        case .success(let report):
            let now = Date.now
            lastSuccess = now
            backoff.reset()
            retryNotBefore = nil
            let synced = SyncStatus.synced(now, sent: report.sent, received: report.applied)
            lastSyncedStatus = synced
            status = synced
            if rerunRequested {
                rerunRequested = false
                schedule(after: 1)
            }
            if mode == .full { waitForChanges(credentials) }
        case .failure(let error) where error is CancellationError:
            status = lastSyncedStatus ?? .waiting
            rerunRequested = false
        case .failure(let error):
            rerunRequested = false
            let failure = SyncFailure(error)
            log.notice("Sync cycle failed: \(failure.detail, privacy: .public)")
            status = .failed(failure)
            lastFailure = SyncDevice.Failure(message: failure.detail, at: .now)
            let delay = backoff.nextDelay()
            retryNotBefore = Date.now.addingTimeInterval(delay)
            scheduled?.task.cancel()
            scheduled = nil
            schedule(after: delay)
        }
    }

    /// Between cycles: a cycle as soon as the server has records this Mac
    /// hasn't pulled. Starts only after a successful full cycle, so a server
    /// that answers at once can't make it ask again and again.
    private func waitForChanges(_ credentials: Credentials) {
        guard triggersRunning else { return }
        let transport = makeTransport(credentials.url, credentials.token)
        let database = database
        changeWaiter = Task { [weak self] in
            guard await SyncChangeWaiter.wait(transport: transport, database: database), !Task.isCancelled else { return }
            self?.schedule(after: 0)
        }
    }

    /// Returns when no cycle runs and none is scheduled (for tests; a failure
    /// schedules its retry, so this would wait for that).
    func waitUntilIdle() async {
        while cycleTask != nil || scheduled != nil {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Before sleep: push only, with a short budget, best effort (docs/SYNC.md,
    /// "Scheduling"). This Mac's report says it is going to sleep.
    func pushBeforeSleep() async {
        guard isActive, cycleTask == nil else { return }
        asleepSince = .now
        await runCycle(.pushOnly, timeout: Delay.sleepBudget)
    }

    /// "Forget…" in Settings → Sync: a device that is gone.
    func forgetDevice(_ device: SyncDevice) {
        do {
            try database.forgetSyncDevice(device.id)
        } catch {
            log.error("Could not forget a device: \(error, privacy: .public)")
        }
        schedule(after: 2)
    }

    // MARK: - Triggers

    private func startTriggers() {
        guard usesTriggers, !triggersRunning else { return }
        triggersRunning = true

        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.didWake() }
        })
        observers.append(workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { await self.pushBeforeSleep() }
            }
        })

        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in self?.pathDidChange(path) }
        }
        monitor.start(queue: DispatchQueue(label: "dev.jonaszell.cortex.sync-path"))
        pathMonitor = monitor

        pendingObservation = database.observePendingSyncRecords { [weak self] count in
            guard count > 0 else { return }
            Task { @MainActor in self?.schedule(after: Delay.localChange) }
        }
        updateFolderWatchers()
        periodicTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Delay.periodic))
                guard !Task.isCancelled else { return }
                self?.schedule(after: 0)
            }
        }
    }

    private func stopTriggers() {
        triggersRunning = false
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observers = []
        pathMonitor?.cancel()
        pathMonitor = nil
        lastPath = nil
        pendingObservation?.cancel()
        pendingObservation = nil
        folderWatchers = [:]
        periodicTask?.cancel()
        periodicTask = nil
        changeWaiter?.cancel()
        changeWaiter = nil
        scheduled?.task.cancel()
        scheduled = nil
        cycleTask?.cancel()
    }

    /// Local changes without pending rows (action files, the knowledge
    /// folder): one watcher per contributed folder, following the modules as
    /// they are switched. Changes to hidden files only (`.git/`, `.conflicts/`)
    /// are not synced, so they ask for no cycle.
    private func updateFolderWatchers() {
        let folders = Set(contributions.compactMap(\.watchedFolder))
        for folder in folderWatchers.keys where !folders.contains(folder) {
            folderWatchers[folder] = nil
        }
        for folder in folders where folderWatchers[folder] == nil {
            folderWatchers[folder] = DirectoryWatcher(url: folder) { [weak self] paths in
                guard paths.contains(where: { !Self.isHidden($0, in: folder) }) else { return }
                self?.schedule(after: Delay.localChange)
            }
        }
    }

    /// Whether an absolute path is hidden below `folder` (a component of it
    /// starts with a dot). A path outside the folder is not.
    nonisolated static func isHidden(_ path: String, in folder: URL) -> Bool {
        let roots = [folder.path(percentEncoded: false), folder.resolvingSymlinksInPath().path(percentEncoded: false)]
            .map { $0.hasSuffix("/") ? $0 : $0 + "/" }
        guard let root = roots.first(where: { path.hasPrefix($0) }) else { return false }
        return path.dropFirst(root.count).split(separator: "/").contains { $0.hasPrefix(".") }
    }

    /// Arriving at work or home: the important one.
    private func didWake() {
        asleepSince = nil
        backoff.reset()
        retryNotBefore = nil
        schedule(after: Delay.wake, force: true)
    }

    /// Tailscale reconnecting shows up as a path change. The first update is
    /// the starting state, not a change.
    private func pathDidChange(_ path: NWPath) {
        defer { lastPath = path }
        guard let lastPath, lastPath != path, path.status == .satisfied else { return }
        backoff.reset()
        retryNotBefore = nil
        schedule(after: Delay.networkChange, force: true)
    }

    // MARK: - Credentials

    private func credentials() -> Credentials? {
        if let cachedCredentials { return cachedCredentials }
        let credentials = Credentials.load(serverURL: settings.serverURL, from: secrets)
        cachedCredentials = credentials
        return credentials
    }

    // MARK: - Setting up

    /// Checks that the server answers and accepts the token. Changes nothing.
    func testConnection(serverURL: String, token: String) async -> Result<String, SyncTestError> {
        do {
            let url = try SyncSetup.parseServerURL(serverURL)
            let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else { throw SyncSetupError.missingToken }
            try await SyncSetup.testConnection(makeTransport(url, token))
            return .success("Connected")
        } catch {
            return .failure(SyncTestError(message: SyncSetup.message(for: error)))
        }
    }

    /// The first Mac: creates the sync key, stores it with the token in the
    /// Keychain and uploads everything. Refuses a server that already holds
    /// data, because the new key can't open it.
    func setUp(serverURL: String, token: String) async throws {
        let url = try SyncSetup.parseServerURL(serverURL)
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw SyncSetupError.missingToken }
        let credentials = try await SyncSetup.firstDevice(
            url: url, token: token, database: database, transport: makeTransport(url, token))
        try finishSetup(credentials)
    }

    /// The second Mac: takes the server and key from a pairing code and checks
    /// the key against the server's key check before anything is stored.
    func join(pairingCode: String) async throws {
        let pairing = try SyncPairing(code: pairingCode)
        let credentials = try await SyncSetup.join(
            pairing, database: database, transport: makeTransport(pairing.serverURL, pairing.token))
        try finishSetup(credentials)
    }

    private func finishSetup(_ credentials: Credentials) throws {
        try credentials.save(to: secrets)
        cachedCredentials = credentials
        isConfigured = true
        settings.serverURL = credentials.url
        // A Mac with data uploads all of it; one that joins merges what it has.
        try database.markEverythingPending()
        guard isRunning else { return }
        startTriggers()
        status = .waiting
        syncNow()
    }

    /// Removes the Keychain items and stops. Local data stays as it is.
    func disconnect() {
        stopTriggers()
        Credentials.remove(from: secrets)
        cachedCredentials = nil
        isConfigured = false
        settings.serverURL = nil
        try? database.resetSyncProgress()
        lastSuccess = nil
        lastSyncedStatus = nil
        backoff.reset()
        retryNotBefore = nil
        status = .off
    }

    /// "Upload Everything Again".
    func uploadEverythingAgain() {
        do {
            try database.markEverythingPending()
        } catch {
            log.error("Could not mark everything pending: \(error, privacy: .public)")
        }
        syncNow()
    }

    /// Puts the pairing code on the pasteboard, marked concealed, so Cortex
    /// records it as a sensitive clip and masks it. Move it over AirDrop or
    /// Universal Clipboard, never through a chat or mail service.
    @discardableResult
    func copyPairingCode(to pasteboard: NSPasteboard = .general) -> Bool {
        guard let credentials = credentials() else { return false }
        let code = credentials.pairing.code
        let item = NSPasteboardItem()
        item.setString(code, forType: .string)
        item.setString("", forType: Paster.concealedType)
        pasteboard.clearContents()
        return pasteboard.writeObjects([item])
    }

    /// The pairing code as a QR code, for the iPhone's camera (plans/IOS.md,
    /// M1). Keeps it off the pasteboard.
    func pairingQRCode() -> NSImage? {
        guard let credentials = credentials(),
              let png = try? QRCode.png(for: credentials.pairing.code, moduleSize: 8)
        else { return nil }
        return NSImage(data: png)
    }
}

struct SyncTestError: Error, Equatable {
    var message: String
}
