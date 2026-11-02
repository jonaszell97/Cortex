import Foundation
import CortexCore

/// The knowledge browser's state: the project picked in the sidebar, the
/// kind picked above the list, that project's items of each kind (narrowed
/// by the search field) and the item shown on the right, edited through a
/// `NoteEditorModel`. Edits are saved before anything else is shown, and
/// with ⌘S; when that save fails (the file changed on disk), the browser
/// stays where it is.
@MainActor
@Observable
final class KnowledgeBrowserModel {
    /// The kinds the list offers, in the picker's order.
    static let kinds: [KnowledgeKind] = [.note, .todo, .skill]
    /// More than any project holds; the index wants a limit.
    static let itemLimit = 10_000

    let service: KnowledgeService
    /// The selected item's title, tags, description and text as edited.
    let editor: NoteEditorModel
    private(set) var projectID: String? = KnowledgeProject.inboxID
    private(set) var kind: KnowledgeKind = .note
    private(set) var selectedPath: String? {
        didSet {
            guard selectedPath != oldValue, selectedPath != editor.path else { return }
            newTag = ""
            if let selectedPath { editor.load(selectedPath) } else { editor.clear() }
        }
    }
    /// The search field: words that must all be in an item's title, tags or
    /// text.
    var filter = ""
    /// Typed into the tag field but not added as a chip yet. It counts as a
    /// tag all the same, so saving never drops it.
    var newTag = ""
    /// The selected project's items per kind, ordered for the list.
    private(set) var items: [KnowledgeKind: [KnowledgeItem]] = [:]
    /// The project `items` were loaded for.
    private(set) var loadedProjectID: String?

    init(service: KnowledgeService) {
        self.service = service
        editor = NoteEditorModel(service: service)
    }

    var projects: [KnowledgeProject] { service.projects }

    var project: KnowledgeProject? {
        projects.first { $0.id == projectID }
    }

    /// The items of the picked kind.
    var listed: [KnowledgeItem] { items[kind] ?? [] }

    /// The list: the items of the picked kind that match the search.
    var filtered: [KnowledgeItem] {
        let words = filter.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return listed }
        return listed.filter { item in
            let text = ([item.title, item.summary ?? "", item.body] + item.tags).joined(separator: "\n")
            return words.allSatisfy { text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
    }

    /// Edits in the editor, or a tag typed but not added.
    var isDirty: Bool {
        editor.isDirty || !newTag.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// The selected item as last indexed (its metadata).
    var selected: KnowledgeItem? {
        listed.first { $0.path == selectedPath }
    }

    func count(of kind: KnowledgeKind) -> Int {
        items[kind]?.count ?? 0
    }

    func projectName(_ id: String) -> String {
        projects.first { $0.id == id }?.name ?? KnowledgeProject.defaultName(for: id)
    }

    // MARK: - Navigating

    /// Shows another project, after saving the edits.
    func selectProject(_ id: String?) async {
        guard id != projectID, await saveEdits() else { return }
        projectID = id
        await load()
    }

    /// Lists another kind, after saving the edits.
    func selectKind(_ kind: KnowledgeKind) async {
        guard kind != self.kind, await saveEdits() else { return }
        self.kind = kind
        keepSelection()
    }

    /// Shows another item, after saving the edits.
    func select(_ path: String?) async {
        guard path != selectedPath, await saveEdits() else { return }
        selectedPath = path
    }

    /// Shows an item: its project, its kind, and it selected; a project's
    /// README shows just the project.
    func reveal(_ path: String) async {
        guard let (project, kind) = KnowledgePath.classify(path), kind == .project || Self.kinds.contains(kind),
              await saveEdits()
        else { return }
        projectID = project
        if kind != .project {
            self.kind = kind
            selectedPath = path
        }
        await load()
    }

    /// Reads the selected project's items again (it changed, or the files did).
    func load() async {
        guard let projectID else {
            items = [:]
            loadedProjectID = nil
            selectedPath = nil
            return
        }
        let hits = await service.search(
            KnowledgeQuery(projectID: projectID, kinds: Set(Self.kinds)), limit: Self.itemLimit)
        // Another project was picked while this one loaded.
        guard projectID == self.projectID else { return }
        items = Self.grouped(hits.map(\.item), project: projectID)
        loadedProjectID = projectID
        keepSelection()
    }

    /// The selection stays when it is still listed, follows the editor when
    /// a save renamed the file, else moves to the first item. Never while
    /// there are edits: they stay on screen until saved or dropped.
    private func keepSelection() {
        guard !listed.contains(where: { $0.path == selectedPath }), !editor.isDirty else { return }
        if let path = editor.path, listed.contains(where: { $0.path == path }) {
            selectedPath = path
        } else {
            selectedPath = listed.first?.path
        }
    }

    // MARK: - Editing

    /// Saves the edits, if any. false: the save failed (a conflict, which
    /// the window asks about, or an error it shows).
    func saveEdits() async -> Bool {
        guard isDirty, !editor.isGone else { return true }
        return await save()
    }

    /// ⌘S. A new title renames the file; the selection follows it.
    @discardableResult
    func save() async -> Bool {
        addNewTag()
        guard await editor.save() else { return false }
        if let path = editor.path { selectedPath = path }
        return true
    }

    // MARK: - Tags

    /// The tags as chips: the editor keeps them comma-separated.
    var tags: [String] {
        Self.tags(from: editor.fields.tags)
    }

    /// Turns what is typed in the tag field into a chip.
    func addNewTag() {
        let added = Self.tags(from: newTag).filter { !tags.contains($0) }
        newTag = ""
        guard !added.isEmpty else { return }
        editor.fields.tags = (tags + added).joined(separator: ", ")
    }

    func removeTag(_ tag: String) {
        editor.fields.tags = tags.filter { $0 != tag }.joined(separator: ", ")
    }

    static func tags(from text: String) -> [String] {
        text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Moves the selected note or to-do to another project, with any other
    /// edits. It leaves the list, and the item after it (else before it) is
    /// selected, so an inbox can be sorted one item after the other.
    func move(to project: String) async {
        guard editor.canMove, project != editor.fields.project, let path = selectedPath else { return }
        let neighbour = neighbour(of: path)
        addNewTag()
        editor.fields.project = project
        guard await editor.save() else { return }
        selectedPath = neighbour
        await load()
    }

    /// Moves a note or to-do of the list (its context menu) to another
    /// project.
    func move(_ path: String, to project: String) async {
        guard path != selectedPath else { return await move(to: project) }
        do {
            let text = try service.folder.text(at: path)
            guard let item = KnowledgeItem.parse(path: path, text: text, modified: .now), item.kind == .note || item.kind == .todo,
                  item.project != project
            else { return }
            var edit = KnowledgeEdit(item, text: text)
            edit.project = project
            try await service.save(edit, at: path)
            await load()
        } catch {
            editor.error = error.localizedDescription
        }
    }

    /// Closes or reopens a to-do from its row, after saving the edits when
    /// it is the one shown.
    func setDone(_ path: String, _ isDone: Bool) async {
        if path == selectedPath, await !saveEdits() { return }
        do {
            try await service.setStatus(isDone ? .done : .open, of: path)
            if path == editor.path { editor.load(path) }
            await load()
        } catch {
            editor.error = error.localizedDescription
        }
    }

    /// A note or to-do in the selected project, then shown with nothing
    /// else to save.
    func create(_ kind: KnowledgeKind, title: String) async {
        guard let projectID, kind == .note || kind == .todo, await saveEdits() else { return }
        do {
            let path = try await service.create(kind, title: title, project: projectID)
            filter = ""
            await reveal(path)
        } catch {
            editor.error = error.localizedDescription
        }
    }

    /// Moves the item's file (a skill's whole folder) to the Trash; the
    /// item after it is selected.
    func delete(_ path: String) async {
        let next = path == selectedPath ? neighbour(of: path) : selectedPath
        do {
            try await service.delete(path)
            if path == selectedPath {
                editor.clear()
                selectedPath = next
            }
            await load()
        } catch {
            editor.error = error.localizedDescription
        }
    }

    /// The item after `path` in the list, else the one before it.
    private func neighbour(of path: String) -> String? {
        let list = filtered
        guard let index = list.firstIndex(where: { $0.path == path }) else { return nil }
        return list.indices.contains(index + 1) ? list[index + 1].path : index > 0 ? list[index - 1].path : nil
    }

    /// An image or other file the shown item refers to.
    func linkedFile(_ source: String) -> URL? {
        editor.path.flatMap { service.folder.linkedFile(source, relativeTo: $0) }
    }

    /// Saves, then opens the file in VS Code.
    func openSelected() async {
        await editor.openInEditor()
    }

    // MARK: - Ordering

    /// Notes newest first, to-dos as `!` lists them (open ones first, then
    /// done ones, last done first), skills by name.
    static func grouped(_ items: [KnowledgeItem], project: String) -> [KnowledgeKind: [KnowledgeItem]] {
        let byKind = Dictionary(grouping: items, by: \.kind)
        let todos = byKind[.todo] ?? []
        return [
            .note: (byKind[.note] ?? []).sorted { $0.updated != $1.updated ? $0.updated > $1.updated : $0.path < $1.path },
            .todo: TodoList.ordered(todos.filter { $0.status != .done }, projects: [project])
                + TodoList.orderedDone(todos.filter { $0.status == .done }),
            .skill: (byKind[.skill] ?? []).sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending },
        ]
    }
}

extension KnowledgeKind {
    /// "Notes", "To-Dos", "Skills": the picker above the browser's list.
    var pluralTitle: String {
        switch self {
        case .note: "Notes"
        case .todo: "To-Dos"
        case .skill: "Skills"
        case .project: "Projects"
        }
    }
}
