import SwiftUI
import CortexCore

/// A note, skill, to-do or project README: its metadata as a header, its
/// body rendered, its checklist tappable. Edit opens the editor; a save that
/// moves the file (a new title or project) follows it here.
struct ItemView: View {
    @Environment(KnowledgeStore.self) private var knowledge
    @Environment(EditorPresenter.self) private var editor
    @Environment(\.dismiss) private var dismiss
    @State private var path: String
    @State private var item: KnowledgeItem?
    @State private var blocks: [MarkdownBlock] = []
    @State private var checklistIndices: [Int: Int] = [:]
    @State private var isMissing = false
    @State private var newChecklistItem = ""
    @State private var confirmingDelete = false
    @State private var error: String?

    init(path: String) {
        _path = State(initialValue: path)
    }

    var body: some View {
        Group {
            if let item {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        header(item)
                        if !blocks.isEmpty { Divider() }
                        MarkdownView(
                            blocks: blocks, resolveFile: { knowledge.file($0, relativeTo: path) },
                            checklistIndices: checklistIndices, toggleChecklistItem: { index in
                                perform { try await knowledge.toggleChecklistItem(index, of: path) }
                            })
                        if item.kind == .todo { addChecklistItemField }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                }
                .textSelection(.enabled)
                .toolbar { toolbar(item) }
            } else if isMissing {
                ContentUnavailableView(
                    "Not here anymore", systemImage: "doc.questionmark",
                    description: Text("It was deleted or moved on another device."))
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .task(id: LoadKey(path: path, revision: knowledge.revision)) { load() }
        .onChange(of: editor.lastMove) { _, move in
            if let move, move.from == path { path = move.to }
        }
        .confirmationDialog(
            "Delete “\(item?.title ?? "")”?", isPresented: $confirmingDelete, titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                perform {
                    try await knowledge.delete(path)
                    dismiss()
                }
            }
        } message: {
            Text("It is deleted on your Macs too, which keep a copy in the knowledge folder's .conflicts folder.")
        }
        .alert("Couldn't change it", isPresented: Binding { error != nil } set: { if !$0 { error = nil } }) {
            Button("OK") {}
        } message: {
            Text(error ?? "")
        }
    }

    private struct LoadKey: Equatable {
        var path: String
        var revision: Int
    }

    private func load() {
        item = knowledge.item(at: path)
        isMissing = item == nil
        guard let body = item?.body else { return }
        blocks = MarkdownBlock.parse(body)
        checklistIndices = MarkdownBlock.checklistIndices(of: blocks, body: body)
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

    @ToolbarContentBuilder
    private func toolbar(_ item: KnowledgeItem) -> some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button("Edit", systemImage: "pencil") { editor.edit(path) }
        }
        ToolbarItem(placement: .primaryAction) {
            Menu("More", systemImage: "ellipsis") {
                if let status = item.status {
                    Button(status == .done ? "Mark Open" : "Mark Done", systemImage: status == .done ? "circle" : "checkmark.circle") {
                        perform { try await knowledge.setStatus(status == .done ? .open : .done, of: path) }
                    }
                }
                ItemActionsMenu(item: item)
                Section {
                    NewItemButtons(project: item.project)
                }
                if item.kind != .project {
                    Button("Delete…", systemImage: "trash", role: .destructive) { confirmingDelete = true }
                }
            }
        }
    }

    /// Under a to-do's text: a field that adds an open checklist item.
    private var addChecklistItemField: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "plus")
                .foregroundStyle(.secondary)
                .frame(minWidth: 18, alignment: .trailing)
            TextField("Add item", text: $newChecklistItem)
                .submitLabel(.done)
                .onSubmit {
                    let text = newChecklistItem.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { return }
                    newChecklistItem = ""
                    perform { try await knowledge.addChecklistItem(text, to: path) }
                }
        }
    }

    private func header(_ item: KnowledgeItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(item.title)
                .font(.title2.bold())
                .strikethrough(item.status == .done)
            if let summary = item.summary, !summary.isEmpty, item.kind != .project {
                Text(summary)
                    .foregroundStyle(.secondary)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { metadata(item) }
                VStack(alignment: .leading, spacing: 4) { metadata(item) }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if !item.tags.isEmpty {
                Text(item.tags.map { "#" + $0 }.joined(separator: " "))
                    .font(.caption)
                    .foregroundStyle(.tint)
            }
        }
    }

    @ViewBuilder
    private func metadata(_ item: KnowledgeItem) -> some View {
        let project = knowledge.project(item.project)
        TintedTag(project: project)
        if let status = item.status {
            Button {
                perform { try await knowledge.setStatus(status == .done ? .open : .done, of: path) }
            } label: {
                Label(status == .done ? "Done" : "Open", systemImage: ItemRow.symbol(for: item))
            }
            .buttonStyle(.borderless)
            .sensoryFeedback(.success, trigger: status)
        }
        if let due = item.due {
            Label("Due \(due)", systemImage: "calendar")
                .foregroundStyle(item.status == .open && TodoList.isOverdue(due) ? Color.red : Color.secondary)
        }
        Label(item.updated.formatted(.relative(presentation: .named)), systemImage: "clock")
    }
}
