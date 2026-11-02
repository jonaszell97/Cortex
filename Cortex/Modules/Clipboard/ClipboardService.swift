import AppKit
import CortexCore

/// Owns clipboard recording, retention and the actions the palette performs
/// on clips.
@MainActor
final class ClipboardService {
    let settings: ClipboardSettings
    let store: ClipStore
    private let pasting: PasteService
    private var monitor: PasteboardMonitor!
    private var indexer: ImageTextIndexer!
    private let log = Log.logger("clipboard")
    private var purgeTask: Task<Void, Never>?
    private var startup: Task<Void, Never>?
    private var stopping: Task<Void, Never>?

    /// Between `start()` and `stop()`.
    private(set) var isRunning = false

    /// Called after the history changed (new copy, purge, import).
    var onChange: (() -> Void)?

    init(
        database: AppDatabase,
        settings: ClipboardSettings,
        pasting: PasteService = PasteService(),
        pasteboardActivity: PasteboardActivity = PasteboardActivity(),
        recognizer: any TextRecognizing = TextRecognizer()
    ) {
        self.settings = settings
        self.pasting = pasting
        store = ClipStore(database: database)
        indexer = ImageTextIndexer(
            store: store, recognizer: recognizer,
            options: { [settings] in settings.imageTextOptions },
            didIndex: { [weak self] in self?.onChange?() })
        monitor = PasteboardMonitor(
            store: store,
            options: { [settings] in settings.recordingOptions },
            isBorrowed: { [pasteboardActivity] in pasteboardActivity.isBorrowed },
            didRecord: { [weak self] in
                self?.onChange?()
                self?.wakeIndexer()
            })
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        let stopping = stopping
        startup = Task { [monitor, indexer] in
            await stopping?.value
            // Orphan cleanup must finish before recording writes new blobs.
            await background { [store] in try store.removeOrphanBlobs() }
            await purge()
            guard !Task.isCancelled else { return }
            await monitor?.start()
            // After the purge, so the backfill skips what it deletes.
            await indexer?.start()
        }
        purgeTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3600))
                await self?.purge()
            }
        }
    }

    /// Stops recording and the hourly purge. What was copied meanwhile is
    /// not recorded when it starts again.
    func stop() {
        guard isRunning else { return }
        isRunning = false
        startup?.cancel()
        startup = nil
        purgeTask?.cancel()
        purgeTask = nil
        stopping = Task { [monitor, indexer] in
            await monitor?.stop()
            await indexer?.stop()
        }
    }

    /// Whether the pasteboard is being polled (for tests).
    func isRecording() async -> Bool {
        await startup?.value
        await stopping?.value
        return await monitor.isPolling
    }

    /// Returns once the orphan sweep and the first purge are done. Sync starts
    /// after that, like recording.
    func waitUntilReady() async {
        await startup?.value
    }

    /// Reads the text of image clips that have none yet: after a copy, after
    /// sync brought clips, after the setting was turned on.
    func wakeIndexer() {
        Task { [indexer] in await indexer?.wake() }
    }

    /// Sync applied clips from the other Mac.
    func remoteChangesApplied() {
        onChange?()
        wakeIndexer()
    }

    func purge() async {
        let policy = settings.retentionPolicy
        if let count = await background({ [store] in try store.purge(policy: policy) }), count > 0 {
            onChange?()
        }
    }

    // MARK: - Palette actions

    /// Writes the clip to the pasteboard and, for `.paste`, pastes it into
    /// `target`. The caller closes the palette first.
    func perform(_ action: PasteAction, id: Int64, into target: NSRunningApplication?) async -> Bool {
        guard let detail = await background({ [store] in try await store.detail(id: id) }) ?? nil else { return false }
        guard await pasting.deliver(.clip(detail), action, into: target) else { return false }
        await background { [store] in try store.markUsed(id: id) }
        return true
    }

    /// Older text clips for `{clipboard offset=n}`, by offset: 1 is the one
    /// before the newest. Offset 0 is the pasteboard itself and not read here.
    /// Sensitive clips are left out.
    func recentTexts(upTo maxOffset: Int) async -> [Int: String] {
        var texts: [Int: String] = [:]
        let maxOffset = min(maxOffset, SnippetTemplate.maxClipboardOffset)
        guard maxOffset > 0 else { return texts }
        let recent = await background { [store] in try await store.recentPlainTexts(limit: maxOffset + 1) } ?? []
        for (offset, text) in recent.enumerated() where offset > 0 {
            texts[offset] = text
        }
        return texts
    }

    /// The newest text clips with their dates; sensitive ones are left out.
    func recentTexts(limit: Int) async -> [RecentClipText] {
        await background { [store] in try await store.recentTexts(limit: limit) } ?? []
    }

    func setPinned(_ pinned: Bool, id: Int64) async {
        await background { [store] in try store.setPinned(pinned, id: id) }
        onChange?()
    }

    func delete(id: Int64) async {
        await background { [store] in try store.delete(ids: [id]) }
        onChange?()
    }

    func clearHistory() async {
        if let count = await background({ [store] in try store.deleteAll() }) {
            log.info("Cleared \(count) items")
        }
        onChange?()
    }

    func reindexSensitive() async {
        let index = settings.indexSensitiveText
        await background { [store] in try store.reindexSensitive(indexSensitive: index) }
    }

    /// Reads Pastebot's pasteboards without importing anything.
    func readPastebot() async throws -> [PastebotImporter.Pasteboard] {
        try await Task.detached { try PastebotImporter().read() }.value
    }

    func importPastebot(_ pasteboards: [PastebotImporter.Pasteboard]) async throws -> PastebotImporter.Report {
        let index = settings.indexSensitiveText
        let store = store
        let report = try await Task.detached {
            try PastebotImporter().importAll(pasteboards, into: store, indexSensitive: index)
        }.value
        onChange?()
        wakeIndexer()
        return report
    }

    func itemCount() async -> Int {
        await background { [store] in try await store.count() } ?? 0
    }

    /// Runs blocking store work off the main actor; logs and swallows errors.
    @discardableResult
    private func background<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) async -> T? {
        do {
            return try await Task.detached(operation: work).value
        } catch {
            log.error("Clipboard store operation failed: \(error, privacy: .public)")
            return nil
        }
    }
}
