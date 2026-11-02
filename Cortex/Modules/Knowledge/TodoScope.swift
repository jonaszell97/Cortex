import AppKit
import SwiftUI
import CortexCore

/// A row of the `!` list.
enum TodoRow: Identifiable, Equatable {
    case todo(KnowledgeItem)
    case add(TodoDraft)

    var id: String {
        switch self {
        case .todo(let item): "todo:\(item.path)"
        case .add: "add"
        }
    }

    var todo: KnowledgeItem? {
        if case .todo(let item) = self { return item }
        return nil
    }
}

/// `!` in the palette: the to-dos (docs/modules/KNOWLEDGE.md, "The palette").
/// Alone, the open ones, due ones on top, then by project; with words, those that
/// match. `done` first lists the done ones. The last row adds what was typed as a
/// to-do (`@project` and `#tag` say where and how), and the palette stays on the
/// list for the next one. ⌘D closes or reopens the selected to-do, ⇥ or ⏎ moves
/// into its checklist where ⏎ ticks an item, ⌘E edits it, ⌘⏎ opens it in VS Code,
/// ⌘⌫ moves it to the Trash.
@MainActor
@Observable
final class TodoScope: PaletteScope {
    /// The route's ID, a subscope of the Knowledge module.
    static let id: ModuleID = "todos"
    static let limit = 500

    let list = ResultList<TodoRow, String>(id: \.id)
    /// The query as last searched.
    private(set) var query = ""
    /// The checklist item ⇥ moved to, in the selected to-do; nil while the
    /// list has the arrow keys.
    private(set) var checklistIndex: Int?

    @ObservationIgnored private let service: KnowledgeService
    @ObservationIgnored private let palette: @MainActor () -> any PaletteHost
    @ObservationIgnored private let edit: @MainActor (String) -> Void
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    /// nil while nothing is loaded (the palette is hidden).
    @ObservationIgnored private var loadedQuery: String?
    /// Closed or reopened since this query was typed: still listed, so a
    /// second ⌘D undoes the first.
    @ObservationIgnored private var toggled: Set<String> = []
    /// Selected once the list for that query has loaded (a to-do just added).
    @ObservationIgnored private var pendingSelection: (query: String, id: String)?

    init(
        service: KnowledgeService, palette: @escaping @MainActor () -> any PaletteHost,
        edit: @escaping @MainActor (String) -> Void
    ) {
        self.service = service
        self.palette = palette
        self.edit = edit
        list.didSelect = { [weak self] _ in self?.checklistIndex = nil }
    }

    /// The files changed: search again if the list is showing.
    func knowledgeDidChange() {
        if let loadedQuery { search(loadedQuery) }
    }

    /// Waits for the search to finish (for tests).
    func loaded() async {
        await searchTask?.value
    }

    var selectedTodo: KnowledgeItem? { list.selected?.todo }

    var checklist: TodoChecklist {
        TodoChecklist(body: selectedTodo?.body ?? "")
    }

    func project(_ id: String) -> KnowledgeProject? {
        service.projects.first { $0.id == id }
    }

    // MARK: - Rows

    private func rows(for text: String) async -> [TodoRow] {
        let query = TodoQuery.parse(text)
        var items = await service.todos(query, limit: Self.limit)
        let missing = toggled.subtracting(items.map(\.path))
        if !missing.isEmpty {
            let index = service.index
            items += missing.sorted().compactMap { try? index.item(at: $0) }
            items = query.showsDone ? TodoList.orderedDone(items) : TodoList.ordered(items, projects: service.projects.map(\.id))
        }
        var rows = items.map(TodoRow.todo)
        if let title = query.newTitle {
            rows.append(.add(TodoDraft(
                title: title, project: service.project(matching: query.query.project), tags: query.query.tags,
                isSensitive: SensitiveTextDetector.looksSensitive(title))))
        }
        return rows
    }

    // MARK: - PaletteScope

    func search(_ text: String) {
        if text != loadedQuery {
            toggled = []
            checklistIndex = nil
        }
        query = text
        loadedQuery = text
        let load = list.load(query: text) { [weak self] in
            await self?.rows(for: text) ?? []
        }
        searchTask = Task { [weak self] in
            await load.value
            guard let self, let pending = pendingSelection, pending.query == text else { return }
            pendingSelection = nil
            if list.items.contains(where: { $0.id == pending.id }) { list.select(pending.id) }
        }
    }

    func clear() {
        list.clear()
        loadedQuery = nil
        toggled = []
        checklistIndex = nil
    }

    var body: AnyView { AnyView(TodoView(scope: self)) }

    func move(_ step: PaletteStep) {
        guard case .vertical(let delta) = step else { return }
        if let index = checklistIndex {
            checklistIndex = min(max(index + delta, 0), checklist.items.count - 1)
        } else {
            list.move(by: delta)
        }
    }

    func activate(_ activation: PaletteActivation, target: PaletteTarget) -> Bool {
        guard target == .selected, let row = list.selected else { return false }
        choose(row)
        return true
    }

    var activationHints: [PaletteHint] {
        if checklistIndex != nil { return [PaletteHint(.primary, "Tick")] }
        switch list.selected {
        case .add?: return [PaletteHint(.primary, "Add")]
        case .todo?: return [PaletteHint(.primary, checklist.isEmpty ? "Edit" : "Checklist")]
        case nil: return []
        }
    }

    var keys: [PaletteKey] {
        let todo = selectedTodo
        let tabHint = checklistIndex != nil ? "List" : checklist.isEmpty ? nil : "Checklist"
        return [
            PaletteKey(.command("d"), hint: todo.map { $0.status == .done ? "Reopen" : "Done" }) { [unowned self] in
                guard let todo = selectedTodo else { return false }
                toggleDone(todo)
                return true
            },
            PaletteKey(.tab, hint: tabHint) { [unowned self] in
                if checklistIndex != nil {
                    checklistIndex = nil
                    return true
                }
                return enterChecklist()
            },
            PaletteKey(.command("e"), hint: todo == nil ? nil : "Edit") { [unowned self] in
                guard let todo = selectedTodo else { return false }
                openEditor(todo.path)
                return true
            },
            PaletteKey(KnowledgeScope.openKey, hint: nil) { [unowned self] in
                guard let todo = selectedTodo else { return false }
                palette().close()
                service.open(todo.path)
                return true
            },
            PaletteKey(.command(.delete), hint: todo == nil ? nil : "Delete") { [unowned self] in
                guard let todo = selectedTodo else { return true }
                palette().present(deleteOverlay(for: todo))
                return true
            },
        ]
    }

    /// Esc leaves the checklist first.
    func cancel() -> Bool {
        guard checklistIndex != nil else { return false }
        checklistIndex = nil
        return true
    }

    // MARK: - Actions

    func choose(_ row: TodoRow) {
        switch row {
        case .add(let draft) where draft.isSensitive:
            palette().present(sensitiveOverlay(for: draft))
        case .add(let draft):
            add(draft)
        case .todo(let todo):
            if let index = checklistIndex {
                tick(index, of: todo)
            } else if !enterChecklist() {
                openEditor(todo.path)
            }
        }
    }

    /// Moves the arrow keys into the selected to-do's checklist, onto its
    /// first open item. false: it has none.
    @discardableResult
    func enterChecklist() -> Bool {
        let items = checklist.items
        guard selectedTodo != nil, !items.isEmpty else { return false }
        checklistIndex = items.firstIndex { !$0.isDone } ?? 0
        return true
    }

    /// Adds the to-do and stays on the list (in its project, if `@` named
    /// one), with the new to-do selected.
    func add(_ draft: TodoDraft) {
        let service = service
        Task { [weak self] in
            do {
                let path = try await service.addTodo(draft)
                guard let self else { return }
                let query = draft.project == KnowledgeProject.inboxID ? "" : "@\(draft.project) "
                pendingSelection = (query, "todo:\(path)")
                palette().open(Self.id, searching: query)
            } catch {
                Beep.play()
                Log.logger("knowledge").error("Adding the to-do failed: \(error, privacy: .public)")
            }
        }
    }

    /// Closes an open to-do or reopens a done one; it stays listed until the
    /// query changes.
    func toggleDone(_ todo: KnowledgeItem) {
        toggled.insert(todo.path)
        let service = service
        Task {
            do {
                try await service.setStatus(todo.status == .done ? .open : .done, of: todo.path)
            } catch {
                Beep.play()
            }
        }
    }

    func tick(_ index: Int, of todo: KnowledgeItem) {
        let service = service
        Task {
            do {
                try await service.toggleChecklistItem(index, of: todo.path)
            } catch {
                Beep.play()
            }
        }
    }

    private func openEditor(_ path: String) {
        palette().close()
        edit(path)
    }

    func sensitiveOverlay(for draft: TodoDraft) -> PaletteOverlay {
        PaletteOverlay(
            body: AnyView(KnowledgeConfirmView(
                symbol: "exclamationmark.lock", title: "Add “\(draft.title)” anyway?",
                message: "It looks like a password or key. To-dos are plain files: they are kept in the git history, synced and readable by any app.")),
            activationHints: [PaletteHint(.primary, "Add anyway")],
            activate: { [unowned self] _ in add(draft) },
            escape: .dismiss)
    }

    func deleteOverlay(for todo: KnowledgeItem) -> PaletteOverlay {
        let query = query
        return PaletteOverlay(
            body: AnyView(KnowledgeConfirmView(
                symbol: "trash", title: "Delete “\(todo.title)”?",
                message: "\(todo.path) goes to the Trash\(service.settings.keepHistory ? " and stays in the folder’s history" : "").")),
            activationHints: [PaletteHint(.primary, "Delete")],
            activate: { [unowned self] _ in
                let service = service
                Task { [weak self] in
                    do {
                        try await service.delete(todo.path)
                    } catch {
                        Beep.play()
                    }
                    self?.palette().open(Self.id, searching: query)
                }
            },
            escape: .dismiss)
    }
}
