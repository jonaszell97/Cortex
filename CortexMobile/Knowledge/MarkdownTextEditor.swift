import SwiftUI
import UIKit

/// The editor's body: a plain text view in a monospaced font, without smart
/// quotes, dashes and inserts, which SwiftUI's `TextEditor` can't switch
/// off. They would turn `--force` into `—force` and the quotes in a command
/// into curly ones. It grows with its text inside the form, which scrolls
/// to keep the caret above the keyboard.
struct MarkdownTextEditor: UIViewRepresentable {
    @Binding var text: String
    /// Set to move the keyboard here (Return in the title); follows the view.
    @Binding var isFocused: Bool
    var minHeight: CGFloat = 200

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.font = UIFont.monospacedSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .body).pointSize, weight: .regular)
        view.adjustsFontForContentSizeCategory = true
        view.backgroundColor = .clear
        view.isScrollEnabled = false
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.smartQuotesType = .no
        view.smartDashesType = .no
        view.smartInsertDeleteType = .no
        view.autocapitalizationType = .sentences
        view.keyboardDismissMode = .interactive
        view.accessibilityLabel = "Markdown"
        view.delegate = context.coordinator
        view.text = text
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        // Only text from outside (a draft read again); typing is already in.
        if view.text != text { view.text = text }
        context.coordinator.isFocused = $isFocused
        if isFocused, !view.isFirstResponder {
            DispatchQueue.main.async { view.becomeFirstResponder() }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView view: UITextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite else { return nil }
        let fitting = view.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: max(minHeight, ceil(fitting.height)))
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, isFocused: $isFocused)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var text: Binding<String>
        var isFocused: Binding<Bool>

        init(text: Binding<String>, isFocused: Binding<Bool>) {
            self.text = text
            self.isFocused = isFocused
        }

        func textViewDidChange(_ view: UITextView) {
            text.wrappedValue = view.text
        }

        func textViewDidChangeSelection(_ view: UITextView) {
            // After the form resized the view for the new text.
            DispatchQueue.main.async { Self.scrollCaretIntoView(view) }
        }

        func textViewDidEndEditing(_ view: UITextView) {
            isFocused.wrappedValue = false
        }

        func textViewDidBeginEditing(_ view: UITextView) {
            if !isFocused.wrappedValue { isFocused.wrappedValue = true }
            // After the keyboard moved the form's safe area.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { Self.scrollCaretIntoView(view) }
        }

        /// The view doesn't scroll itself, so the form it is in shows the
        /// caret, with a line to spare.
        private static func scrollCaretIntoView(_ view: UITextView) {
            guard view.isFirstResponder, let position = view.selectedTextRange?.end else { return }
            var container = view.superview
            while let candidate = container, !(candidate is UIScrollView) { container = candidate.superview }
            guard let scrollView = container as? UIScrollView else { return }
            let caret = view.caretRect(for: position).insetBy(dx: 0, dy: -(view.font?.lineHeight ?? 20))
            scrollView.scrollRectToVisible(view.convert(caret, to: scrollView), animated: false)
        }
    }
}
