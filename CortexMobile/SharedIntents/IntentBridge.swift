import Foundation
import CortexCore

/// How intents reach the app when they run in its process (plans/IOS.md,
/// M5). The app sets both handlers at launch; in an extension they stay
/// nil, and the app picks up what was written the next time it runs.
@MainActor
enum IntentBridge {
    /// Opens a deep link through `AppNavigator`. Links opened before the
    /// app set it (an intent that launched the app) wait for it.
    static var openLink: ((URL) -> Void)? {
        didSet {
            guard let openLink else { return }
            let waiting = pending
            pending = []
            waiting.forEach(openLink)
        }
    }

    /// Something wrote knowledge files or the reading list's outbox.
    static var didWrite: (() -> Void)?

    private static var pending: [URL] = []

    static func open(_ link: KnowledgeLink) {
        if let openLink {
            openLink(link.url)
        } else {
            pending.append(link.url)
        }
    }

    static func wrote() {
        didWrite?()
    }
}
