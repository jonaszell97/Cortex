import Network
import SwiftUI
import CortexCore

/// Runs sync on the phone (plans/IOS.md, M1): the same engine and handlers as
/// the Macs, for the knowledge folder, the reading list and the devices' reports
/// (M6). iOS has no
/// long-running timers, so cycles run at the moments that matter on a phone:
/// launch, coming to the foreground with an old last sync, pull to refresh, a
/// network that comes back, local changes, and a push before going to the
/// background. While the app is in front it also waits on the server for the
/// Macs' changes, like the Macs do. Like on the Mac, nothing waits for the
/// network: the data is local, and a failed cycle only shows in the status.
@MainActor
@Observable
final class MobileSyncService {
    /// Delays of the triggers, in seconds.
    enum Delay {
        static let launch: TimeInterval = 1
        static let networkChange: TimeInterval = 3
        static let localChange: TimeInterval = 5
        static let staleSuccess: TimeInterval = 120
        /// While the app is in front: what the Macs pushed shows up within
        /// this, without pulling to refresh, when waiting for changes
        /// doesn't work (an older server, a request that failed).
        static let periodic: TimeInterval = 120
        static let backgroundBudget: TimeInterval = 20
        /// A background refresh's cycle: iOS gives such a task about 30 s.
        static let refreshBudget: TimeInterval = 25
        /// Of the background time, what a cycle already running may take.
        static let cycleInFlightBudget: TimeInterval = 8
    }

    private enum Key {
        static let serverURL = "syncServerURL"
        static let deviceName = "devices.name"
    }

    /// The name before one is set: iOS gives apps no device name.
    static let defaultDeviceName = "iPhone"

    private(set) var status: SyncStatus = .off
    private(set) var lastSuccess: Date?
    /// Whether the sync key and token are in the Keychain.
    private(set) var isConfigured = false
    private(set) var serverURL: URL?
    /// Local changes not on the server yet; counted while the app is in front.
    private(set) var pendingCount = 0
    /// Knowledge files written here since the last successful cycle began:
    /// they become pending only when a cycle scans the folder, so until then
    /// they are counted here.
    private(set) var unscannedWrites = 0
    /// Every device's last report, this iPhone first once it has reported.
    private(set) var devices: [SyncDevice] = []
    /// This iPhone's name in the other devices' lists (Settings).
    var deviceName: String {
        didSet {
            let trimmed = deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
            defaults.set(trimmed.isEmpty ? nil : trimmed, forKey: Key.deviceName)
            schedule(after: Delay.localChange)
        }
    }

    @ObservationIgnored private let database: AppDatabase
    @ObservationIgnored private let secrets: any SecretStore
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let knowledge: KnowledgeStore
    @ObservationIgnored private let readingList: ReadingListModel
    @ObservationIgnored private let knowledgeFolderIdentity: String
    @ObservationIgnored private let makeTransport: @Sendable (URL, String) -> any SyncTransport
    @ObservationIgnored private let log = Log.logger("sync")

    @ObservationIgnored private var credentials: SyncCredentials?
    @ObservationIgnored private var backoff = SyncBackoff()
    @ObservationIgnored private var retryNotBefore: Date?
    @ObservationIgnored private var scheduled: (task: Task<Void, Never>, due: Date)?
    @ObservationIgnored private var cycleTask: Task<SyncCycleReport, any Error>?
    @ObservationIgnored private var rerunRequested = false
    @ObservationIgnored private var lastSyncedStatus: SyncStatus?
    /// For this iPhone's report.
    @ObservationIgnored private var lastFailure: SyncDevice.Failure?
    @ObservationIgnored private var devicesObservation: SyncObservation?

    @ObservationIgnored private var triggersRunning = false
    @ObservationIgnored private var pathMonitor: NWPathMonitor?
    @ObservationIgnored private var lastPath: NWPath?
    @ObservationIgnored private var pendingObservation: SyncObservation?
    @ObservationIgnored private var periodicTask: Task<Void, Never>?
    /// Waits on the server for the Macs' changes while the app is in front.
    @ObservationIgnored private var changeWaiter: Task<Void, Never>?

    init(
        database: AppDatabase,
        secrets: any SecretStore,
        defaults: UserDefaults,
        knowledge: KnowledgeStore,
        readingList: ReadingListModel,
        knowledgeFolderIdentity: String,
        makeTransport: @escaping @Sendable (URL, String) -> any SyncTransport = { SyncAPI(baseURL: $0, token: $1) }
    ) {
        self.database = database
        self.secrets = secrets
        self.defaults = defaults
        self.knowledge = knowledge
        self.readingList = readingList
        self.knowledgeFolderIdentity = knowledgeFolderIdentity
        self.makeTransport = makeTransport
        deviceName = defaults.string(forKey: Key.deviceName) ?? Self.defaultDeviceName
        serverURL = defaults.string(forKey: Key.serverURL).flatMap(URL.init(string:))
        credentials = SyncCredentials.load(serverURL: serverURL, from: secrets)
        isConfigured = credentials != nil
        lastSuccess = (try? database.syncState())?.lastSuccess
        devicesObservation = database.observeSyncDevices { [weak self] devices in
            MainActor.assumeIsolated { self?.devices = devices }
        }
    }

    // MARK: - Lifecycle

    /// At launch, once the knowledge folder is indexed.
    func start() {
        guard isConfigured else { return }
        status = .waiting
        startTriggers()
        schedule(after: Delay.launch)
    }

    /// The app came to the foreground: sync if the last success is old.
    func becameActive() {
        guard isConfigured else { return }
        startTriggers()
        if let lastSuccess, Date.now.timeIntervalSince(lastSuccess) < Delay.staleSuccess { return }
        schedule(after: 0)
    }

    /// The app went to the background: stop the triggers until it is back,
    /// let a cycle in flight finish (or cut it short), then push what changed
    /// here. The caller holds a background task and suspends the database
    /// afterwards.
    func enteredBackground() async {
        guard isConfigured else { return }
        stopTriggers()
        rerunRequested = false
        await finishCycleInFlight()
        // This iPhone's report says when it was last used.
        await runCycle(.pushOnly, timeout: Delay.backgroundBudget, reportsDevice: true)
    }

    /// A background refresh (`BGAppRefreshTask`, plans/IOS.md M5): one full
    /// cycle within the time iOS gives, so the widgets and Spotlight show
    /// what the Macs pushed. The triggers stay off unless the app is in
    /// front (iOS may have launched it just for this).
    func refreshInBackground(isActive: () -> Bool) async {
        guard isConfigured else { return }
        scheduled?.task.cancel()
        scheduled = nil
        await finishCycleInFlight()
        await runCycle(.full, timeout: Delay.refreshBudget, reportsDevice: true)
        if !isActive() {
            stopTriggers()
            rerunRequested = false
        }
    }

    /// Lets a cycle that is running finish, or cuts it short.
    private func finishCycleInFlight() async {
        while let cycleTask {
            let watchdog = Task {
                try? await Task.sleep(for: .seconds(Delay.cycleInFlightBudget))
                cycleTask.cancel()
            }
            _ = await cycleTask.result
            watchdog.cancel()
            // `runCycle` clears `cycleTask` when it resumes.
            await Task.yield()
        }
    }

    // MARK: - Requests

    /// Pull to refresh and "Sync Now": runs a cycle now and returns when it is
    /// done (after the one in flight, if any).
    func syncNow() async {
        guard isConfigured else { return }
        backoff.reset()
        retryNotBefore = nil
        scheduled?.task.cancel()
        scheduled = nil
        if let cycleTask { _ = await cycleTask.result }
        await runCycle()
    }

    /// Asks for a cycle after `delay`. Of several requests the earliest wins.
    /// After a failure the ones that aren't `force`d wait for the backoff.
    func schedule(after delay: TimeInterval, force: Bool = false) {
        guard isConfigured else { return }
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

    /// The app wrote a knowledge file, or found files the share extension,
    /// a widget or an intent wrote: a cycle in 5 s scans and pushes them.
    func knowledgeWritten(count: Int = 1) {
        guard isConfigured, count > 0 else { return }
        unscannedWrites += count
        schedule(after: Delay.localChange)
    }

    // MARK: - Running a cycle

    /// - Parameter reportsDevice: Send this iPhone's report even if it isn't due.
    private func makeEngine(_ credentials: SyncCredentials, reportsDevice: Bool) -> SyncEngine {
        let knowledge = knowledge
        let readingList = readingList
        let handlers: [any SyncEntityHandler] = [
            KnowledgeFileSync(
                root: knowledge.folder.root, hashes: knowledge.syncHashes, folderIdentity: knowledgeFolderIdentity),
            ReadingListSyncHandler(store: readingList.store, deleteReadBefore: readingList.purgeCutoff()),
        ]
        let device = DeviceSyncHandler(
            database: database, name: defaults.string(forKey: Key.deviceName) ?? Self.defaultDeviceName,
            collections: DeviceSyncHandler.collections(of: handlers), lastFailure: lastFailure, reportsNow: reportsDevice)
        return SyncEngine(
            database: database, transport: makeTransport(credentials.url, credentials.token), key: credentials.key,
            handlers: handlers + [device],
            onRemoteChanges: { report in
                // The devices' reports show through their own observation.
                Task { @MainActor in
                    if report.changedCollections.contains(.knowledge) { knowledge.refresh() }
                    if report.changedCollections.contains(.reading) { await readingList.reload() }
                }
            })
    }

    /// "Forget" on the Devices tab: a device that is gone.
    func forgetDevice(_ device: SyncDevice) {
        do {
            try database.forgetSyncDevice(device.id)
        } catch {
            log.error("Could not forget a device: \(String(describing: error), privacy: .public)")
        }
        schedule(after: 1)
    }

    /// One cycle, if none is running (then a follow-up is requested). Failures
    /// land in `status`; nothing is thrown.
    func runCycle(_ mode: SyncMode = .full, timeout: TimeInterval? = nil, reportsDevice: Bool = false) async {
        guard let credentials else { return }
        guard cycleTask == nil else {
            rerunRequested = true
            return
        }
        status = .syncing
        // The cycle pulls; waiting starts again from its cursor.
        changeWaiter?.cancel()
        changeWaiter = nil
        let writesBefore = unscannedWrites
        let engine = makeEngine(credentials, reportsDevice: reportsDevice)
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

        guard isConfigured else {
            status = .off
            return
        }
        switch result {
        case .success(let report):
            let now = Date.now
            lastSuccess = now
            unscannedWrites -= writesBefore
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
            if triggersRunning { schedule(after: delay) }
        }
    }

    /// Between cycles while the app is in front: a cycle as soon as the
    /// server has records this iPhone hasn't pulled. Starts only after a
    /// successful full cycle, so a server that answers at once can't make it
    /// ask again and again.
    private func waitForChanges(_ credentials: SyncCredentials) {
        guard triggersRunning else { return }
        let transport = makeTransport(credentials.url, credentials.token)
        let database = database
        changeWaiter = Task { [weak self] in
            guard await SyncChangeWaiter.wait(transport: transport, database: database), !Task.isCancelled else { return }
            self?.schedule(after: 0)
        }
    }

    // MARK: - Triggers

    private func startTriggers() {
        guard isConfigured, !triggersRunning else { return }
        triggersRunning = true

        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in self?.pathDidChange(path) }
        }
        monitor.start(queue: DispatchQueue(label: "dev.jonaszell.cortex.sync-path"))
        pathMonitor = monitor

        pendingObservation = database.observePendingSyncRecords { [weak self] count in
            Task { @MainActor in
                self?.pendingCount = count
                if count > 0 { self?.schedule(after: Delay.localChange) }
            }
        }
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
        pathMonitor?.cancel()
        pathMonitor = nil
        lastPath = nil
        pendingObservation?.cancel()
        pendingObservation = nil
        pendingCount = 0
        periodicTask?.cancel()
        periodicTask = nil
        changeWaiter?.cancel()
        changeWaiter = nil
        scheduled?.task.cancel()
        scheduled = nil
    }

    /// Tailscale connecting shows up as a path change. The first update is
    /// the starting state, not a change.
    private func pathDidChange(_ path: NWPath) {
        defer { lastPath = path }
        guard let lastPath, lastPath != path, path.status == .satisfied else { return }
        backoff.reset()
        retryNotBefore = nil
        schedule(after: Delay.networkChange, force: true)
    }

    // MARK: - Setting up

    /// Joins with a Mac's pairing code: checks the key against the server
    /// before anything is stored, then runs the first cycle.
    func join(pairingCode: String) async throws {
        let pairing = try SyncPairing(code: pairingCode)
        let credentials = try await SyncSetup.join(
            pairing, database: database, transport: makeTransport(pairing.serverURL, pairing.token))
        try credentials.save(to: secrets)
        defaults.set(credentials.url.absoluteString, forKey: Key.serverURL)
        serverURL = credentials.url
        self.credentials = credentials
        // What this phone already has (nothing, the first time) merges.
        try database.markEverythingPending()
        isConfigured = true
        status = .waiting
        startTriggers()
        await syncNow()
    }

    /// Removes the Keychain items and stops. The data on the phone stays.
    func disconnect() {
        stopTriggers()
        cycleTask?.cancel()
        SyncCredentials.remove(from: secrets)
        defaults.removeObject(forKey: Key.serverURL)
        credentials = nil
        serverURL = nil
        isConfigured = false
        try? database.resetSyncProgress()
        lastSuccess = nil
        lastSyncedStatus = nil
        unscannedWrites = 0
        backoff.reset()
        retryNotBefore = nil
        status = .off
    }

    /// The status for this phone: the Mac's words, but "this iPhone", and
    /// what is still waiting to be sent.
    var statusLine: String {
        if case .failed(.updateRequired) = status { return "Update Cortex on this iPhone" }
        return [status.settingsLine(lastSuccess: lastSuccess), pendingLine].compactMap(\.self).joined(separator: " · ")
    }

    /// Under the lists: "Synced 3 min ago", with the changes not sent yet.
    var footerLine: String? {
        let line = status.menuLine(lastSuccess: lastSuccess)
        guard let pendingLine else { return line }
        return line.map { "\($0) · \(pendingLine)" } ?? pendingLine
    }

    /// nil when nothing waits, and during a cycle, which is sending it.
    private var pendingLine: String? {
        let count = pendingCount + unscannedWrites
        guard isConfigured, count > 0, status != .syncing else { return nil }
        return count == 1 ? "1 change not sent yet" : "\(count) changes not sent yet"
    }
}

/// Extra time to finish a push after the app went to the background. Ends
/// once, when the work is done or when iOS says the time is up (after
/// `onExpiration`).
@MainActor
final class BackgroundTask {
    private var identifier = UIBackgroundTaskIdentifier.invalid

    init(name: String, onExpiration: @escaping @MainActor () -> Void = {}) {
        identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            MainActor.assumeIsolated {
                onExpiration()
                self?.end()
            }
        }
    }

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}
