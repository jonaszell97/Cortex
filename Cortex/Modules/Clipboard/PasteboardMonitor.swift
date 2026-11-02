import AppKit
import CortexCore

/// Records every change of a pasteboard (the general one, outside tests) into
/// the clip store.
///
/// `NSPasteboard` has no change notification, so this polls `changeCount`
/// every 250 ms. Polling and reading run on this actor, not the main thread:
/// reading can block on the source app when it provides data lazily.
actor PasteboardMonitor {
    private let store: ClipStore
    private let pasteboardName: NSPasteboard.Name
    private let frontmostApp: @MainActor () -> PasteboardReader.SourceApp?
    private let options: @MainActor () -> ClipboardSettings.RecordingOptions
    /// True while Cortex borrows the pasteboard (see `PasteboardActivity`).
    private let isBorrowed: @MainActor () -> Bool
    private let didRecord: @MainActor () -> Void
    private let log = Log.logger("pasteboard")

    private var pollTask: Task<Void, Never>?
    private var lastChangeCount: Int

    init(
        store: ClipStore,
        pasteboard: NSPasteboard.Name = .general,
        frontmostApp: @escaping @MainActor () -> PasteboardReader.SourceApp? = PasteboardReader.SourceApp.frontmost,
        options: @escaping @MainActor () -> ClipboardSettings.RecordingOptions,
        isBorrowed: @escaping @MainActor () -> Bool = { false },
        didRecord: @escaping @MainActor () -> Void
    ) {
        self.store = store
        self.pasteboardName = pasteboard
        self.frontmostApp = frontmostApp
        self.options = options
        self.isBorrowed = isBorrowed
        self.didRecord = didRecord
        // Whatever is on the pasteboard at launch was copied before; skip it.
        self.lastChangeCount = NSPasteboard(name: pasteboard).changeCount
    }

    var isPolling: Bool { pollTask != nil }

    /// Starts polling. What is on the pasteboard by then was copied before
    /// (at launch, or while recording was stopped) and is skipped.
    func start() {
        guard pollTask == nil else { return }
        lastChangeCount = NSPasteboard(name: pasteboardName).changeCount
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                await self?.poll()
            }
        }
        log.info("Monitoring the pasteboard")
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// Records the pasteboard's content if it changed since the last poll.
    /// Called by the polling loop; tests call it directly.
    func poll() async {
        let pasteboard = NSPasteboard(name: pasteboardName)
        let changeCount = pasteboard.changeCount
        guard changeCount != lastChangeCount else { return }
        // While Cortex borrows the pasteboard the change stays unread, so a
        // copy another app makes meanwhile is still recorded afterwards.
        let borrowed = await isBorrowed()
        guard !borrowed else { return }
        lastChangeCount = changeCount

        let types = (pasteboard.types ?? []).map(\.rawValue)
        guard !types.isEmpty, !types.contains(Paster.ownMarkerType.rawValue) else { return }

        let options = await options()
        guard !options.isPaused else { return }
        let source = await frontmostApp()
        if let bundleID = source?.bundleID, options.ignoredBundleIDs.contains(bundleID) {
            log.debug("Ignored copy from \(bundleID, privacy: .public)")
            return
        }

        // Another copy may have happened while waiting for the main actor.
        guard pasteboard.changeCount == changeCount else { return }

        guard var snapshot = PasteboardReader.snapshot(of: pasteboard, types: types, source: source) else { return }
        guard snapshot.byteSize <= ClipboardSettings.maxItemBytes else {
            log.notice("Skipped a copy of \(snapshot.byteSize) bytes (over the size limit)")
            return
        }

        if options.detectSensitiveText, !snapshot.isSensitive, snapshot.kind == .text || snapshot.kind == .richText,
           let text = snapshot.plainText, let reason = SensitiveTextDetector.reason(for: text) {
            snapshot.isSensitive = true
            log.debug("Flagged a copy as sensitive (looks like: \(reason.rawValue, privacy: .public))")
        }

        do {
            let outcome = try store.record(snapshot, indexSensitive: options.indexSensitiveText)
            log.debug("Recorded \(String(describing: outcome), privacy: .public) (\(snapshot.kind.rawValue, privacy: .public), sensitive: \(snapshot.isSensitive))")
            await didRecord()
        } catch {
            log.error("Recording failed: \(error, privacy: .public)")
        }
    }
}
