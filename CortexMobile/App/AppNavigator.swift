import SwiftUI
import CortexCore

/// Where the app is: the tab, the Knowledge tab's stack and its search.
/// Deep links (`KnowledgeLink`, from reminders, events, widgets, intents,
/// quick actions and Spotlight) move it.
@MainActor
@Observable
final class AppNavigator {
    enum Tab: Hashable {
        case knowledge, todos, readingList, devices, settings
    }

    var tab = Tab.knowledge
    var knowledgePath = NavigationPath()
    var knowledgeQuery = ""
    var isSearchingKnowledge = false

    @ObservationIgnored private let editor: EditorPresenter
    @ObservationIgnored private let log = Log.logger("app")

    init(editor: EditorPresenter) {
        self.editor = editor
    }

    /// Opens a `cortex://` link; anything else (the Shortcuts callback,
    /// `cortex://`) just brings the app to the front.
    func open(_ url: URL) {
        guard let link = KnowledgeLink(url: url) else {
            log.info("Not a link to open: \(url.absoluteString, privacy: .public)")
            return
        }
        switch link {
        case .item(let path):
            tab = .knowledge
            knowledgeQuery = ""
            isSearchingKnowledge = false
            // The item on top of the project list; Back goes to the list.
            knowledgePath = NavigationPath([ItemRoute(path: path)])
        case .search(let text):
            tab = .knowledge
            knowledgePath = NavigationPath()
            knowledgeQuery = text
            isSearchingKnowledge = true
        case .new(let kind, let project):
            editor.new(kind, project: project)
        case .todos:
            tab = .todos
        case .readingList:
            tab = .readingList
        }
    }
}
