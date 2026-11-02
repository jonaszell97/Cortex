import AppKit
import CortexCore

/// Owns the reading list store and what is done with links: adding,
/// editing, opening, marking read, deleting and the daily purge of read
/// links.
@MainActor
@Observable
final class ReadingListService {
    let settings: ReadingListSettings
    @ObservationIgnored let store: ReadingListStore
    @ObservationIgnored private let log = Log.logger("reading-list")
    @ObservationIgnored private var purgeTask: Task<Void, Never>?
    @ObservationIgnored private let openURL: @MainActor (URL) -> Void

    /// Bumped after every change, so open views reload.
    private(set) var revision = 0

    init(
        database: AppDatabase, settings: ReadingListSettings,
        openURL: @escaping @MainActor (URL) -> Void = { NSWorkspace.shared.open($0) }
    ) {
        self.settings = settings
        self.openURL = openURL
        store = ReadingListStore(database: database)
    }

    /// Purges read links now and hourly.
    func start() {
        guard purgeTask == nil else { return }
        purgeTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.purge()
                try? await Task.sleep(for: .seconds(3600))
            }
        }
    }

    func stop() {
        purgeTask?.cancel()
        purgeTask = nil
    }

    var isRunning: Bool { purgeTask != nil }

    // MARK: - Reading

    func all() async -> [ReadingItem] {
        await background { [store] in try await store.all() } ?? []
    }

    // MARK: - Editing

    /// Throws `ReadingListError.notALink`.
    @discardableResult
    func add(url: String, title: String? = nil, sourceAppName: String? = nil) async throws -> ReadingItem {
        let store = store
        let item = try await Task.detached { try store.add(url: url, title: title, sourceAppName: sourceAppName) }.value
        didChange()
        return item
    }

    /// The link on `pasteboard`, saved; nil if there is none.
    @discardableResult
    func addLink(from pasteboard: NSPasteboard = .general, sourceAppName: String?) async -> ReadingItem? {
        guard let link = Self.link(on: pasteboard) else { return nil }
        return try? await add(url: link.url, title: link.title, sourceAppName: sourceAppName)
    }

    func edit(id: Int64, title: String?, note: String?) async {
        await background { [store] in try store.edit(id: id, title: title, note: note) }
        didChange()
    }

    func setRead(_ read: Bool, id: Int64) async {
        await background { [store] in try store.setRead(read, id: id) }
        didChange()
    }

    func delete(id: Int64) async {
        await background { [store] in try store.delete(id: id) }
        didChange()
    }

    /// Opens the link in the default browser and marks it read.
    func open(_ item: ReadingItem) async {
        guard let url = URL(string: item.url), let id = item.id else { return }
        openURL(url)
        await setRead(true, id: id)
    }

    /// Links read before this are deleted; nil while the setting keeps them.
    func purgeCutoff(now: Date = .now) -> Date? {
        ReadingListStore.purgeCutoff(afterDays: settings.deleteReadAfterDays, now: now)
    }

    /// Deletes read links older than the setting allows.
    func purge(now: Date = .now) async {
        guard let cutoff = purgeCutoff(now: now) else { return }
        if let count = await background({ [store] in try store.purgeRead(before: cutoff) }), count > 0 {
            log.info("Deleted \(count) read links")
            didChange()
        }
    }

    /// Sync changed links in the database.
    func reloadAfterSync() {
        didChange()
    }

    private func didChange() {
        revision += 1
    }

    // MARK: - The pasteboard

    /// Safari, Chrome and most apps that copy a link put its title next to
    /// it in one of these; plain text that is a link works too.
    private static let urlsWithTitles = NSPasteboard.PasteboardType("WebURLsWithTitlesPboardType")
    private static let urlName = NSPasteboard.PasteboardType("public.url-name")

    /// The web link on `pasteboard` and its title, if it carries one.
    static func link(on pasteboard: NSPasteboard) -> (url: String, title: String?)? {
        if let list = pasteboard.propertyList(forType: urlsWithTitles) as? [[String]], list.count == 2,
           let url = list[0].first, ReadingItem.normalizedURL(url) != nil {
            return (url, list[1].first)
        }
        if let url = pasteboard.string(forType: .URL), ReadingItem.normalizedURL(url) != nil {
            return (url, pasteboard.string(forType: urlName))
        }
        if let text = pasteboard.string(forType: .string), ReadingItem.isPastedLink(text) {
            return (text, nil)
        }
        return nil
    }

    /// Runs blocking store work off the main actor; logs and swallows errors.
    @discardableResult
    private func background<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) async -> T? {
        do {
            return try await Task.detached(operation: work).value
        } catch {
            log.error("Reading list store operation failed: \(error, privacy: .public)")
            return nil
        }
    }
}
