import AppKit

/// The panel as a window: where it opens, closing when another app is
/// clicked (unless that was a drag onto it), and closing on lock and sleep.
extension PanelController: NSWindowDelegate {
    // MARK: - Losing focus

    /// Clicking anywhere else (another app, the desktop) takes key status
    /// away. With the mouse still down this may be the start of a drag onto
    /// the palette, so wait for the mouse to come up first: a drop makes the
    /// panel key again, anything else closes it.
    func windowDidResignKey(_ notification: Notification) {
        guard NSEvent.pressedMouseButtons & 1 != 0 else {
            close()
            return
        }
        guard mouseUpMonitor == nil else { return }
        mouseUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.removeMouseUpMonitor()
                // The drop is delivered right after the mouse comes up.
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(300))
                    if !self.panel.isKeyWindow { self.close() }
                }
            }
        }
    }

    func removeMouseUpMonitor() {
        if let mouseUpMonitor { NSEvent.removeMonitor(mouseUpMonitor) }
        mouseUpMonitor = nil
    }

    // MARK: - Placement

    func screenWithMouse() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
    }

    /// Centred, or where the user last dragged it, on the screen with the mouse.
    func origin(on screen: NSScreen?) -> NSPoint {
        guard let visible = screen?.visibleFrame else { return .zero }
        return PanelPlacement.origin(size: panel.frame.size, relativeCenter: paletteSettings.position, in: visible)
    }

    func windowDidMove(_ notification: Notification) {
        guard !isPlacing, isVisible, let visible = panel.screen?.visibleFrame else { return }
        paletteSettings.position = PanelPlacement.relativeCenter(of: panel.frame, in: visible)
    }

    // MARK: - Screen lock and sleep

    /// Close the panel (which also re-masks sensitive items and drops loaded
    /// content) when the screen locks or the Mac sleeps.
    func observeLockAndSleep() {
        let close: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
        DistributedNotificationCenter.default().addObserver(
            forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main, using: close)
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main, using: close)
        workspace.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main, using: close)
        workspace.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main, using: close)
    }
}
