import WidgetKit
import CortexCore

/// Writes what the widgets show (`Widgets.json`, `WidgetSnapshot`) after
/// the to-dos or the reading list changed, and reloads their timelines
/// only when it differs from the file, which a widget may have changed
/// meanwhile (ticking off a to-do).
@MainActor
final class WidgetUpdater {
    private let url: URL
    private let knowledge: KnowledgeStore
    private let readingList: ReadingListModel
    private var updateTask: Task<Void, Never>?
    private var needsUpdate = false
    private let log = Log.logger("widgets")

    init(url: URL, knowledge: KnowledgeStore, readingList: ReadingListModel) {
        self.url = url
        self.knowledge = knowledge
        self.readingList = readingList
    }

    func requestUpdate() {
        guard updateTask == nil else {
            needsUpdate = true
            return
        }
        updateTask = Task { [weak self] in
            guard let self else { return }
            repeat {
                needsUpdate = false
                await update()
            } while needsUpdate
            updateTask = nil
        }
    }

    private func update() async {
        let snapshot = WidgetSnapshot(
            openTodos: await knowledge.todos(done: false), projects: knowledge.projects, readingList: readingList.items)
        guard snapshot != WidgetSnapshot.read(from: url) else { return }
        do {
            try snapshot.write(to: url)
            WidgetCenter.shared.reloadAllTimelines()
        } catch {
            log.error("Cannot write the widgets' snapshot: \(error, privacy: .public)")
        }
    }
}
