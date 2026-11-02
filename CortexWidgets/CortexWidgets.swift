import AppIntents
import SwiftUI
import WidgetKit
import CortexCore

/// The widgets and the control (plans/IOS.md, M5). They show the snapshot
/// the app writes (`Widgets.json`); ticking off a to-do writes its file
/// (`CompleteTodoIntent`), the rest opens the app through its links.
@main
struct CortexWidgets: WidgetBundle {
    var body: some Widget {
        TodosWidget()
        ReadingListWidget()
        NewNoteWidget()
        NewNoteControl()
    }
}

// MARK: - Timeline

struct SnapshotEntry: TimelineEntry {
    var date: Date
    var snapshot: WidgetSnapshot
}

/// One entry from the snapshot, until midnight, when overdue marks change;
/// the app reloads the timelines whenever it writes a new snapshot.
struct SnapshotProvider: TimelineProvider {
    func placeholder(in context: Context) -> SnapshotEntry {
        SnapshotEntry(date: .now, snapshot: .preview)
    }

    func getSnapshot(in context: Context, completion: @escaping (SnapshotEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : entry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SnapshotEntry>) -> Void) {
        let midnight = Calendar.current.startOfDay(for: .now.addingTimeInterval(24 * 60 * 60))
        completion(Timeline(entries: [entry()], policy: .after(midnight)))
    }

    private func entry() -> SnapshotEntry {
        let snapshot = (try? SharedContainer.dataDirectory()).map {
            WidgetSnapshot.read(from: SharedContainer.widgetSnapshotURL(in: $0))
        }
        return SnapshotEntry(date: .now, snapshot: snapshot ?? WidgetSnapshot())
    }
}

extension WidgetSnapshot {
    /// For the widget gallery.
    static let preview = WidgetSnapshot(
        todos: [
            Todo(
                path: "server-config/todos/rotate.md", title: "Rotate the S3 key", project: "server-config",
                projectName: "Server config", projectColor: .blue, due: "2026-10-20", checklistDone: 1, checklistCount: 2),
            Todo(
                path: "inbox/todos/call.md", title: "Call Anna", project: "inbox", projectName: "Inbox", projectColor: .gray,
                due: nil, checklistDone: 0, checklistCount: 0),
            Todo(
                path: "home/todos/plants.md", title: "Repot the plants", project: "home", projectName: "Home",
                projectColor: .green, due: nil, checklistDone: 0, checklistCount: 0),
        ],
        openTodoCount: 3,
        links: [
            Link(url: "https://example.com/a", title: "How SQLite's WAL works", site: "sqlite.org"),
            Link(url: "https://example.com/b", title: "Context Window", site: "claude.com"),
        ],
        unreadCount: 2)
}

// MARK: - To-dos

struct TodosWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: SharedContainer.WidgetKind.todos, provider: SnapshotProvider()) { entry in
            TodosWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
                .widgetURL(KnowledgeLink.todos.url)
        }
        .configurationDisplayName("To-Dos")
        .description("Your open to-dos, in the order of the To-Dos tab. Tick one off right here.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryRectangular, .accessoryInline])
    }
}

struct TodosWidgetView: View {
    var entry: SnapshotEntry
    @Environment(\.widgetFamily) private var family

    private var snapshot: WidgetSnapshot { entry.snapshot }

    private var rowCount: Int {
        switch family {
        case .systemLarge: 7
        case .systemMedium: 3
        default: 3
        }
    }

    var body: some View {
        switch family {
        case .accessoryInline:
            Label(countText, systemImage: "checklist")
        case .accessoryRectangular:
            VStack(alignment: .leading) {
                Label(countText, systemImage: "checklist")
                    .font(.headline)
                ForEach(snapshot.todos.prefix(2)) { Text($0.title).lineLimit(1) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .systemSmall:
            VStack(alignment: .leading, spacing: 4) {
                header
                ForEach(snapshot.todos.prefix(rowCount)) { todo in
                    Text(todo.title)
                        .font(.caption)
                        .lineLimit(2)
                        .foregroundStyle(todo.isOverdue(now: entry.date) ? .red : .primary)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        default:
            VStack(alignment: .leading, spacing: 8) {
                header
                if snapshot.todos.isEmpty {
                    Text("Nothing open.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                ForEach(snapshot.todos.prefix(rowCount)) { TodoRow(todo: $0, now: entry.date) }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var countText: String {
        switch snapshot.openTodoCount {
        case 0: "No to-dos"
        case 1: "1 to-do"
        default: "\(snapshot.openTodoCount) to-dos"
        }
    }

    private var header: some View {
        HStack {
            Text("To-Dos")
                .font(.headline)
            Spacer()
            Text("\(snapshot.openTodoCount)")
                .font(.headline)
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())
        }
    }
}

/// A circle that ticks the to-do off, and its title, project and due day,
/// which open it.
struct TodoRow: View {
    var todo: WidgetSnapshot.Todo
    var now: Date

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Button(intent: CompleteTodoIntent(path: todo.path)) {
                Image(systemName: "circle")
                    .foregroundStyle(todo.projectColor.color)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Complete \(todo.title)")
            Link(destination: KnowledgeLink.item(todo.path).url) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(todo.title)
                        .font(.subheadline)
                        .lineLimit(1)
                    Text(details)
                        .font(.caption2)
                        .foregroundStyle(todo.isOverdue(now: now) ? .red : .secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var details: String {
        var parts = [todo.projectName]
        if let due = todo.due { parts.append(Self.dueText(due)) }
        if todo.checklistCount > 0 { parts.append("\(todo.checklistDone)/\(todo.checklistCount)") }
        return parts.joined(separator: " · ")
    }

    private static func dueText(_ due: String) -> String {
        guard let date = try? Date(due, strategy: .iso8601.year().month().day()) else { return due }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }
}

// MARK: - Reading list

struct ReadingListWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: SharedContainer.WidgetKind.readingList, provider: SnapshotProvider()) { entry in
            ReadingListWidgetView(snapshot: entry.snapshot)
                .containerBackground(.fill.tertiary, for: .widget)
                .widgetURL(KnowledgeLink.readingList.url)
        }
        .configurationDisplayName("Reading List")
        .description("How many links are unread, and the newest.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryInline])
    }
}

struct ReadingListWidgetView: View {
    var snapshot: WidgetSnapshot
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .accessoryInline:
            Label("\(snapshot.unreadCount) unread", systemImage: "eyeglasses")
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                VStack(spacing: 0) {
                    Image(systemName: "eyeglasses")
                        .font(.caption)
                    Text("\(snapshot.unreadCount)")
                        .font(.title3.bold())
                }
            }
        case .systemSmall:
            VStack(alignment: .leading) {
                Image(systemName: "eyeglasses")
                    .font(.title2)
                    .foregroundStyle(.tint)
                Spacer()
                Text("\(snapshot.unreadCount)")
                    .font(.largeTitle.bold())
                    .contentTransition(.numericText())
                Text("unread")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let first = snapshot.links.first {
                    Text(first.title)
                        .font(.caption2)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        default:
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Reading List")
                        .font(.headline)
                    Spacer()
                    Text("\(snapshot.unreadCount) unread")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                if snapshot.links.isEmpty {
                    Text("All read.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                ForEach(snapshot.links.prefix(3)) { link in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(link.title)
                            .font(.subheadline)
                            .lineLimit(1)
                        Text(link.site)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

// MARK: - New note

/// The Lock Screen's way to a new note.
struct NewNoteWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: SharedContainer.WidgetKind.newNote, provider: SnapshotProvider()) { _ in
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: "square.and.pencil")
                    .font(.title2)
            }
            .containerBackground(.clear, for: .widget)
            .widgetURL(KnowledgeLink.new(.note, project: nil).url)
            .accessibilityLabel("New Note")
        }
        .configurationDisplayName("New Note")
        .description("Opens Cortex with a new note in the inbox.")
        .supportedFamilies([.accessoryCircular])
    }
}

/// Control Center's (and the Action button's) way to a new note.
struct NewNoteControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: SharedContainer.WidgetKind.newNoteControl) {
            ControlWidgetButton(action: NewNoteIntent()) {
                Label("New Note", systemImage: "square.and.pencil")
            }
        }
        .displayName("New Note")
        .description("Opens Cortex with a new note in the inbox.")
    }
}
