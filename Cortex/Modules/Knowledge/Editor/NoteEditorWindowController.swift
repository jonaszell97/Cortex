import AppKit
import SwiftUI

/// The note editor window, opened with ⌘E in `?` and `!`. One item at a
/// time; opening another saves the one being edited first.
@MainActor
final class NoteEditorWindowController: NSObject, NSWindowDelegate {
    let model: NoteEditorModel
    private var window: NSWindow?

    init(service: KnowledgeService) {
        model = NoteEditorModel(service: service)
    }

    func show(_ path: String) {
        let window = window ?? makeWindow()
        self.window = window
        NSApp.bringToFront(window)
        Task {
            await model.open(path)
            window.title = model.fields.title.isEmpty ? "Note" : model.fields.title
        }
    }

    /// Closes the window as its close button does, so unsaved changes are
    /// asked about first (Knowledge was switched off).
    func close() {
        guard let window, window.isVisible else { return }
        window.performClose(nil)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentViewController: NSHostingController(rootView: NoteEditorView(model: model)))
        window.title = "Note"
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("NoteEditor")
        window.delegate = self
        if window.frame.width < 560 { window.setContentSize(NSSize(width: 680, height: 600)) }
        window.center()
        return window
    }

    /// Unsaved changes: save, discard or keep the window open.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard model.isDirty, !model.isGone else { return true }
        let alert = NSAlert()
        alert.messageText = "Save changes to “\(model.fields.title.isEmpty ? "Untitled" : model.fields.title)”?"
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
