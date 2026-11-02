import AppKit
import CortexCore

/// What ⏎ (paste) and ⌥⏎ (copy only) do with a picked item.
enum PasteAction: Equatable {
    case paste(Paster.Mode)
    case copyOnly
}

/// Something to put on the pasteboard and, maybe, paste.
enum PasteContent {
    /// Plain text: a rendered snippet, an emoji, an action's result.
    case text(String)
    /// A PNG picture: an SF Symbol, an action's result.
    case image(Data)
    /// A clip from the history, with all its representations.
    case clip(ClipDetail)
}

/// Writes to the pasteboard and pastes into another app by posting ⌘V, for
/// every feature that delivers something: clips, snippets, emoji, symbols
/// and action results. Not final, so that tests can record what is written.
@MainActor
class PasteService {
    let accessibility: AccessibilityPermission
    private let log = Log.logger("pasting")

    init(accessibility: AccessibilityPermission = AccessibilityPermission()) {
        self.accessibility = accessibility
    }

    /// Puts `content` on the pasteboard. `mode` only applies to clips.
    func write(_ content: PasteContent, mode: Paster.Mode = .rich, recording: Paster.Recording = .skip) {
        switch content {
        case .text(let text): Paster.write(text: text, recording: recording)
        case .image(let png): Paster.write(image: png, recording: recording)
        case .clip(let detail): Paster.write(detail, mode: mode)
        }
    }

    /// How long a borrowed pasteboard waits for the target to read the
    /// pasted content before giving up on it.
    static let readTimeout: Duration = .seconds(3)
    /// After the target's first read: time for it to read other types.
    static let readGrace: Duration = .milliseconds(200)

    /// Writes `content` to the pasteboard and, for `.paste`, pastes it into
    /// `target`. The caller closes the palette first. Returns false when a
    /// paste was wanted but did not happen: Accessibility is missing, or
    /// `target` did not come back to the front. The content was only copied.
    ///
    /// - Parameters:
    ///   - recording: Whether the history records the content (a quick
    ///     action's result) or skips it (the default).
    ///   - charactersAfterCursor: Moves the cursor this far left after pasting.
    ///   - restoringPasteboard: Puts the previous pasteboard content back
    ///     afterwards (keyword expansion, picked emoji and selection
    ///     replacements should not replace the clipboard). Content that only
    ///     borrows the pasteboard like this is never recorded. Applies to
    ///     text and images; clips always stay on the pasteboard.
    func deliver(
        _ content: PasteContent,
        _ action: PasteAction,
        recording: Paster.Recording = .skip,
        charactersAfterCursor: Int = 0,
        restoringPasteboard: Bool = false,
        into target: NSRunningApplication?
    ) async -> Bool {
        guard case .paste(let mode) = action else {
            write(content, mode: .rich, recording: recording)
            return true
        }
        accessibility.refresh()
        guard accessibility.isGranted else {
            write(content, mode: mode, recording: recording)
            log.notice("Copied instead of pasting: no Accessibility permission")
            return false
        }
        guard restoringPasteboard, let representations = Self.lendable(content) else {
            write(content, mode: mode, recording: recording)
            guard await Paster.paste(into: target) else {
                log.notice("Copied instead of pasting: the target app is no longer in front")
                return false
            }
            await Paster.moveCursorLeft(by: charactersAfterCursor)
            return true
        }

        let saved = Paster.save()
        let loan = Paster.lend(representations, concealed: recording.isSensitive)
        let written = NSPasteboard.general.changeCount
        guard await Paster.paste(into: target, beforePosting: loan.arm) else {
            log.notice("Copied instead of pasting: the target app is no longer in front")
            return false
        }
        await Paster.moveCursorLeft(by: charactersAfterCursor)
        // Restore once the target has read the content, not after a fixed
        // delay: a slow app would otherwise paste the restored clipboard.
        let clock = ContinuousClock()
        let deadline = clock.now + Self.readTimeout
        while !loan.wasRead, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        if loan.wasRead {
            try? await Task.sleep(for: Self.readGrace)
        } else if saved.isSensitive {
            // It may still read it later: never let that be the password.
            log.notice("The target did not read the pasted content; the sensitive clipboard is not put back")
            return true
        }
        Paster.restore(saved, ifUnchangedSince: written)
        return true
    }

    /// The representations of content that can be lent: text and images.
    private static func lendable(_ content: PasteContent) -> [NSPasteboard.PasteboardType: Data]? {
        switch content {
        case .text(let text): [.string: Data(text.utf8)]
        case .image(let png): Paster.imageRepresentations(png)
        case .clip: nil
        }
    }
}
