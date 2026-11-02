import AppKit
import CortexCore

/// What `?` saves when nothing matched: a note titled with what was typed,
/// its body the clipboard's text or nothing.
struct KnowledgeCapture: Equatable {
    var title: String
    var body: String
    /// The `@project` of the query when it names exactly one, else the inbox.
    var project: String
    var tags: [String]
    var fromClipboard: Bool
    /// The text looks like a password or key: saving asks first.
    var isSensitive: Bool
}

/// What `!` adds: a to-do titled with what was typed, in the `@project`
/// the query names (exactly one), else the inbox.
struct TodoDraft: Equatable {
    var title: String
    var project: String
    var tags: [String]
    /// The text looks like a password or key: adding asks first.
    var isSensitive: Bool
}

/// What `?@name` offers when `@name` names no project: a new project
/// folder with a README.
struct NewProject: Equatable {
    /// The README's `name`: what was typed, or made from the folder name
    /// when it was typed in lowercase ("server-config" is "Server config").
    var name: String
    /// The folder name.
    var id: String
    /// What the field shows once it exists: the query with `@id`.
    var query: String
}

/// Owns the knowledge folder while the module is on: indexes it at start,
/// watches it for changes from editors, agents and other Macs (Sync writes
/// their files into it), writes the
/// palette's captures, keeps its git history and links its skills into
/// Claude Code's skills folder.
@MainActor
@Observable
final class KnowledgeService {
    let folder: KnowledgeFolder
    let settings: KnowledgeSettings
    /// Bumped after every refresh that changed something.
    private(set) var revision = 0
    private(set) var projects: [KnowledgeProject] = [KnowledgeProject(id: KnowledgeProject.inboxID)]
    /// Items per project.
    private(set) var counts: [String: Int] = [:]
    private(set) var isRunning = false
    /// nil until checked at start.
    private(set) var isGitAvailable: Bool?
    /// The last commit's failure, shown in Settings.
    private(set) var historyProblem: String?
    /// What the last update of the skills links found; nil while off.
    private(set) var skillLinksReport: KnowledgeSkillLinks.Report?
    /// The last update's failure, shown in Settings.
    private(set) var skillLinksProblem: String?
    /// Called after a refresh changed something (the open palette reloads).
    @ObservationIgnored var onChange: (() -> Void)?
    /// Opens a file in an editor. VS Code by default.
    @ObservationIgnored var openFile: @MainActor (URL) -> Void = KnowledgeService.openInEditor

    @ObservationIgnored let library: KnowledgeLibrary
    @ObservationIgnored let skillLinks: KnowledgeSkillLinks
    /// The files' hashes for Sync, kept across its cycles.
    @ObservationIgnored let syncHashes = KnowledgeFileHashes()
    /// The skills the links were last made for.
    @ObservationIgnored private var linkedSkillPaths: [String]?
    @ObservationIgnored private var watcher: DirectoryWatcher?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var needsRefresh = false
    @ObservationIgnored private var commitTask: Task<Void, Never>?
    @ObservationIgnored private let log = Log.logger("knowledge")
    /// How long the history waits after the last change.
    @ObservationIgnored var commitDelay: Duration = .seconds(60)

    /// `skillsFolder`: another than the settings' (tests).
    init(settings: KnowledgeSettings, skillsFolder: URL? = nil) {
        self.settings = settings
        folder = KnowledgeFolder(root: settings.folder)
        // An in-memory database only fails to open when memory is gone.
        library = try! KnowledgeLibrary(folder: folder)
        skillLinks = KnowledgeSkillLinks(knowledge: folder.root, skills: skillsFolder ?? settings.skillsFolder)
    }

    var index: KnowledgeIndex { library.index }

    // MARK: - Lifecycle

    /// Creates the folder, indexes it, watches it and prepares the history.
    func start() async {
        guard !isRunning else { return }
        isRunning = true
        do {
            try folder.prepare()
        } catch {
            log.error("Cannot create \(self.folder.root.path, privacy: .public): \(error, privacy: .public)")
        }
        watcher = DirectoryWatcher(url: folder.root) { [weak self] paths in self?.filesChanged(paths) }
        await refreshNow()
        isGitAvailable = await KnowledgeHistory.isGitAvailable()
        // Changes made while Cortex was not running (an agent, an editor).
        if settings.keepHistory { await commit() }
    }

    /// Stops watching; a pending commit is made right away.
    func stop() {
        guard isRunning else { return }
        isRunning = false
        watcher = nil
        refreshTask?.cancel()
        refreshTask = nil
        if commitTask != nil {
            commitTask?.cancel()
            commitTask = nil
            Task { await commit() }
        }
    }

    /// Whether the folder is watched (for tests).
    var isWatching: Bool { watcher != nil }

    // MARK: - Reading

    private func filesChanged(_ paths: [String]) {
        // git's own writes (and other dot folders) are not changes to the
        // knowledge base; without this, every commit would schedule another.
        guard paths.contains(where: { !isHidden($0) }) else { return }
        refresh()
        scheduleCommit()
    }

    private func isHidden(_ absolutePath: String) -> Bool {
        let roots = [folder.root.path(percentEncoded: false), folder.root.resolvingSymlinksInPath().path(percentEncoded: false)]
            .map { $0.hasSuffix("/") ? $0 : $0 + "/" }
        guard let root = roots.first(where: { absolutePath.hasPrefix($0) }) else { return false }
        return KnowledgePath.isHidden(String(absolutePath.dropFirst(root.count)))
    }

    /// Reads what changed, one refresh at a time; asking during one runs
    /// another afterwards.
    func refresh() {
        guard refreshTask == nil else {
            needsRefresh = true
            return
        }
        refreshTask = Task { [weak self] in
            await self?.runRefreshes()
        }
    }

    /// Refreshes and waits for it (start, tests, after own writes).
    func refreshNow() async {
        if let refreshTask {
            needsRefresh = true
            await refreshTask.value
        } else {
            refresh()
            await refreshTask?.value
        }
    }

    private func runRefreshes() async {
        repeat {
            needsRefresh = false
            do {
                let changes = try await library.refresh()
                let index = index
                projects = try index.projects()
                counts = try index.counts()
                updateSkillLinks()
                if !changes.isEmpty {
                    revision += 1
                    onChange?()
                }
            } catch {
                log.error("Indexing failed: \(error, privacy: .public)")
            }
        } while needsRefresh && !Task.isCancelled
        refreshTask = nil
    }

    /// Where a capture or a new to-do goes: the one project `@prefix`
    /// names, else the inbox.
    func project(matching prefix: String?) -> String {
        let matching = prefix.map { prefix in projects.filter { $0.matches(prefix: prefix) } } ?? []
        return matching.count == 1 ? matching[0].id : KnowledgeProject.inboxID
    }

    func search(_ query: KnowledgeQuery, limit: Int) async -> [KnowledgeHit] {
        let index = index
        do {
            return try await Task.detached { try index.search(query, limit: limit) }.value
        } catch {
            log.error("Search failed: \(error, privacy: .public)")
            return []
        }
    }

    // MARK: - Writing

    /// Writes the note and returns its path.
    @discardableResult
    func capture(_ capture: KnowledgeCapture) async throws -> String {
        let path = try folder.createNote(title: capture.title, body: capture.body, project: capture.project, tags: capture.tags)
        log.info("Captured \(path, privacy: .public)")
        await didWrite()
        return path
    }

    /// Writes the to-do and returns its path.
    @discardableResult
    func addTodo(_ draft: TodoDraft) async throws -> String {
        let path = try folder.createTodo(title: draft.title, project: draft.project, tags: draft.tags)
        log.info("Added \(path, privacy: .public)")
        await didWrite()
        return path
    }

    /// An empty note or to-do in `project`, from the browser's +; returns
    /// its path.
    @discardableResult
    func create(_ kind: KnowledgeKind, title: String, project: String) async throws -> String {
        let path = kind == .todo
            ? try folder.createTodo(title: title, project: project)
            : try folder.createNote(title: title, body: "", project: project)
        log.info("Created \(path, privacy: .public)")
        await didWrite()
        return path
    }

    func setStatus(_ status: TodoStatus, of path: String) async throws {
        try folder.setStatus(status, of: path)
        await didWrite()
    }

    func toggleChecklistItem(_ index: Int, of path: String) async throws {
        try folder.toggleChecklistItem(index, of: path)
        await didWrite()
    }

    /// Saves the editor's changes; returns the path, new if the file moved.
    func save(_ edit: KnowledgeEdit, at path: String) async throws -> String {
        let saved = try folder.save(edit, at: path)
        await didWrite()
        return saved
    }

    /// Moves the item's file to the Trash.
    func delete(_ path: String) async throws {
        try folder.delete(path)
        await didWrite()
    }

    /// Makes the project's folder with a README naming it, in the colour
    /// fewest projects have; returns its ID,
    /// another than `project.id` if that folder appeared meanwhile.
    @discardableResult
    func createProject(_ project: NewProject) async throws -> String {
        let id = folder.newProjectID(for: project.id)
        try folder.createProject(id: id, name: project.name, color: ProjectColor.leastUsed(by: projects))
        log.info("Created project \(id, privacy: .public)")
        await didWrite()
        return id
    }

    /// Writes a project's README from Settings → Projects: a new project's
    /// folder with it, or an existing one's name, summary, symbol, colour and
    /// linked folders.
    func saveProject(_ project: KnowledgeProject) async throws {
        try folder.saveProject(project)
        log.info("Saved project \(project.id, privacy: .public)")
        await didWrite()
    }

    /// Writes what `$note` or `$todo` proposed; returns its path.
    @discardableResult
    func file(_ proposal: KnowledgeFiling.Proposal) async throws -> String {
        let path = try KnowledgeFiling.write(proposal, to: folder)
        log.info("Filed \(path, privacy: .public)")
        await didWrite()
        return path
    }

    /// Applies `$tidy`'s proposals one by one. An item that changed since
    /// it was sent, or that cannot be moved, is left as it is; the result
    /// counts what was applied and what failed.
    func applyTidy(_ proposals: [KnowledgeFiling.TidyProposal]) async -> (applied: Int, failed: Int) {
        var applied = 0
        var failed = 0
        for proposal in proposals {
            do {
                try KnowledgeFiling.apply(proposal, in: folder)
                applied += 1
            } catch {
                failed += 1
                log.error("Tidying \(proposal.item.path, privacy: .public) failed: \(error, privacy: .public)")
            }
        }
        await didWrite()
        return (applied, failed)
    }

    /// Imports a Trello board's JSON export.
    func importTrello(_ board: TrelloBoard) async throws -> TrelloImportReport {
        let folder = folder
        defer { scheduleCommit() }
        let report = try await Task.detached { try TrelloImporter(folder: folder).run(board) }.value
        await refreshNow()
        return report
    }

    /// The index sees the change at once, the history a minute later.
    private func didWrite() async {
        await refreshNow()
        scheduleCommit()
    }

    /// The to-dos `!` lists: open ones due first, then by project; done
    /// ones last done first.
    func todos(_ query: TodoQuery, limit: Int = 500) async -> [KnowledgeItem] {
        let items = await search(query.query, limit: limit).map(\.item)
        return query.showsDone ? TodoList.orderedDone(items) : TodoList.ordered(items, projects: projects.map(\.id))
    }

    func open(_ path: String) {
        openFile(folder.url(for: path))
    }

    func revealFolder() {
        try? folder.prepare()
        NSWorkspace.shared.open(folder.root)
    }

    /// VS Code when it is installed, else whatever opens Markdown.
    static func openInEditor(_ url: URL) {
        if let vscode = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.microsoft.VSCode") {
            NSWorkspace.shared.open([url], withApplicationAt: vscode, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    static var editorName: String {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.microsoft.VSCode") == nil ? "Editor" : "VS Code"
    }

    // MARK: - Skills for Claude Code

    /// Makes the links match the skills, when the setting is on and the
    /// skills changed since the last time.
    private func updateSkillLinks(force: Bool = false) {
        guard settings.linkSkills else { return }
        do {
            let paths = try index.paths(of: .skill)
            guard force || paths != linkedSkillPaths else { return }
            let report = try skillLinks.update(skillPaths: paths)
            linkedSkillPaths = paths
            skillLinksReport = report
            skillLinksProblem = nil
            if !report.added.isEmpty || !report.removed.isEmpty {
                log.info("Skills linked: +\(report.added.count) −\(report.removed.count)")
            }
        } catch {
            skillLinksProblem = error.localizedDescription
            log.error("Linking skills failed: \(error, privacy: .public)")
        }
    }

    /// The setting was switched: on, the links are made; off, every link
    /// into the knowledge folder is removed.
    func skillLinksSettingChanged() {
        if settings.linkSkills {
            updateSkillLinks(force: true)
        } else {
            linkedSkillPaths = nil
            skillLinksReport = nil
            do {
                try skillLinks.removeAll()
                skillLinksProblem = nil
            } catch {
                skillLinksProblem = error.localizedDescription
                log.error("Removing the skills links failed: \(error, privacy: .public)")
            }
        }
    }

    // MARK: - MCP

    /// `cortex-mcp` next to the app's own executable.
    static var mcpExecutable: URL {
        Bundle.main.bundleURL.appending(path: "Contents/MacOS/cortex-mcp", directoryHint: .notDirectory)
    }

    /// The line that adds the server to Claude Code, with `--folder` when
    /// the module uses another folder than the default.
    var mcpCommand: String {
        let executable = Self.shellQuoted(Self.mcpExecutable.path(percentEncoded: false))
        guard settings.folderOverride != nil else { return "claude mcp add --scope user cortex \(executable)" }
        // After `--`, so claude does not read --folder as its own option.
        return "claude mcp add --scope user cortex -- \(executable) --folder " + Self.shellQuoted(folder.root.path(percentEncoded: false))
    }

    static func shellQuoted(_ text: String) -> String {
        guard text.contains(where: { !$0.isLetter && !$0.isNumber && !"/._-~".contains($0) }) else { return text }
        return "'" + text.replacing("'", with: "'\\''") + "'"
    }

    // MARK: - History

    /// The setting was switched: on, the repository is made and the folder
    /// committed; off, nothing more is committed (the history stays).
    func historySettingChanged() {
        if settings.keepHistory {
            Task { await commit() }
        } else {
            commitTask?.cancel()
            commitTask = nil
            historyProblem = nil
        }
    }

    /// Commits `commitDelay` after the last change.
    private func scheduleCommit() {
        guard settings.keepHistory, isGitAvailable != false else { return }
        commitTask?.cancel()
        let delay = commitDelay
        commitTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            self.commitTask = nil
            await self.commit()
        }
    }

    /// Makes the repository if needed and commits everything.
    func commit() async {
        guard settings.keepHistory, isGitAvailable == true else { return }
        let history = KnowledgeHistory(folder: folder.root)
        do {
            try await history.prepare()
            if let message = try await history.commitAll() {
                log.info("Committed: \(message.split(separator: "\n").first ?? "", privacy: .public)")
            }
            historyProblem = nil
        } catch {
            historyProblem = (error as? QuickActionError)?.message ?? error.localizedDescription
            log.error("Commit failed: \(error, privacy: .public)")
        }
    }
}
