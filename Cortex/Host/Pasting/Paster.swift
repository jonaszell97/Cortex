import AppKit
import Carbon.HIToolbox
import CortexCore
import Synchronization

/// Puts a clip back on the pasteboard and, when asked, pastes it into the
/// frontmost app by posting ⌘V (needs Accessibility permission).
@MainActor
enum Paster {
    enum Mode: Equatable {
        /// All stored representations; the target app picks the richest it reads.
        case rich
        /// Plain text only (files paste as their paths).
        case plainText
    }

    /// Set on every event Cortex posts, so the keyword expander's event
    /// tap can tell them from what the user types.
    nonisolated static let eventTag: Int64 = 0x7468_656D_696E_64

    /// Written next to content Cortex itself puts on the pasteboard, so the
    /// clipboard history does not record its own pastes as new copies.
    nonisolated static let ownMarkerType = NSPasteboard.PasteboardType("dev.jonaszell.cortex.own")
    /// Convention from nspasteboard.org: the bundle ID of the app that wrote.
    nonisolated static let sourceType = NSPasteboard.PasteboardType("org.nspasteboard.source")

    /// A sensitive clip is marked concealed, stays on this Mac and is
    /// cleared again after `sensitiveLifetime`.
    static func write(_ detail: ClipDetail, mode: Mode, to pasteboard: NSPasteboard = .general) {
        let sensitive = detail.item.isSensitive
        prepare(pasteboard, sensitive: sensitive)
        defer { if sensitive { expire(pasteboard) } }
        let markers = markedItem(concealed: sensitive)

        // An image pastes as plain text only once its text has been read.
        if mode == .plainText || detail.item.kind == .text, let text = detail.item.textForPlainPaste {
            markers.setString(text, forType: .string)
            pasteboard.writeObjects([markers])
            return
        }

        if detail.item.kind == .files {
            // One pasteboard item per file, as Finder does.
            pasteboard.writeObjects(detail.fileURLs.map { $0 as NSURL } + [markers])
            return
        }

        for representation in detail.representations {
            markers.setData(representation.data, forType: .init(representation.type))
            if representation.type == ClipType.png, let tiff = NSImage(data: representation.data)?.tiffRepresentation {
                // Some apps only read TIFF.
                markers.setData(tiff, forType: .tiff)
            }
        }
        pasteboard.writeObjects([markers])
    }

    /// What the history makes of Cortex's own writes.
    enum Recording: Equatable {
        /// Not recorded: a clip or snippet pasted again.
        case skip
        /// Recorded as a new clip from Cortex (a quick action's result),
        /// flagged sensitive if it was made from something sensitive.
        case record(sensitive: Bool)

        var isSensitive: Bool { self == .record(sensitive: true) }
    }

    /// Puts plain text (a rendered snippet, an action's result) on the
    /// pasteboard.
    static func write(text: String, recording: Recording = .skip, to pasteboard: NSPasteboard = .general) {
        prepare(pasteboard, sensitive: recording.isSensitive)
        let item = markedItem(recording)
        item.setString(text, forType: .string)
        pasteboard.writeObjects([item])
        if recording.isSensitive { expire(pasteboard) }
    }

    /// Puts an image (a quick action's result) on the pasteboard as PNG,
    /// plus TIFF for apps that only read that.
    static func write(image png: Data, recording: Recording = .skip, to pasteboard: NSPasteboard = .general) {
        prepare(pasteboard, sensitive: recording.isSensitive)
        let item = markedItem(recording)
        for (type, data) in imageRepresentations(png) {
            item.setData(data, forType: type)
        }
        pasteboard.writeObjects([item])
        if recording.isSensitive { expire(pasteboard) }
    }

    /// PNG, plus TIFF for apps that only read that.
    static func imageRepresentations(_ png: Data) -> [NSPasteboard.PasteboardType: Data] {
        var representations: [NSPasteboard.PasteboardType: Data] = [.png: png]
        representations[.tiff] = NSImage(data: png)?.tiffRepresentation
        return representations
    }

    /// An item naming Cortex as its writer and, unless it is new content,
    /// carrying the marker that keeps the pasteboard monitor from recording it.
    /// `concealed` tells other clipboard managers not to keep it.
    private static func markedItem(_ recording: Recording = .skip, concealed: Bool = false) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        if recording == .skip {
            item.setString("", forType: ownMarkerType)
        }
        if concealed || recording.isSensitive {
            item.setString("", forType: concealedType)
        }
        item.setString(Bundle.main.bundleIdentifier ?? "Cortex", forType: sourceType)
        return item
    }

    static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    /// Convention from nspasteboard.org: content that is only passing
    /// through, which clipboard managers don't record.
    static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    /// How long sensitive content Cortex wrote stays on the pasteboard.
    static let sensitiveLifetime: Duration = .seconds(90)

    /// Empties the pasteboard for a write. Sensitive content stays on this
    /// Mac: no Universal Clipboard.
    private static func prepare(_ pasteboard: NSPasteboard, sensitive: Bool) {
        if sensitive {
            pasteboard.prepareForNewContents(with: .currentHostOnly)
        } else {
            pasteboard.clearContents()
        }
    }

    /// Clears the pasteboard after `sensitiveLifetime`, unless something
    /// else was written meanwhile.
    static func expire(_ pasteboard: NSPasteboard, after lifetime: Duration = sensitiveLifetime) {
        let written = pasteboard.changeCount
        Task { @MainActor in
            try? await Task.sleep(for: lifetime)
            if pasteboard.changeCount == written {
                pasteboard.clearContents()
            }
        }
    }

    // MARK: - Lending

    /// Content put on the pasteboard for one paste (a keyword expansion, an
    /// emoji, a replaced selection). Its data is handed out only when an app
    /// asks for it, so `PasteService` knows when the target has read it and
    /// the previous contents can go back.
    final class Loan: NSObject, NSPasteboardItemDataProvider, Sendable {
        private let representations: [NSPasteboard.PasteboardType: Data]
        private struct State {
            var armed = false
            var wasRead = false
        }
        private let state = Mutex(State())

        init(_ representations: [NSPasteboard.PasteboardType: Data]) {
            self.representations = representations
        }

        /// From now on a read counts: called right before ⌘V is posted, so a
        /// clipboard manager reading the new content first doesn't.
        func arm() {
            state.withLock { $0.armed = true }
        }

        /// Whether the content was read since `arm()`.
        var wasRead: Bool { state.withLock(\.wasRead) }

        func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
            item.setData(representations[type] ?? Data(), forType: type)
            state.withLock { if $0.armed { $0.wasRead = true } }
        }
    }

    /// The loan on the pasteboard, kept alive for as long as it may be read.
    private static var currentLoan: Loan?

    /// Puts `representations` on the pasteboard as a loan: marked as Cortex's
    /// own and transient, kept on this Mac, and concealed when `concealed`.
    static func lend(
        _ representations: [NSPasteboard.PasteboardType: Data], concealed: Bool = false, to pasteboard: NSPasteboard = .general
    ) -> Loan {
        let loan = Loan(representations)
        currentLoan = loan
        pasteboard.prepareForNewContents(with: .currentHostOnly)
        let item = markedItem(concealed: concealed)
        item.setString("", forType: transientType)
        item.setDataProvider(loan, forTypes: Array(representations.keys))
        pasteboard.writeObjects([item])
        return loan
    }

    // MARK: - Saving and restoring

    /// A copy of everything on the pasteboard, to put back after a keyword
    /// expansion borrowed it.
    struct SavedContents {
        var items: [[(NSPasteboard.PasteboardType, Data)]]

        /// Marked by a password manager or similar, or written by one.
        var isSensitive: Bool {
            let representations = items.joined()
            let source = representations.first { $0.0 == Paster.sourceType }.flatMap { String(data: $0.1, encoding: .utf8) }
            return SensitivityRules.isSensitive(types: representations.map(\.0.rawValue), sourceBundleID: source)
        }
    }

    static func save(_ pasteboard: NSPasteboard = .general) -> SavedContents {
        SavedContents(items: (pasteboard.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        })
    }

    /// Puts saved contents back, unless someone else wrote to the pasteboard
    /// after `changeCount`. Marked as Cortex's own, so it is not recorded
    /// again. Sensitive contents stay on this Mac and expire like a
    /// sensitive clip: the password manager's own timer no longer applies.
    static func restore(_ saved: SavedContents, ifUnchangedSince changeCount: Int, to pasteboard: NSPasteboard = .general) {
        guard pasteboard.changeCount == changeCount else { return }
        let sensitive = saved.isSensitive
        prepare(pasteboard, sensitive: sensitive)
        defer { if sensitive { expire(pasteboard) } }
        let items = saved.items.map { representations in
            let item = NSPasteboardItem()
            for (type, data) in representations { item.setData(data, forType: type) }
            return item
        }
        guard !items.isEmpty else { return }
        items[0].setString("", forType: ownMarkerType)
        pasteboard.writeObjects(items)
    }

    // MARK: - Posting keys

    /// Waits until `target` is the active app again (the palette has just been
    /// closed), then posts ⌘V. Returns false, without posting, if `target`
    /// did not become active: the content would land in another app.
    static func paste(into target: NSRunningApplication?, beforePosting: () -> Void = {}) async -> Bool {
        if let target {
            for _ in 0..<50 where NSWorkspace.shared.frontmostApplication != target {
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
        // Let the target's key window settle after our panel ordered out.
        try? await Task.sleep(for: .milliseconds(30))
        if let target, NSWorkspace.shared.frontmostApplication != target { return false }
        beforePosting()
        postCommandV()
        return true
    }

    /// Posts ⌘C, to copy the frontmost app's selection.
    static func copySelection() {
        post(kVK_ANSI_C, flags: .maskCommand)
    }

    private static func postCommandV() {
        post(kVK_ANSI_V, flags: .maskCommand)
    }

    /// Moves the cursor left, to where a snippet's `{cursor}` was.
    static func moveCursorLeft(by count: Int) async {
        guard count > 0 else { return }
        // Some apps (browsers, Electron) insert the pasted text asynchronously.
        try? await Task.sleep(for: .milliseconds(50))
        for _ in 0..<min(count, 5_000) {
            post(kVK_LeftArrow)
        }
    }

    /// Deletes a typed keyword before its snippet is pasted.
    static func deleteBackward(count: Int) {
        for _ in 0..<count {
            post(kVK_Delete)
        }
    }

    private static func post(_ key: Int, flags: CGEventFlags = []) {
        // A private event source ignores modifier keys the user may still be
        // holding (⇧ from ⇧⏎), which would otherwise turn ⌘V into ⇧⌘V.
        let source = CGEventSource(stateID: .privateState)
        for keyDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(key), keyDown: keyDown)
            event?.flags = flags
            event?.setIntegerValueField(.eventSourceUserData, value: eventTag)
            event?.post(tap: .cghidEventTap)
        }
    }
}
