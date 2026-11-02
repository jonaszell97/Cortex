import AppKit
import SwiftUI
import CortexCore

/// The snippet's text in an `NSTextView`, its placeholders on a tinted
/// background. Plain text, without smart quotes or dashes, which would break
/// `{date format="…"}` and the JSON or code a snippet often holds. A text
/// view rather than `TextEditor`, so the highlight never ends up in the text
/// and `SnippetTextInserter` can insert at the cursor with undo.
struct SnippetTextView: NSViewRepresentable {
    @Binding var text: String
    let inserter: SnippetTextInserter

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.drawsBackground = false
        let textView = scrollView.documentView as! NSTextView
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        textView.textContainerInset = NSSize(width: 12, height: 10)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.string = text
        Coordinator.highlight(textView)
        inserter.textView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.text = $text
        guard let textView = scrollView.documentView as? NSTextView else { return }
        inserter.textView = textView
        // Another snippet, or reverted: start over at the top.
        if textView.string != text {
            textView.string = text
            textView.setSelectedRange(NSRange(location: 0, length: 0))
            textView.scrollToBeginningOfDocument(nil)
            context.coordinator.undoManager.removeAllActions()
            Coordinator.highlight(textView)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        /// Its own, so undo never reaches into the snippet shown before.
        let undoManager = UndoManager()

        init(text: Binding<String>) {
            self.text = text
        }

        func undoManager(for view: NSTextView) -> UndoManager? { undoManager }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
            Self.highlight(textView)
        }

        /// Tints every placeholder `SnippetTemplate` recognises.
        static func highlight(_ textView: NSTextView) {
            guard let storage = textView.textStorage else { return }
            let text = textView.string
            storage.beginEditing()
            storage.removeAttribute(.backgroundColor, range: NSRange(location: 0, length: storage.length))
            for range in SnippetTemplate.placeholderRanges(in: text) {
                storage.addAttribute(.backgroundColor, value: tint, range: NSRange(range, in: text))
            }
            storage.endEditing()
            // Typing right after a placeholder must not continue its tint.
            textView.typingAttributes[.backgroundColor] = nil
        }

        static let tint = NSColor.controlAccentColor.withAlphaComponent(0.18)
    }
}

/// Inserts text at the cursor of the shown `SnippetTextView`, as if typed
/// (it can be undone), for the Insert Placeholder menu.
@MainActor
final class SnippetTextInserter {
    weak var textView: NSTextView?

    func insert(_ text: String) {
        guard let textView else { return }
        textView.window?.makeFirstResponder(textView)
        textView.insertText(text, replacementRange: textView.selectedRange())
    }
}
