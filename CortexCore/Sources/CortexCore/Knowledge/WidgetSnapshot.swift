import Foundation

/// What the iPhone's widgets show (plans/IOS.md, M5): the first open to-dos
/// and the newest unread links. The app writes it whenever its lists
/// change, as `Widgets.json` in the data directory; the widgets only read
/// it, so they never index the folder or open the database.
public struct WidgetSnapshot: Codable, Sendable, Equatable {
    public struct Todo: Codable, Sendable, Equatable, Identifiable {
        public var path: String
        public var title: String
        public var project: String
        public var projectName: String
        public var projectColor: ProjectColor
        /// A day, `2026-10-30`.
        public var due: String?
        /// Checklist items done and in all; 0 of 0 without a checklist.
        public var checklistDone: Int
        public var checklistCount: Int

        public var id: String { path }

        public init(
            path: String, title: String, project: String, projectName: String, projectColor: ProjectColor, due: String?,
            checklistDone: Int, checklistCount: Int
        ) {
            self.path = path
            self.title = title
            self.project = project
            self.projectName = projectName
            self.projectColor = projectColor
            self.due = due
            self.checklistDone = checklistDone
            self.checklistCount = checklistCount
        }

        public func isOverdue(now: Date = .now) -> Bool {
            due.map { TodoList.isOverdue($0, now: now) } ?? false
        }
    }

    public struct Link: Codable, Sendable, Equatable, Identifiable {
        public var url: String
        public var title: String
        public var site: String

        public var id: String { url }

        public init(url: String, title: String, site: String) {
            self.url = url
            self.title = title
            self.site = site
        }
    }

    /// The most any widget shows.
    public static let todoLimit = 8
    public static let linkLimit = 4
    public static let fileName = "Widgets.json"

    public var todos: [Todo]
    public var openTodoCount: Int
    public var links: [Link]
    public var unreadCount: Int

    public init(todos: [Todo] = [], openTodoCount: Int = 0, links: [Link] = [], unreadCount: Int = 0) {
        self.todos = todos
        self.openTodoCount = openTodoCount
        self.links = links
        self.unreadCount = unreadCount
    }

    /// `openTodos` in the order the To-Dos tab shows them (`TodoList.ordered`),
    /// `readingList` newest first.
    public init(openTodos: [KnowledgeItem], projects: [KnowledgeProject], readingList: [ReadingItem]) {
        let projectsByID = Dictionary(projects.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        todos = openTodos.prefix(Self.todoLimit).map { item in
            let project = projectsByID[item.project] ?? KnowledgeProject(id: item.project)
            let checklist = TodoChecklist(body: item.body)
            return Todo(
                path: item.path, title: item.title, project: item.project, projectName: project.name,
                projectColor: project.tint, due: item.due, checklistDone: checklist.doneCount,
                checklistCount: checklist.items.count)
        }
        openTodoCount = openTodos.count
        let unread = readingList.filter { !$0.isRead }
        links = unread.prefix(Self.linkLimit).map { Link(url: $0.url, title: $0.displayTitle, site: $0.site) }
        unreadCount = unread.count
    }

    /// The snapshot after a widget ticked off the to-do at `path`, before
    /// the app has seen the change.
    public func completing(_ path: String) -> WidgetSnapshot {
        guard todos.contains(where: { $0.path == path }) else { return self }
        var snapshot = self
        snapshot.todos.removeAll { $0.path == path }
        snapshot.openTodoCount = max(0, openTodoCount - 1)
        return snapshot
    }

    // MARK: - The file

    public static func url(inDataDirectory directory: URL) -> URL {
        directory.appending(path: fileName)
    }

    /// An empty snapshot when there is no file yet or it can't be read.
    public static func read(from url: URL) -> WidgetSnapshot {
        guard let data = try? Data(contentsOf: url) else { return WidgetSnapshot() }
        return (try? JSONDecoder().decode(WidgetSnapshot.self, from: data)) ?? WidgetSnapshot()
    }

    public func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
