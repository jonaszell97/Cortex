import AppKit
import CoreGraphics

/// Screen Recording permission, for modules that capture the screen (Text
/// Recognition). Without it a capture shows only the wallpaper and the
/// menu bar, not the windows.
///
/// macOS has no notification for the grant, and applies it only after the
/// app was quit and opened again.
@MainActor
enum ScreenRecordingPermission {
    static let settingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!

    static var isGranted: Bool { CGPreflightScreenCaptureAccess() }

    /// Adds Cortex to the list in System Settings (macOS only lists apps
    /// that have asked; the first time it also shows its own prompt) and
    /// opens the pane.
    static func request() {
        if !CGRequestScreenCaptureAccess() {
            NSWorkspace.shared.open(settingsURL)
        }
    }
}
