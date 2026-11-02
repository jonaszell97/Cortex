import AppKit
import SwiftUI

/// The knowledge browser window, opened from the status menu and with ⌘O
/// in `?`. One window; showing it again brings it to the front, on the
/// item or project asked for. Closing it saves the edits first.
@MainActor
final class KnowledgeBrowserWindowController: NSObject, NSWindowDelegate {
    let model: KnowledgeBrowserModel
    private var window: NSWindow?

    init(service: KnowledgeService) {
        model = KnowledgeBrowserModel(service: service)
    }

    /// `path`: an item or a project's README to show; nil keeps what was shown.
    func show(_ path: String? = nil) {
        let window = window ?? makeWindow()
        self.window = window
        NSApp.bringToFront(window)
        if let path {
            Task { await model.reveal(path) }
        }
    }

    /// Closes the window as its close button does, so edits are saved
    /// first (Knowledge was switched off).
    func close() {
        guard let window, window.isVisible else { return }
        window.performClose(nil)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentViewController: NSHostingController(rootView: KnowledgeBrowserView(model: model)))
        window.title = "Knowledge"
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView]
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("KnowledgeBrowser")
        window.delegate = self
        if window.frame.width < 860 { window.setContentSize(NSSize(width: 1080, height: 680)) }
        window.center()
        return window
    }

    /// Edits are saved; when that fails, the window stays open on them and
    /// says why (or asks, when the file changed on disk).
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard model.isDirty, !model.editor.isGone else { return true }
        Task {
            if await model.save() { sender.close() }
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        NSApp.yieldActivationIfNoWindows(besides: window)
    }
}
