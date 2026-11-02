import AppKit
import SwiftUI
import CortexCore

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let host: ModuleHost
    private let accessibility: AccessibilityPermission
    private let launchAtLogin: LaunchAtLogin
    private let keepAwake: KeepAwake
    private let paletteSettings: PaletteSettings
    private let storage: () -> StorageInfo
    private var window: NSWindow?

    init(
        host: ModuleHost,
        accessibility: AccessibilityPermission,
        launchAtLogin: LaunchAtLogin,
        keepAwake: KeepAwake,
        paletteSettings: PaletteSettings,
        storage: @escaping () -> StorageInfo
    ) {
        self.host = host
        self.accessibility = accessibility
        self.launchAtLogin = launchAtLogin
        self.keepAwake = keepAwake
        self.paletteSettings = paletteSettings
        self.storage = storage
    }

    func show() {
        let window = window ?? makeWindow()
        self.window = window
        accessibility.refresh()
        launchAtLogin.refresh()
        NSApp.bringToFront(window)
    }

    private func makeWindow() -> NSWindow {
        let general = GeneralSettingsView(
            accessibility: accessibility,
            launchAtLogin: launchAtLogin,
            keepAwake: keepAwake,
            storage: storage(),
            paletteSettings: paletteSettings,
            host: host)
        let view = SettingsView(host: host, general: general)
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = "Cortex Settings"
        window.styleMask = [.titled, .closable, .resizable, .fullSizeContentView]
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setContentSize(NSSize(width: 860, height: 640))
        window.center()
        return window
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        NSApp.yieldActivationIfNoWindows(besides: window)
    }
}
