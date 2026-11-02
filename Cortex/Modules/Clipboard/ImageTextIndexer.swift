import Foundation
import CortexCore

/// Reads the text in image clips, so the palette finds screenshots by what
/// is in them (docs/modules/TEXT_RECOGNITION.md, "The indexer"). One clip at a
/// time at background priority, newest first; a clip whose text has been read is
/// not read again, so a backfill picks up where it stopped.
///
/// Woken after the startup purge, after each copy and after sync brought
/// clips. Recognised text stays on this Mac: each Mac reads its own clips.
actor ImageTextIndexer {
    /// What the indexer needs from the settings, as a value it can take off
    /// the main actor.
    struct Options: Sendable {
        var isEnabled: Bool
        var indexSensitiveText: Bool
        var detectSensitiveText: Bool
    }

    /// Clips asked for at a time; the palette reloads after each page.
    static let pageSize = 50

    private let store: ClipStore
    private let recognizer: any TextRecognizing
    private let options: @MainActor () -> Options
    /// Called after a page of clips got their text.
    private let didIndex: @MainActor () -> Void
    private let log = Log.logger("image-text")

    private var isRunning = false
    private var drainTask: Task<Void, Never>?
    /// Woken while draining: look again once the queue seems empty.
    private var wokenWhileDraining = false

    init(
        store: ClipStore,
        recognizer: any TextRecognizing = TextRecognizer(),
        options: @escaping @MainActor () -> Options,
        didIndex: @escaping @MainActor () -> Void
    ) {
        self.store = store
        self.recognizer = recognizer
        self.options = options
        self.didIndex = didIndex
    }

    func start() {
        isRunning = true
        wake()
    }

    /// Stops after the clip being read; its text is still stored.
    func stop() {
        isRunning = false
        drainTask?.cancel()
        drainTask = nil
    }

    /// Looks for image clips without text and reads them.
    func wake() {
        guard isRunning else { return }
        guard drainTask == nil else {
            wokenWhileDraining = true
            return
        }
        drainTask = Task(priority: .background) { [weak self] in
            await self?.drain()
        }
    }

    /// Returns once nothing is left to read (for tests).
    func idle() async {
        while let drainTask {
            await drainTask.value
        }
    }

    private func drain() async {
        defer {
            // After `stop()` a new drain may already be running.
            if !Task.isCancelled { drainTask = nil }
        }
        repeat {
            wokenWhileDraining = false
            while !Task.isCancelled {
                let ids: [Int64]
                do {
                    ids = try await store.unrecognizedImageIDs(limit: Self.pageSize)
                } catch {
                    log.error("Listing image clips failed: \(error, privacy: .public)")
                    return
                }
                guard !ids.isEmpty else { break }
                let indexed = await index(ids)
                if indexed > 0 { await didIndex() }
                // Stopped, turned off, or a write failed (which would hand
                // out the same clip again and again): wait for the next wake.
                guard indexed == ids.count else { return }
            }
        } while wokenWhileDraining && !Task.isCancelled
    }

    /// Reads the clips in order; returns how many got their text before
    /// one failed or indexing was stopped or turned off.
    private func index(_ ids: [Int64]) async -> Int {
        var indexed = 0
        for id in ids {
            guard !Task.isCancelled, await options().isEnabled, await index(id) else { break }
            indexed += 1
        }
        return indexed
    }

    /// Reads one clip's text and stores it; an image that cannot be read
    /// gets "", so it is not tried again. False if storing failed.
    private func index(_ id: Int64) async -> Bool {
        var text = ""
        do {
            if let image = try await store.imageData(id: id) {
                text = try await recognizer.recognize(image)
            }
        } catch is CancellationError {
            return false
        } catch {
            log.notice("Reading the text of clip \(id) failed: \(error, privacy: .public)")
        }
        let options = await options()
        var markSensitive = false
        if options.detectSensitiveText, let reason = SensitiveTextDetector.reason(for: text) {
            markSensitive = true
            log.debug("Flagged an image clip as sensitive (its text looks like: \(reason.rawValue, privacy: .public))")
        }
        do {
            try store.setRecognizedText(text, id: id, markSensitive: markSensitive, indexSensitive: options.indexSensitiveText)
            return true
        } catch {
            log.error("Storing the text of clip \(id) failed: \(error, privacy: .public)")
            return false
        }
    }
}
