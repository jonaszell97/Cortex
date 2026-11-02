import AppKit
import ApplicationServices
import CortexCore

/// Accessibility permission is needed to post ⌘V into other apps (Phase 1)
/// and, if enabled, for snippet keyword expansion (Phase 2) and scroll
/// reversal.
///
/// The grant is tied to the code signature, so it survives rebuilds as long as
/// the app is signed with the same Apple Development identity.
///
/// Revoking the permission while an event tap runs freezes every click and
/// key press in the system: WindowServer keeps routing events to the tap but
/// no longer takes them back. So while a tap runs, the permission is watched
/// and `isGranted` turns false within about a second, for the taps to be torn
/// down.
@MainActor
@Observable
final class AccessibilityPermission {
    static let settingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!

    private(set) var isGranted: Bool

    @ObservationIgnored private let isTrusted: @MainActor () -> Bool

    @ObservationIgnored private var pollTask: Task<Void, Never>?
    /// Someone waits for the grant (onboarding, a tap that could not start).
    @ObservationIgnored private var isWaitingForGrant = false
    /// Running event taps that must stop as soon as the grant is gone.
    @ObservationIgnored private var watchers = 0
    @ObservationIgnored private var changeObserver: (any NSObjectProtocol)?
    @ObservationIgnored private let log = Log.logger("permissions")

    /// `isTrusted` stands in for the system's answer in tests.
    init(isTrusted: @escaping @MainActor () -> Bool = { AXIsProcessTrusted() }) {
        self.isTrusted = isTrusted
        isGranted = isTrusted()
        // Posted when the list in System Settings changes, slightly before
        // the change is stored, so check again a moment later. Undocumented,
        // so polling stays the fallback.
        changeObserver = DistributedNotificationCenter.default().addObserver(
            forName: .init("com.apple.accessibility.api"), object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
                try? await Task.sleep(for: .milliseconds(250))
                self?.refresh()
            }
        }
    }

    isolated deinit {
        if let changeObserver { DistributedNotificationCenter.default().removeObserver(changeObserver) }
        pollTask?.cancel()
    }

    func refresh() {
        let granted = isTrusted()
        if granted != isGranted {
            log.info("Accessibility permission \(granted ? "granted" : "revoked", privacy: .public)")
            isGranted = granted
        }
    }

    /// Adds Cortex to the list in System Settings (macOS only lists apps
    /// that have asked) and opens the pane.
    func openSystemSettings() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        NSWorkspace.shared.open(Self.settingsURL)
        startPolling()
    }

    /// There is no reliable notification for the grant, so poll while someone
    /// is waiting for it (the onboarding window is open).
    func startPolling() {
        isWaitingForGrant = true
        updatePolling()
    }

    func stopPolling() {
        isWaitingForGrant = false
        updatePolling()
    }

    /// An event tap started: poll until `stopWatching()`, so a revoked
    /// permission is noticed even without the notification.
    func startWatching() {
        watchers += 1
        updatePolling()
    }

    func stopWatching() {
        watchers = max(watchers - 1, 0)
        updatePolling()
    }

    private func updatePolling() {
        let wanted = isWaitingForGrant || watchers > 0
        if !wanted {
            pollTask?.cancel()
            pollTask = nil
        } else if pollTask == nil {
            pollTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    guard let self, !Task.isCancelled else { return }
                    self.refresh()
                    if self.isGranted { self.isWaitingForGrant = false }
                    if !self.isWaitingForGrant && self.watchers == 0 { break }
                }
                self?.pollTask = nil
            }
        }
    }
}
