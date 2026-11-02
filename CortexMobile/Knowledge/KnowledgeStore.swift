import SwiftUI
import CortexCore

/// The knowledge folder on the phone and its index. There is no folder
/// watcher: the files change through sync (which refreshes after
/// applying), through the app's own writes, which refresh and then ask for
/// a sync cycle (`onWrite`), and through the share extension, the widgets
/// and intents, which the app picks up when it runs
/// (`refreshOutsideWrites`).
@MainActor
@Observable
final class KnowledgeStore {
    let folder: KnowledgeFolder
    /// Bumped after every refresh that changed something; views reload on it.
    private(set) var revision = 0
    private(set) var projects: [KnowledgeProject] = []
    /// Items per project.
    private(set) var counts: [String: Int] = [:]
    /// Open to-dos per project.
    private(set) var openTodoCounts: [String: Int] = [:]
    private(set) var itemCount = 0

    /// The files' hashes for sync, kept across its cycles.
    @ObservationIgnored let syncHashes = KnowledgeFileHashes()
    /// After every write: knowledge files have no triggers, so the app asks
    /// sync for a cycle, whose scan picks the change up.
    @ObservationIgnored var onWrite: () -> Void = {}
    /// Files changed outside the app (their count), found by
    /// `refreshOutsideWrites`: they need a cycle like the app's own writes.
    @ObservationIgnored var onOutsideWrites: (Int) -> Void = { _ in }
    /// After every refresh that changed something (Spotlight, the widgets).
    @ObservationIgnored var onChange: (KnowledgeLibrary.Changes) -> Void = { _ in }
    @ObservationIgnored private let library: KnowledgeLibrary
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var needsRefresh = false
    /// The first refresh reads every file; only later ones find writes.
    @ObservationIgnored private var hasIndexed = false
    @ObservationIgnored private var countsOutsideWrites = false
    @ObservationIgnored private let log = Log.logger("knowledge")

    init(folder: KnowledgeFolder) {
        self.folder = folder
        // An in-memory database only fails to open when memory is gone.
        library = try! KnowledgeLibrary(folder: folder)
    }

    private var index: KnowledgeIndex { library.index }

    /// Creates the folder (sync scans only a folder that exists) and indexes it.
    func start() async {
        do {
            try folder.prepare()
        } catch {
            log.error("Cannot create the knowledge folder: \(error, privacy: .public)")
        }
        await refreshNow()
    }

    /// Reads what changed, one refresh at a time; asking during one runs
    /// another afterwards.
    func refresh() {
        guard refreshTask == nil else {
            needsRefresh = true
            return
        }
        refreshTask = Task { [weak self] in await self?.runRefreshes() }
    }

    func refreshNow() async {
        if let refreshTask {
            needsRefresh = true
            await refreshTask.value
        } else {
            refresh()
            await refreshTask?.value
        }
    }

    /// A refresh that counts what it finds as writes to sync: the share
    /// extension's, a widget's or an intent's, made while the app was away.
    func refreshOutsideWrites() async {
        countsOutsideWrites = true
        await refreshNow()
    }

    private func runRefreshes() async {
        repeat {
            needsRefresh = false
            let counting = countsOutsideWrites && hasIndexed
            countsOutsideWrites = false
            do {
                let changes = try await library.refresh()
                hasIndexed = true
                let index = index
                projects = try index.projects()
                counts = try index.counts()
                openTodoCounts = try index.openTodoCounts()
                itemCount = counts.values.reduce(0, +)
                if !changes.isEmpty {
                    revision += 1
                    if counting { onOutsideWrites(changes.updated.count + changes.removed.count) }
                    onChange(changes)
                }
            } catch {
                log.error("Indexing failed: \(error, privacy: .public)")
            }
        } while needsRefresh && !Task.isCancelled
        refreshTask = nil
    }

    // MARK: - Reading

    func project(_ id: String) -> KnowledgeProject {
        projects.first { $0.id == id } ?? KnowledgeProject(id: id)
    }

    /// A project's items of the given kinds, most recently updated first.
    func items(in project: String, kinds: Set<KnowledgeKind>) async -> [KnowledgeItem] {
        await search(KnowledgeQuery(projectID: project, kinds: kinds), limit: 5_000).map(\.item)
    }

    /// What is typed in the search field, with `@project` and `#tag` as on
    /// the Mac's `?`.
    func search(_ text: String) async -> [KnowledgeHit] {
        await search(KnowledgeQuery.parse(text), limit: 100)
    }

    private func search(_ query: KnowledgeQuery, limit: Int) async -> [KnowledgeHit] {
        let index = index
        do {
            return try await Task.detached { try index.search(query, limit: limit) }.value
        } catch {
            log.error("Search failed: \(error, privacy: .public)")
            return []
        }
    }

    func item(at path: String) -> KnowledgeItem? {
        try? index.item(at: path)
    }

    /// The indexed items of `kinds` and their files' modification dates,
    /// read off the main actor.
    func modificationDates(of kinds: Set<KnowledgeKind>) async -> [String: Date] {
        let index = index
        let dates = (try? await Task.detached { try index.modificationDates() }.value) ?? [:]
        return dates.filter { KnowledgePath.classify($0.key).map { kinds.contains($0.kind) } ?? false }
    }

    func items(at paths: [String]) async -> [KnowledgeItem] {
        let index = index
        return await Task.detached { paths.compactMap { try? index.item(at: $0) } }.value
    }

    /// Open to-dos ordered as the Mac's `!` lists them, or the done ones
    /// last done first.
    func todos(done: Bool) async -> [KnowledgeItem] {
        let items = await search(KnowledgeQuery(kinds: [.todo], status: done ? .done : .open), limit: 5_000).map(\.item)
        return done ? TodoList.orderedDone(items) : TodoList.ordered(items, projects: projects.map(\.id))
    }

    // MARK: - Writing

    /// Runs a write off the main actor, then indexes it and asks for a sync
    /// cycle.
    private func write<T: Sendable>(_ change: @escaping @Sendable (KnowledgeFolder) throws -> T) async throws -> T {
        let folder = folder
        let result = try await Task.detached { try change(folder) }.value
        await refreshNow()
        onWrite()
        return result
    }

    func createNote(title: String, body: String, project: String, tags: [String]) async throws -> String {
        let path = try await write { try $0.createNote(title: title, body: body, project: project, tags: tags) }
        log.info("Created \(path, privacy: .public)")
        return path
    }

    func createTodo(title: String, body: String, project: String, tags: [String], due: String?) async throws -> String {
        let path = try await write { try $0.createTodo(title: title, body: body, project: project, tags: tags, due: due) }
        log.info("Created \(path, privacy: .public)")
        return path
    }

    func setStatus(_ status: TodoStatus, of path: String) async throws {
        try await write { try $0.setStatus(status, of: path) }
    }

    func toggleChecklistItem(_ index: Int, of path: String) async throws {
        try await write { try $0.toggleChecklistItem(index, of: path) }
    }

    func addChecklistItem(_ text: String, to path: String) async throws {
        try await write { folder in
            try folder.modify(path) { _, body in body = TodoChecklist.adding(text, to: body) }
        }
    }

    /// Saves the editor's fields; returns the path, new if the file moved.
    /// Throws `KnowledgeEditConflict` when the file changed meanwhile.
    func save(_ edit: KnowledgeEdit, at path: String) async throws -> String {
        try await write { try $0.save(edit, at: path) }
    }

    /// "Copy Mine": the edit as a new item next to the one at `path`.
    func saveCopy(_ edit: KnowledgeEdit, of path: String) async throws -> String {
        try await write { try $0.saveCopy(edit, of: path) }
    }

    /// Removes the file (a skill with its folder). The Macs keep it in
    /// `.conflicts/` when the delete reaches them.
    func delete(_ path: String) async throws {
        try await write { try $0.delete(path) }
        log.info("Deleted \(path, privacy: .public)")
    }

    /// A project folder with a README, in the colour fewest projects have
    /// (as on the Mac). Returns its ID.
    func createProject(name: String, summary: String?) async throws -> String {
        let color = ProjectColor.leastUsed(by: projects)
        return try await write { folder in
            let id = folder.newProjectID(for: name)
            try folder.createProject(id: id, name: name, summary: summary, color: color)
            return id
        }
    }

    // MARK: - Conflict copies

    var conflictCopies: KnowledgeConflictCopies { KnowledgeConflictCopies(root: folder.root) }

    /// Puts a kept version back; the current file goes to `.conflicts/`.
    func restore(_ copy: KnowledgeConflictCopies.Copy) async throws {
        let copies = conflictCopies
        try await write { _ in try copies.restore(copy) }
    }

    /// A file in the folder that a note refers to (an image), if it stays
    /// inside the folder.
    func file(_ source: String, relativeTo itemPath: String) -> URL? {
        folder.linkedFile(source, relativeTo: itemPath)
    }
}
