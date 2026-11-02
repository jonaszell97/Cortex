import AppKit

extension NSApplication {
    /// A menu bar app has no Dock icon, so its windows easily get lost
    /// behind other apps. While one is open, Cortex shows in the Dock and in
    /// ⌘Tab like a normal app.
    func activateInDock() {
        setActivationPolicy(.regular)
        activate()
    }

    /// Shows `window` in front of every other app. Cortex is usually not the
    /// active app when this runs (the palette is a non-activating panel), and
    /// activation is cooperative, so a plain `activate()` is often ignored
    /// until the Dock icon is clicked. Ordering the window front regardless,
    /// and activating again once the policy change has settled, avoids that.
    func bringToFront(_ window: NSWindow) {
        // Without this the window stays in the Space it first opened in, and
        // reopening it from another Space switches back to that one.
        window.collectionBehavior.insert(.moveToActiveSpace)
        activateInDock()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        DispatchQueue.main.async { [weak self, weak window] in
            self?.activate()
            window?.makeKeyAndOrderFront(nil)
        }
        // A menu or the palette closing can hand activation back to the app
        // that was in front, after the calls above have run.
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(150)) { [weak self, weak window] in
            guard let self, let window, window.isVisible, !isActive else { return }
            activate()
            window.makeKeyAndOrderFront(nil)
        }
    }

    /// A menu bar app stays active with no windows after its last window
    /// closes, leaving the user with no focused window. Hiding the app hands
    /// activation back to the app that was active before, and the Dock icon
    /// goes away again. A minimized window still counts as open.
    func yieldActivationIfNoWindows(besides closing: NSWindow) {
        let othersOpen = windows.contains {
            $0 !== closing && ($0.isVisible || $0.isMiniaturized) && $0.styleMask.contains(.titled)
        }
        if !othersOpen {
            hide(nil)
            setActivationPolicy(.accessory)
        }
    }
}
