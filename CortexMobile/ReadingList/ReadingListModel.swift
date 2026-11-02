import SafariServices
import SwiftUI
import CortexCore

/// The phone's reading list preferences, in the App Group defaults as
/// "reading-list.<name>".
@MainActor
@Observable
final class ReadingListSettings {
    enum OpenLinks: String, CaseIterable {
        /// The default browser, through `openURL`.
        case browser
        /// `SFSafariViewController`, in Reader when the page has one.
        case inApp
    }

    @ObservationIgnored private let defaults: UserDefaults

    var openLinks: OpenLinks { didSet { defaults.set(openLinks.rawValue, forKey: Key.openLinks) } }
    /// Adding a link to Safari's Reading List marks it read here ("moved to
    /// Safari").
    var safariMarksRead: Bool { didSet { defaults.set(safariMarksRead, forKey: Key.safariMarksRead) } }
    /// Read links are deleted this many days after they were read; 0 keeps
    /// them. Set per device, like on the Macs.
    var deleteReadAfterDays: Int { didSet { defaults.set(deleteReadAfterDays, forKey: Key.deleteReadAfterDays) } }

    private enum Key {
        static let openLinks = "reading-list.openLinks"
        static let safariMarksRead = "reading-list.safariMarksRead"
        static let deleteReadAfterDays = "reading-list.deleteReadAfterDays"
    }

    init(defaults: UserDefaults) {
        self.defaults = defaults
        openLinks = defaults.string(forKey: Key.openLinks).flatMap(OpenLinks.init(rawValue:)) ?? .browser
        safariMarksRead = defaults.object(forKey: Key.safariMarksRead) as? Bool ?? true
        deleteReadAfterDays = defaults.integer(forKey: Key.deleteReadAfterDays)
    }
}

/// The reading list on the phone: the links for the views and what is done
/// with them, over `ReadingListStore` (plans/IOS.md, M2). Like the Mac's
/// `ReadingListService`, without the pasteboard and the hourly purge.
@MainActor
@Observable
final class ReadingListModel {
    let settings: ReadingListSettings
    /// Every link, newest first.
    private(set) var items: [ReadingItem] = []

    @ObservationIgnored let store: ReadingListStore
    /// After a reload that changed the links (the widgets).
    @ObservationIgnored var onChange: () -> Void = {}
    @ObservationIgnored private let log = Log.logger("reading-list")
    /// Reloads may overlap (a sync and a tap); only the latest one lands.
    @ObservationIgnored private var reloadGeneration = 0

    init(store: ReadingListStore, settings: ReadingListSettings) {
        self.store = store
        self.settings = settings
    }

    var unreadCount: Int { items.count { !$0.isRead } }

    func reload() async {
        reloadGeneration += 1
        let generation = reloadGeneration
        guard let all = await background({ [store] in try await store.all() }), generation == reloadGeneration else {
            return
        }
        guard all != items else { return }
        items = all
        onChange()
    }

    /// Adds the links the share extension and intents saved while the app
    /// was away. Their database writes request a cycle like any other.
    func apply(_ outbox: ReadingListOutbox) async {
        guard !outbox.isEmpty, let added = await background({ [store] in try outbox.apply(to: store) }) else { return }
        log.info("Added \(added) links from the outbox")
        await reload()
    }

    // MARK: - Editing

    /// Throws `ReadingListError.notALink`.
    func add(_ text: String) async throws {
        let store = store
        _ = try await Task.detached { try store.add(url: text) }.value
        await reload()
    }

    func edit(id: Int64, title: String?, note: String?) async {
        await background { [store] in try store.edit(id: id, title: title, note: note) }
        await reload()
    }

    func setRead(_ read: Bool, id: Int64) async {
        await background { [store] in try store.setRead(read, id: id) }
        await reload()
    }

    /// Leaves a tombstone, so the Macs delete it too.
    func delete(id: Int64) async {
        await background { [store] in try store.delete(id: id) }
        await reload()
    }

    // MARK: - Safari's Reading List

    static func canAddToSafari(_ item: ReadingItem) -> Bool {
        URL(string: item.url).map(SSReadingList.supportsURL) ?? false
    }

    /// Adds the link to Safari's Reading List (which keeps it for offline
    /// reading), and marks it read here if the setting says so.
    func addToSafari(_ item: ReadingItem) async throws {
        guard let url = URL(string: item.url), let list = SSReadingList.default() else { return }
        try list.addItem(with: url, title: item.title, previewText: item.note)
        if settings.safariMarksRead, let id = item.id { await setRead(true, id: id) }
    }

    // MARK: - Purging

    /// Links read before this are deleted; nil while the setting keeps them.
    func purgeCutoff(now: Date = .now) -> Date? {
        ReadingListStore.purgeCutoff(afterDays: settings.deleteReadAfterDays, now: now)
    }

    /// Deletes read links older than the setting allows. Local only, no
    /// tombstones: the Macs keep theirs.
    func purge() async {
        guard let cutoff = purgeCutoff() else { return }
        if let count = await background({ [store] in try store.purgeRead(before: cutoff) }), count > 0 {
            log.info("Deleted \(count) read links")
            await reload()
        }
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
