import AppKit
import CortexCore

/// Reads the text selected in the frontmost app by copying it (⌘C) and
/// putting the clipboard back right after, so neither the clipboard nor the
/// history shows that anything happened.
@MainActor
struct SelectionReader {
    /// Copies the selection in the frontmost app. Production posts ⌘C.
    private let copy: @MainActor () -> Void
    /// Keeps the clipboard history from recording the borrowed pasteboard.
    private let activity: PasteboardActivity
    private let pasteboard: NSPasteboard
    /// How long to wait for the app to copy before concluding that nothing
    /// is selected (browsers and Electron apps copy asynchronously).
    private let timeout: Duration

    init(
        activity: PasteboardActivity,
        pasteboard: NSPasteboard = .general,
        copy: @escaping @MainActor () -> Void = Paster.copySelection,
        timeout: Duration = .milliseconds(600)
    ) {
        self.pasteboard = pasteboard
        self.copy = copy
        self.timeout = timeout
        self.activity = activity
    }

    /// The selected text as action input, or why there is none.
    func read() async -> Result<ResolvedActionInput, QuickActionError> {
        let resolved = await activity.borrow { await copySelection() }
        guard let resolved else { return .failure(QuickActionError("No text is selected.")) }
        guard resolved.input.kind == .text else { return .failure(QuickActionError("The selection is not text.")) }
        return .success(resolved)
    }

    private func copySelection() async -> ResolvedActionInput? {
        let saved = Paster.save(pasteboard)
        let before = pasteboard.changeCount
        copy()

        var waited = Duration.zero
        let step = Duration.milliseconds(10)
        while pasteboard.changeCount == before, waited < timeout {
            try? await Task.sleep(for: step)
            waited += step
        }
        guard pasteboard.changeCount != before else { return nil }

        var resolved = ResolvedActionInput.pasteboard(pasteboard)
        resolved.source = .selection
        Paster.restore(saved, ifUnchangedSince: pasteboard.changeCount, to: pasteboard)
        return resolved
    }
}
