import AppKit
import SwiftUI

/// Explains and requests the Accessibility permission. Shown at launch while
/// the permission is missing, and from the status menu.
@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    private let accessibility: AccessibilityPermission
    private var window: NSWindow?

    init(accessibility: AccessibilityPermission) {
        self.accessibility = accessibility
    }

    func show() {
        let window = window ?? makeWindow()
        self.window = window
        accessibility.startPolling()
        NSApp.bringToFront(window)
    }

    private func makeWindow() -> NSWindow {
        let view = OnboardingView(accessibility: accessibility) { [weak self] in
            self?.window?.performClose(nil)
        }
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = "Welcome to Cortex"
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        return window
    }

    func windowWillClose(_ notification: Notification) {
        accessibility.stopPolling()
        guard let window = notification.object as? NSWindow else { return }
        NSApp.yieldActivationIfNoWindows(besides: window)
    }
}

private struct OnboardingView: View {
    let accessibility: AccessibilityPermission
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Accessibility access", systemImage: "accessibility")
                .font(.title2.bold())

            Text("""
                Cortex pastes into the app you were using by sending it ⌘V. \
                macOS only allows that for apps you approve in System Settings → \
                Privacy & Security → Accessibility.
                """)
            Text("""
                Without it, the palette still opens and copies to the clipboard, \
                but pasting into other apps won't work.
                """)
            .foregroundStyle(.secondary)
            if !accessibility.isGranted {
                Text("""
                    Already switched on in System Settings? Then the permission belongs \
                    to an older build of Cortex. Select Cortex in the list, remove it \
                    with −, and switch the new entry on.
                    """)
                .font(.callout)
                .foregroundStyle(.secondary)
            }

            HStack {
                if accessibility.isGranted {
                    Label("Access granted", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Label("Not granted yet", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                Spacer()
                if accessibility.isGranted {
                    Button("Done", action: close)
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Later", action: close)
                    Button("Open System Settings") { accessibility.openSystemSettings() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24)
        .frame(width: 460)
    }
}
