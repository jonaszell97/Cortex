import AppKit
import CortexCore
import UserNotifications

/// User notifications for any feature (a finished background action, a
/// failed one). Clicking one that lists files shows them in Finder. Not
/// final, so that tests can record what is posted.
@MainActor
class Notifier: NSObject, UNUserNotificationCenterDelegate {
    private nonisolated static let filesKey = "files"
    private let log = Log.logger("notifications")
    private var authorized: Bool?

    /// Notifications need a real app bundle; the unit tests' host has none
    /// worth bothering.
    private var isAvailable: Bool { !AppDelegate.isHostingTests && Bundle.main.bundleIdentifier != nil }

    func start() {
        guard isAvailable else { return }
        UNUserNotificationCenter.current().delegate = self
    }

    func post(title: String, body: String, revealing files: [URL] = []) {
        guard isAvailable else { return }
        Task {
            guard await requestAuthorization() else {
                log.notice("Notifications are off; \(title, privacy: .public): \(body, privacy: .public)")
                return
            }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            if !files.isEmpty {
                content.userInfo = [Self.filesKey: files.map(\.path)]
            }
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            do {
                try await UNUserNotificationCenter.current().add(request)
            } catch {
                log.error("Posting a notification failed: \(error, privacy: .public)")
            }
        }
    }

    /// Asks once per launch; macOS shows its prompt only the first time.
    private func requestAuthorization() async -> Bool {
        if let authorized { return authorized }
        let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
        authorized = granted
        return granted
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Cortex is never "in front", but show banners even if it is.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let paths = response.notification.request.content.userInfo[Self.filesKey] as? [String] else { return }
        let urls = paths.map { URL(filePath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
        await MainActor.run {
            if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) }
        }
    }
}
