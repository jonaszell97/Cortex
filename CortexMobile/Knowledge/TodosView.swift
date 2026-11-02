import SwiftUI
import CortexCore

/// Every project's to-dos, as the Mac's `!` lists them: the open ones with
/// the due ones on top (overdue in red), or the done ones, last done first.
/// The circle ticks one off.
struct TodosView: View {
    @Environment(KnowledgeStore.self) private var knowledge
    @Environment(MobileSyncService.self) private var sync
    @Environment(ItemActions.self) private var actions
    @State private var showsDone = false
    @State private var todos: [KnowledgeItem]?
    @State private var query = ""
    @State private var deleting: KnowledgeItem?
    @State private var error: String?

    var body: some View {
        List {
            Section {
                Picker("Show", selection: $showsDone) {
                    Text("Open").tag(false)
                    Text("Done").tag(true)
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }
            Section {
                ForEach(shown) { item in
                    TodoRow(item: item, project: knowledge.project(item.project).name) { toggle(item) }
                        .swipeActions(edge: .leading) {
                            Button(item.status == .done ? "Reopen" : "Done", systemImage: item.status == .done ? "circle" : "checkmark") {
                                toggle(item)
                            }
                            .tint(.green)
                            if item.status != .done {
                                Button("Remind", systemImage: "checklist.unchecked") { actions.addToReminders(item) }
                                    .tint(.orange)
                            }
                        }
                        .swipeActions(edge: .trailing) {
                            Button("Delete", systemImage: "trash", role: .destructive) { deleting = item }
                        }
                        .itemActions(item)
                }
            } footer: {
                Text(sync.footerLine ?? "")
            }
        }
        .navigationTitle("To-Dos")
        .navigationDestination(for: ItemRoute.self) { ItemView(path: $0.path) }
        .toolbar {
            ToolbarItem(placement: .primaryAction) { NewItemMenu() }
        }
        .searchable(text: $query, prompt: "Filter")
        .refreshable { await sync.syncNow() }
        .task(id: LoadKey(showsDone: showsDone, revision: knowledge.revision)) {
            todos = await knowledge.todos(done: showsDone)
        }
        .overlay {
            if let todos, shown.isEmpty {
                if !query.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else if todos.isEmpty {
                    ContentUnavailableView(showsDone ? "Nothing done yet" : "Nothing to do", systemImage: "checklist")
                }
            }
        }
        .confirmationDialog(
            "Delete “\(deleting?.title ?? "")”?", isPresented: Binding { deleting != nil } set: { if !$0 { deleting = nil } },
            titleVisibility: .visible, presenting: deleting
        ) { item in
            Button("Delete", role: .destructive) { perform { try await knowledge.delete(item.path) } }
        }
        .alert("Couldn't change it", isPresented: Binding { error != nil } set: { if !$0 { error = nil } }) {
            Button("OK") {}
        } message: {
            Text(error ?? "")
        }
    }

    private struct LoadKey: Equatable {
        var showsDone: Bool
        var revision: Int
    }

    private var shown: [KnowledgeItem] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return todos ?? [] }
        return (todos ?? []).filter { item in
            let text = ([item.title, knowledge.project(item.project).name] + item.tags).joined(separator: " ").lowercased()
            return words.allSatisfy { text.contains($0) }
        }
    }

    private func toggle(_ item: KnowledgeItem) {
        perform { try await knowledge.setStatus(item.status == .done ? .open : .done, of: item.path) }
    }

    private func perform(_ change: @escaping () async throws -> Void) {
        Task {
            do {
                try await change()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

/// A to-do with a circle to tick it off; the rest of the row opens it.
private struct TodoRow: View {
    let item: KnowledgeItem
    let project: String
    let toggle: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Button(action: toggle) {
                Image(systemName: ItemRow.symbol(for: item))
                    .font(.title3)
                    .foregroundStyle(item.status == .done ? Color.secondary : Color.accentColor)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .sensoryFeedback(.success, trigger: item.status)
            .accessibilityLabel(item.status == .done ? "Reopen" : "Mark Done")
            NavigationLink(value: ItemRoute(path: item.path)) {
                ItemRow(item: item, detail: checklistLine, project: project, showsIcon: false)
            }
        }
    }

    /// "2/5" for a to-do with a checklist.
    private var checklistLine: String? {
        let checklist = TodoChecklist(body: item.body)
        return checklist.isEmpty ? nil : "\(checklist.doneCount)/\(checklist.items.count)"
    }
}
