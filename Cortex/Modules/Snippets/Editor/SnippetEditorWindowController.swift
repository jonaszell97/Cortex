import AppKit
import SwiftUI

/// The snippet editor window, opened from the status menu, the palette (⌘E,
/// ⌘N) and Settings.
@MainActor
final class SnippetEditorWindowController: NSObject, NSWindowDelegate {
    private let model: SnippetEditorModel
    private var window: NSWindow?

    init(snippets: SnippetsService) {
        model = SnippetEditorModel(service: snippets)
    }

    func show(_ request: SnippetEditRequest? = nil) {
        let window = window ?? makeWindow()
        self.window = window
        NSApp.bringToFront(window)
        if let request {
            Task { await model.open(request) }
        }
    }

    /// Closes the window as its close button does, so unsaved changes are
    /// asked about first (Snippets was switched off).
    func close() {
        guard let window, window.isVisible else { return }
        window.performClose(nil)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentViewController: NSHostingController(rootView: SnippetEditorView(model: model)))
        window.title = "Snippets"
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView]
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("SnippetEditor")
        window.delegate = self
        if window.frame.width < 800 { window.setContentSize(NSSize(width: 860, height: 600)) }
        window.center()
        return window
    }

    /// Unsaved changes: save, discard or keep the window open.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard model.isDirty else { return true }
        let alert = NSAlert()
        alert.messageText = "Save changes to “\(model.draft?.name.isEmpty == false ? model.draft!.name : "New Snippet")”?"
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don’t Save")
        alert.beginSheetModal(for: sender) { [weak self] response in
            guard let self else { return }
            switch response {
            case .alertFirstButtonReturn:
                Task {
                    if await self.model.save() { sender.close() }
                }
            case .alertThirdButtonReturn:
                self.model.revert()
                sender.close()
            default:
                break
            }
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        NSApp.yieldActivationIfNoWindows(besides: window)
    }
}
