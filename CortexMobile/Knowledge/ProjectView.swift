import SwiftUI
import CortexCore

/// One project: open to-dos, notes, skills, then done to-dos, each most
/// recently updated first. The README is "About". New notes and to-dos
/// made here go into this project.
struct ProjectView: View {
    let projectID: String
    @Environment(KnowledgeStore.self) private var knowledge
    @Environment(MobileSyncService.self) private var sync
    @State private var items: [KnowledgeItem]?

    private var project: KnowledgeProject { knowledge.project(projectID) }

    var body: some View {
        List {
            if let readme = items?.first(where: { $0.kind == .project }) {
                Section {
                    NavigationLink(value: ItemRoute(path: readme.path)) {
                        Label("About", systemImage: "info.circle")
                    }
                    .itemActions(readme)
                }
            }
            section("To-dos", items: openTodos)
            section("Notes", items: items(of: .note))
            section("Skills", items: items(of: .skill))
            section("Done", items: doneTodos)
        }
        .navigationTitle(project.name)
        .toolbar {
            ToolbarItem(placement: .primaryAction) { NewItemMenu(project: projectID) }
        }
        .refreshable { await sync.syncNow() }
        .task(id: knowledge.revision) {
            items = await knowledge.items(in: projectID, kinds: Set(KnowledgeKind.allCases))
        }
        .overlay {
            if let items, items.allSatisfy({ $0.kind == .project }) {
                ContentUnavailableView("Nothing in \(project.name)", systemImage: "folder")
            }
        }
    }

    @ViewBuilder
    private func section(_ title: String, items: [KnowledgeItem]) -> some View {
        if !items.isEmpty {
            Section(title) {
                ForEach(items) { item in
                    NavigationLink(value: ItemRoute(path: item.path)) { ItemRow(item: item) }
                        .itemActions(item)
                }
            }
        }
    }

    private func items(of kind: KnowledgeKind) -> [KnowledgeItem] {
        (items ?? []).filter { $0.kind == kind }
    }

    private var openTodos: [KnowledgeItem] {
        TodoList.ordered(items(of: .todo).filter { $0.status != .done }, projects: [projectID])
    }

    private var doneTodos: [KnowledgeItem] {
        TodoList.orderedDone(items(of: .todo).filter { $0.status == .done })
    }
}

/// An item in a list: its symbol, title, and a second line (a search
/// snippet, the summary, or the due day and tags).
struct ItemRow: View {
    let item: KnowledgeItem
    var detail: String?
    /// Shown in search results, where items of every project mix.
    var project: String?
    /// The to-dos list draws its own circle, a button.
    var showsIcon = true

    var body: some View {
        if showsIcon {
            Label {
                text
            } icon: {
                Image(systemName: Self.symbol(for: item))
                    .foregroundStyle(item.status == .done ? Color.secondary : Color.accentColor)
            }
        } else {
            text
        }
    }

    private var text: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(item.title)
                .strikethrough(item.status == .done)
                .lineLimit(2)
            if let line = secondLine {
                Text(line)
                    .font(.caption)
                    .foregroundStyle(isOverdue ? Color.red : Color.secondary)
                    .lineLimit(2)
            }
        }
    }

    private var isOverdue: Bool {
        item.status == .open && item.due.map { TodoList.isOverdue($0) } == true
    }

    private var secondLine: String? {
        var parts: [String] = []
        if let project { parts.append(project) }
        if let due = item.due, item.status == .open { parts.append("Due \(due)") }
        if let detail, !detail.isEmpty {
            parts.append(detail)
        } else if let summary = item.summary, !summary.isEmpty {
            parts.append(summary)
        }
        if !item.tags.isEmpty { parts.append(item.tags.map { "#" + $0 }.joined(separator: " ")) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    static func symbol(for item: KnowledgeItem) -> String {
        switch item.kind {
        case .note: "doc.text"
        case .skill: "wand.and.sparkles"
        case .todo: item.status == .done ? "checkmark.circle" : "circle"
        case .project: "folder"
        }
    }
}
