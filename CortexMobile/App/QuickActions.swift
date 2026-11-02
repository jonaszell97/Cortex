import UIKit

/// The Home Screen icon's quick actions (`UIApplicationShortcutItems` in
/// `Config/CortexMobile-Info.plist`). SwiftUI has no hook for them, so a
/// scene delegate hands them over; one that launched the app waits until
/// the environment sets `handler`.
@MainActor
enum QuickActions {
    enum Action: String {
        case newNote = "new-note"
        case newTodo = "new-todo"
        case addLinkFromClipboard = "add-link-from-clipboard"

        /// The item's type is `<bundle ID>.<raw value>`.
        init?(_ item: UIApplicationShortcutItem) {
            guard let name = item.type.split(separator: ".").last else { return nil }
            self.init(rawValue: String(name))
        }
    }

    static var handler: ((Action) -> Void)? {
        didSet {
            guard let handler, let action = pending else { return }
            pending = nil
            handler(action)
        }
    }

    private static var pending: Action?

    static func perform(_ item: UIApplicationShortcutItem) -> Bool {
        guard let action = Action(item) else { return false }
        if let handler {
            handler(action)
        } else {
            pending = action
        }
        return true
    }
}

/// Puts `QuickActionSceneDelegate` on the app's scene.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication, configurationForConnecting session: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        // Launched from a quick action: it comes with the scene, not later.
        if let item = options.shortcutItem { _ = QuickActions.perform(item) }
        let configuration = UISceneConfiguration(name: nil, sessionRole: session.role)
        configuration.delegateClass = QuickActionSceneDelegate.self
        return configuration
    }
}

final class QuickActionSceneDelegate: NSObject, UIWindowSceneDelegate {
    func windowScene(_ windowScene: UIWindowScene, performActionFor shortcutItem: UIApplicationShortcutItem) async -> Bool {
        QuickActions.perform(shortcutItem)
    }
}
