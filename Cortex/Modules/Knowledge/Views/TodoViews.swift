import SwiftUI
import CortexCore

/// The `!` scope: the to-dos and the row that adds one, and the selected
/// to-do's body and checklist.
struct TodoView: View {
    let scope: TodoScope

    var body: some View {
        PaletteSplitLayout {
            PaletteList(
                list: scope.list,
                empty: PaletteEmptyState(
                    title: TodoQuery.parse(scope.query).showsDone ? "Nothing done yet" : "Nothing to do",
                    systemImage: "checklist",
                    description: "Type a to-do and press ⏎ to add it. @project puts it in a project, #tag tags it."),
                onActivate: { scope.choose($0) }
            ) { row, _, isSelected in
                TodoRowView(row: row, project: { scope.project($0) ?? KnowledgeProject(id: $0) }, isSelected: isSelected)
            }
        } preview: {
            TodoPreviewView(
                row: scope.list.selected, checklist: scope.checklist, checklistIndex: scope.checklistIndex,
                project: { scope.project($0) ?? KnowledgeProject(id: $0) })
        }
    }
}

struct TodoRowView: View {
    let row: TodoRow
    let project: (String) -> KnowledgeProject
    let isSelected: Bool

    var body: some View {
        switch row {
        case .todo(let todo):
            PaletteRow(
                symbol: todo.status == .done ? "checkmark.circle.fill" : "circle", title: todo.title,
                subtitle: Self.subtitle(todo), tag: TintedTag(project: project(todo.project)), shortcutNumber: nil, isSelected: isSelected)
                .opacity(todo.status == .done ? 0.6 : 1)
        case .add(let draft):
            PaletteRow(
                symbol: draft.isSensitive ? "exclamationmark.lock" : "plus.circle", title: "Add to-do “\(draft.title)”",
                subtitle: draft.isSensitive ? "Looks like a password or key"
                    : draft.tags.isEmpty ? nil : draft.tags.map { "#\($0)" }.joined(separator: " "),
                tag: TintedTag(project: project(draft.project)), shortcutNumber: nil, isSelected: isSelected)
        }
    }

    /// "Due Oct 30 · 1 of 3 · #backup", or the first line of the body.
    static func subtitle(_ todo: KnowledgeItem) -> String? {
        var parts: [String] = []
        if todo.status == .done {
            parts.append("Done " + (todo.frontMatter.date("done") ?? todo.updated).formatted(.relative(presentation: .named)))
        } else if let due = todo.due {
            parts.append(dueText(due))
        }
        let checklist = TodoChecklist(body: todo.body)
        if !checklist.isEmpty { parts.append("\(checklist.doneCount) of \(checklist.items.count)") }
        if !todo.tags.isEmpty { parts.append(todo.tags.map { "#\($0)" }.joined(separator: " ")) }
        if parts.isEmpty {
            let line = PaletteRow.firstLine(of: todo.body)
            return line.isEmpty ? nil : line
        }
        return parts.joined(separator: " · ")
    }

    /// "Due today", "Overdue since Oct 21", "Due Oct 30".
    static func dueText(_ due: String) -> String {
        let today = FrontMatter.formatDay(.now)
        let day = String(due.prefix(10))
        guard let date = FrontMatter.parseDate(day) else { return "Due \(due)" }
        let formatted = date.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, timeZone: TimeZone(identifier: "UTC")!))
        if day == today { return "Due today" }
        return day < today ? "Overdue since \(formatted)" : "Due \(formatted)"
    }
}

/// The selected to-do: title, project and dates, the body, and the
/// checklist with the item ⇥ moved to.
struct TodoPreviewView: View {
    let row: TodoRow?
    let checklist: TodoChecklist
    let checklistIndex: Int?
    let project: (String) -> KnowledgeProject

    var body: some View {
        switch row {
        case .todo(let todo):
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(todo.title).font(.headline).lineLimit(2)
                    HStack(spacing: 6) {
                        TintedTag(project: project(todo.project))
                        if let subtitle = TodoRowView.subtitle(todo) { Text("· \(subtitle)") }
                        Spacer(minLength: 0)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if !checklist.isEmpty {
                            checklistView
                        }
                        let text = Self.textWithoutChecklist(todo.body, checklist: checklist)
                        if !text.isEmpty {
                            Text(text)
                                .font(.callout)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(16)
                }
            }
        case .add(let draft):
            VStack(alignment: .leading, spacing: 8) {
                Text(draft.title).font(.headline)
                Text(KnowledgeFolder.todoPath(project: draft.project, title: draft.title, date: .now))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Text("⏎ adds it and stays here for the next one.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        case nil:
            Color.clear
        }
    }

    private var checklistView: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(checklist.items.enumerated()), id: \.offset) { index, item in
                let isFocused = index == checklistIndex
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: item.isDone ? "checkmark.square.fill" : "square")
                        .foregroundStyle(isFocused ? .white : item.isDone ? .secondary : .primary)
                    Text(item.text)
                        .strikethrough(item.isDone)
                        .foregroundStyle(isFocused ? .white : item.isDone ? .secondary : .primary)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .paletteSelection(isFocused)
            }
        }
    }

    /// The body without the task list lines, which the checklist shows.
    static func textWithoutChecklist(_ body: String, checklist: TodoChecklist) -> String {
        let lines = Set(checklist.items.map(\.line))
        return body.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
            .filter { !lines.contains($0.offset) }
            .map { String($0.element) }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
