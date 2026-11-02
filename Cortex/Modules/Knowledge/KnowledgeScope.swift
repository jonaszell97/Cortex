import AppKit
import SwiftUI
import CortexCore

/// A row of the `?` list.
enum KnowledgeRow: Identifiable, Equatable {
    case project(KnowledgeProject, count: Int)
    case item(KnowledgeHit)
    case capture(KnowledgeCapture)
    case newProject(NewProject)

    var id: String {
        switch self {
        case .project(let project, _): "project:\(project.id)"
        case .item(let hit): hit.item.kind == .project ? "project:\(hit.item.project)" : "item:\(hit.item.path)"
        case .capture(let capture): capture.fromClipboard ? "capture:clipboard" : "capture:text"
        case .newProject(let project): "new-project:\(project.id)"
        }
    }

    var item: KnowledgeItem? {
        if case .item(let hit) = self, hit.item.kind != .project { return hit.item }
        return nil
    }
}

/// `?` in the palette: the knowledge base (docs/modules/KNOWLEDGE.md, "The
/// palette"). Alone, the projects and the most recently updated items; with
/// words, a full-text search, best match first (`@project` and `#tag` narrow it).
/// ⏎ pastes the selected item's text, ⌥⏎ copies it, ⌘1–9 paste its code blocks,
/// ⌘E edits it in the note editor, ⌘⏎ opens the file in VS Code, ⌘O shows it in
/// the browser window, ⌘⌫ moves it to the Trash. ⏎ on a project searches in it.
/// When nothing matches, ⏎ saves what was typed as a note in the inbox, with the
/// clipboard's text as its body if wanted. When `@name` names no project, the
/// first row creates it.
@MainActor
@Observable
final class KnowledgeScope: PaletteScope {
    static let recentLimit = 10
    static let searchLimit = 50

    let list = ResultList<KnowledgeRow, String>(id: \.id)
    /// The query as last searched.
    private(set) var query = ""

    @ObservationIgnored private let service: KnowledgeService
    @ObservationIgnored private let moduleID: ModuleID
    @ObservationIgnored private let clipboardText: @MainActor () -> String?
    @ObservationIgnored private let palette: @MainActor () -> any PaletteHost
    @ObservationIgnored private let edit: @MainActor (String) -> Void
    @ObservationIgnored private let browse: @MainActor (String?) -> Void
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    /// nil while nothing is loaded (the palette is hidden).
    @ObservationIgnored private var loadedQuery: String?

    init(
        service: KnowledgeService, moduleID: ModuleID,
        clipboardText: @escaping @MainActor () -> String? = { NSPasteboard.general.string(forType: .string) },
        palette: @escaping @MainActor () -> any PaletteHost,
        edit: @escaping @MainActor (String) -> Void = { _ in },
        browse: @escaping @MainActor (String?) -> Void = { _ in }
    ) {
        self.service = service
        self.moduleID = moduleID
        self.clipboardText = clipboardText
        self.palette = palette
        self.edit = edit
        self.browse = browse
    }

    /// The files changed: search again if the list is showing.
    func knowledgeDidChange() {
        if let loadedQuery { search(loadedQuery) }
    }

    /// Waits for the search to finish (for tests).
    func loaded() async {
        await searchTask?.value
    }

    /// The selected item's fenced code blocks, for ⌘1–9.
    var codeBlocks: [KnowledgeMarkdown.CodeBlock] {
        list.selected?.item.map { KnowledgeMarkdown.codeBlocks(in: $0.body) } ?? []
    }

    func project(_ id: String) -> KnowledgeProject? {
        service.projects.first { $0.id == id }
    }

    // MARK: - Rows

    private func rows(for text: String) async -> [KnowledgeRow] {
        let query = KnowledgeQuery.parse(text)
        let items: Set<KnowledgeKind> = [.note, .skill, .todo]

        let newProject = newProject(for: text, query: query).map { [KnowledgeRow.newProject($0)] } ?? []

        // `?` alone: the projects, then what changed last.
        if text.trimmingCharacters(in: .whitespaces).isEmpty {
            let projects = service.projects.map { KnowledgeRow.project($0, count: service.counts[$0.id] ?? 0) }
            let recent = await service.search(KnowledgeQuery(kinds: items), limit: Self.recentLimit)
            return projects + recent.map(KnowledgeRow.item)
        }
        // Only `@project` or `#tag`: everything in it, newest first.
        guard query.hasText else {
            var filtered = query
            filtered.kinds = items
            return await newProject + service.search(filtered, limit: Self.searchLimit).map(KnowledgeRow.item)
        }
        let hits = await service.search(query, limit: Self.searchLimit)
        return hits.isEmpty ? newProject + captures(for: query) : hits.map(KnowledgeRow.item)
    }

    /// "New project" when the query's `@name` names none. The name keeps
    /// what was typed, unless that is all lowercase.
    private func newProject(for text: String, query: KnowledgeQuery) -> NewProject? {
        guard let prefix = query.project, !service.projects.contains(where: { $0.matches(prefix: prefix) }),
              let token = text.split(whereSeparator: \.isWhitespace).last(where: { $0.hasPrefix("@") && $0.count > 1 })
        else { return nil }
        let typed = String(token.dropFirst())
        // `@!!!` would make a folder called "untitled".
        guard typed.contains(where: { $0.isLetter || $0.isNumber }) else { return nil }
        let id = service.folder.newProjectID(for: typed)
        let name = typed.contains(where: \.isUppercase)
            ? typed.replacing("-", with: " ").replacing("_", with: " ")
            : KnowledgeProject.defaultName(for: id)
        let words = text.split(whereSeparator: \.isWhitespace).filter { !$0.hasPrefix("@") }.joined(separator: " ")
        return NewProject(name: name, id: id, query: "@\(id) " + words)
    }

    /// "Save as note", and "Save clipboard as note" while it holds text.
    private func captures(for query: KnowledgeQuery) -> [KnowledgeRow] {
        let title = query.text.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return [] }
        let project = service.project(matching: query.project)
        var rows = [KnowledgeRow.capture(KnowledgeCapture(
            title: title, body: "", project: project, tags: query.tags, fromClipboard: false,
            isSensitive: SensitiveTextDetector.looksSensitive(title)))]
        if let clipboard = clipboardText(), !clipboard.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            rows.append(.capture(KnowledgeCapture(
                title: title, body: clipboard, project: project, tags: query.tags, fromClipboard: true,
                isSensitive: SensitiveTextDetector.looksSensitive(title) || SensitiveTextDetector.looksSensitive(clipboard))))
        }
        return rows
    }

    // MARK: - PaletteScope

    func search(_ text: String) {
        query = text
        loadedQuery = text
        searchTask = list.load(query: text) { [weak self] in
            await self?.rows(for: text) ?? []
        }
    }

    func clear() {
        list.clear()
        loadedQuery = nil
    }

    var body: AnyView { AnyView(KnowledgeView(scope: self)) }

    func move(_ step: PaletteStep) {
        if case .vertical(let delta) = step { list.move(by: delta) }
    }

    func activate(_ activation: PaletteActivation, target: PaletteTarget) -> Bool {
        switch target {
        case .position(let index):
            // ⌘1–9: the selected note's code blocks.
            guard codeBlocks.indices.contains(index) else { return false }
            deliver(codeBlocks[index].code, copyOnly: activation.isCopy)
            return true
        case .selected:
            guard let row = list.selected else { return false }
            choose(row, copyOnly: activation.isCopy)
            return true
        }
    }

    var activationHints: [PaletteHint] {
        switch list.selected {
        case .capture?:
            return [PaletteHint(.primary, "Save")]
        case .newProject?:
            return [PaletteHint(.primary, "Create project")]
        case let row? where row.item == nil:
            return [PaletteHint(.primary, "Search in project")]
        default:
            let paste = [PaletteHint(.primary, "Paste"), PaletteHint(.option, "Copy")]
            return codeBlocks.isEmpty ? paste : paste + [.positions("Paste code block")]
        }
    }

    var keys: [PaletteKey] {
        let item = list.selected?.item
        return [
            PaletteKey(.command("e"), hint: item == nil ? nil : "Edit") { [unowned self] in
                guard let item = list.selected?.item else { return false }
                palette().close()
                edit(item.path)
                return true
            },
            PaletteKey(KnowledgeScope.openKey, hint: item == nil ? nil : "Open in \(KnowledgeService.editorName)") { [unowned self] in
                guard let item = list.selected?.item else { return false }
                palette().close()
                service.open(item.path)
                return true
            },
            PaletteKey(.command("o"), hint: "Browse") { [unowned self] in
                palette().close()
                browse(browsedPath)
                return true
            },
            PaletteKey(.command(.delete), hint: item == nil ? nil : "Delete") { [unowned self] in
                guard let item = list.selected?.item else { return true }
                palette().present(deleteOverlay(for: item))
                return true
            },
        ]
    }

    /// What ⌘O shows in the browser: the selected item or project, else
    /// what it showed last.
    private var browsedPath: String? {
        switch list.selected {
        case .project(let project, _): "\(project.id)/README.md"
        case .item(let hit): hit.item.path
        default: nil
        }
    }

    /// ⌘⏎.
    static let openKey = KeyCombo(.return, modifiers: .command)

    // MARK: - Actions

    func choose(_ row: KnowledgeRow, copyOnly: Bool = false) {
        switch row {
        case .project(let project, _):
            palette().open(moduleID, searching: "@\(project.id) ")
        case .item(let hit) where hit.item.kind == .project:
            palette().open(moduleID, searching: "@\(hit.item.project) ")
        case .item(let hit):
            deliver(hit.item.pasteText, copyOnly: copyOnly)
        case .capture(let capture) where capture.isSensitive:
            palette().present(sensitiveOverlay(for: capture))
        case .capture(let capture):
            save(capture)
        case .newProject(let project):
            create(project)
        }
    }

    /// Makes the project, then searches in it with the rest of the query,
    /// so a capture typed after `@name` goes there.
    private func create(_ project: NewProject) {
        let service = service
        let moduleID = moduleID
        Task { [weak self] in
            do {
                let id = try await service.createProject(project)
                let query = id == project.id ? project.query : project.query.replacing("@\(project.id) ", with: "@\(id) ")
                self?.palette().open(moduleID, searching: query)
            } catch {
                Beep.play()
                Log.logger("knowledge").error("Creating the project failed: \(error, privacy: .public)")
            }
        }
    }

    private func deliver(_ text: String, copyOnly: Bool) {
        palette().closeAndDeliver(
            .text(text), copyOnly ? .copyOnly : .paste(.plainText), recording: .skip, restoringPasteboard: false, after: nil)
    }

    private func save(_ capture: KnowledgeCapture) {
        palette().close()
        let service = service
        Task {
            do {
                try await service.capture(capture)
            } catch {
                Beep.play()
                Log.logger("knowledge").error("Saving the note failed: \(error, privacy: .public)")
            }
        }
    }

    /// Asks before saving text that looks like a secret as a plain file.
    func sensitiveOverlay(for capture: KnowledgeCapture) -> PaletteOverlay {
        PaletteOverlay(
            body: AnyView(KnowledgeConfirmView(
                symbol: "exclamationmark.lock", title: "Save “\(capture.title)” anyway?",
                message: "It looks like a password or key. Notes are plain files: they are kept in the git history, synced and readable by any app.")),
            activationHints: [PaletteHint(.primary, "Save anyway")],
            activate: { [unowned self] _ in save(capture) },
            escape: .dismiss)
    }

    /// Asks before moving an item to the Trash.
    func deleteOverlay(for item: KnowledgeItem) -> PaletteOverlay {
        let moduleID = moduleID
        let query = query
        return PaletteOverlay(
            body: AnyView(KnowledgeConfirmView(
                symbol: "trash", title: "Delete “\(item.title)”?",
                message: "\(item.path) goes to the Trash\(service.settings.keepHistory ? " and stays in the folder’s history" : "").")),
            activationHints: [PaletteHint(.primary, "Delete")],
            activate: { [unowned self] _ in
                let service = service
                Task { [weak self] in
                    do {
                        try await service.delete(item.path)
                    } catch {
                        Beep.play()
                    }
                    self?.palette().open(moduleID, searching: query)
                }
            },
            escape: .dismiss)
    }
}
