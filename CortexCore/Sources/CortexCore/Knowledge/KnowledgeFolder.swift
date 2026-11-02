import Foundation

/// The knowledge folder on disk: one subfolder per project, one Markdown
/// file per note, skill or to-do (docs/modules/KNOWLEDGE.md, "The files"). The
/// files are the source of truth; everything else (the index, the palette) is
/// rebuilt from them.
///
/// Writes are atomic (a temporary file, then a rename), so a watcher never
/// reads half a file.
public struct KnowledgeFolder: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// `$XDG_CONFIG_HOME/cortex/knowledge`, or `~/.config/cortex/knowledge`,
    /// next to the action files.
    public static func defaultDirectory(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        UserActionLibrary.defaultDirectory(environment: environment)
            .deletingLastPathComponent()
            .appending(path: "knowledge", directoryHint: .isDirectory)
    }

    public func url(for path: String) -> URL {
        root.appending(path: path, directoryHint: .notDirectory)
    }

    /// Creates the folder and the inbox if they are missing.
    public func prepare() throws {
        try FileManager.default.createDirectory(
            at: root.appending(path: KnowledgeProject.inboxID, directoryHint: .isDirectory),
            withIntermediateDirectories: true)
    }

    // MARK: - Reading

    /// Every file that is an item, with its modification date. Hidden files
    /// and folders (`.git`, `.conflicts`) are skipped.
    public func itemFiles(fileManager: FileManager = .default) -> [String: Date] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        guard let enumerator = fileManager.enumerator(
            at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { return [:] }
        let rootPath = root.standardizedFileURL.path(percentEncoded: false)
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        var files: [String: Date] = [:]
        for case let url as URL in enumerator {
            let path = url.standardizedFileURL.path(percentEncoded: false)
            guard path.hasPrefix(prefix) else { continue }
            let relative = String(path.dropFirst(prefix.count))
            // Assets are never items; do not walk them.
            if url.lastPathComponent == "assets", relative.split(separator: "/").count == 2 {
                enumerator.skipDescendants()
                continue
            }
            guard KnowledgePath.classify(relative) != nil,
                  let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true
            else { continue }
            files[relative] = values.contentModificationDate ?? .distantPast
        }
        return files
    }

    /// The project folders' names, sorted, the inbox among them even before
    /// its folder exists.
    public func projectIDs(fileManager: FileManager = .default) -> [String] {
        let urls = (try? fileManager.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        var ids = Set(urls.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map(\.lastPathComponent))
        ids.insert(KnowledgeProject.inboxID)
        return ids.sorted()
    }

    public func text(at path: String) throws -> String {
        try String(contentsOf: url(for: path), encoding: .utf8)
    }

    public func item(at path: String) throws -> KnowledgeItem? {
        let url = url(for: path)
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .now
        return KnowledgeItem.parse(path: path, text: try String(contentsOf: url, encoding: .utf8), modified: modified)
    }

    public func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: url(for: path).path(percentEncoded: false))
    }

    /// A file that the item at `itemPath` refers to (an image), relative to
    /// the item or, starting with `/`, to the folder; nil for a web link or
    /// a path that leaves the folder.
    public func linkedFile(_ source: String, relativeTo itemPath: String) -> URL? {
        guard !source.contains("://"), let decoded = source.removingPercentEncoding else { return nil }
        let base = url(for: itemPath).deletingLastPathComponent()
        let url = (decoded.hasPrefix("/") ? root.appending(path: decoded) : base.appending(path: decoded))
            .standardizedFileURL
        let rootPath = root.standardizedFileURL.path(percentEncoded: false)
        let rootPrefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        return url.path(percentEncoded: false).hasPrefix(rootPrefix) ? url : nil
    }

    // MARK: - Writing

    /// Writes the file atomically, creating its folders.
    public func write(_ text: String, to path: String) throws {
        let url = url(for: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url, options: .atomic)
    }

    /// `<project>/notes/<slug>.md`, in the inbox `inbox/notes/<day>-<slug>.md`.
    public static func notePath(project: String, title: String, date: Date, timeZone: TimeZone = .current) -> String {
        itemPath("notes", project: project, title: title, date: date, timeZone: timeZone)
    }

    /// `<project>/todos/<slug>.md`, in the inbox `inbox/todos/<day>-<slug>.md`.
    public static func todoPath(project: String, title: String, date: Date, timeZone: TimeZone = .current) -> String {
        itemPath("todos", project: project, title: title, date: date, timeZone: timeZone)
    }

    private static func itemPath(_ folder: String, project: String, title: String, date: Date, timeZone: TimeZone) -> String {
        "\(project)/\(folder)/\(fileName(project: project, title: title, date: date, timeZone: timeZone)).md"
    }

    /// The slug, with the day before it in the inbox.
    static func fileName(project: String, title: String, date: Date, timeZone: TimeZone = .current) -> String {
        let slug = KnowledgeSlug.make(title)
        return project == KnowledgeProject.inboxID ? "\(FrontMatter.formatDay(date, timeZone: timeZone))-\(slug)" : slug
    }

    /// `path`, or with `-2`, `-3`, … before the extension while that is taken.
    public func unusedPath(_ path: String) -> String {
        guard exists(path) else { return path }
        let name = path.split(separator: "/").last ?? ""
        let ext = name.lastIndex(of: ".").flatMap { $0 == name.startIndex ? nil : String(name[$0...]) } ?? ""
        let stem = String(path.dropLast(ext.count))
        var number = 2
        while exists("\(stem)-\(number)\(ext)") { number += 1 }
        return "\(stem)-\(number)\(ext)"
    }

    /// Writes a new note and returns its path. The title goes into the front
    /// matter, so the body is exactly what was given.
    @discardableResult
    public func createNote(
        title: String, body: String, project: String = KnowledgeProject.inboxID, tags: [String] = [], now: Date = .now
    ) throws -> String {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let path = unusedPath(Self.notePath(project: project, title: title, date: now))
        var meta = FrontMatter()
        meta.set("title", text: title.isEmpty ? "Untitled" : title)
        let tags = tags.map(KnowledgeTag.normalize).filter { !$0.isEmpty }
        if !tags.isEmpty { meta.set("tags", .list(tags)) }
        meta.set("created", date: now)
        meta.set("updated", date: now)
        try write(FrontMatter.compose(meta, body: Self.bodyText(body)), to: path)
        return path
    }

    /// Writes a new open to-do and returns its path. `due` is a day
    /// (`2026-10-30`).
    @discardableResult
    public func createTodo(
        title: String, body: String = "", project: String = KnowledgeProject.inboxID, tags: [String] = [], due: String? = nil,
        now: Date = .now
    ) throws -> String {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let path = unusedPath(Self.todoPath(project: project, title: title, date: now))
        var meta = FrontMatter()
        meta.set("title", text: title.isEmpty ? "Untitled" : title)
        meta.set("status", text: TodoStatus.open.rawValue)
        let tags = tags.map(KnowledgeTag.normalize).filter { !$0.isEmpty }
        if !tags.isEmpty { meta.set("tags", .list(tags)) }
        meta.set("due", text: due.flatMap { $0.isEmpty ? nil : $0 })
        meta.set("created", date: now)
        meta.set("updated", date: now)
        try write(FrontMatter.compose(meta, body: Self.bodyText(body)), to: path)
        return path
    }

    /// Writes a new skill, `<project>/skills/<name>/SKILL.md` in Claude
    /// Code's layout, and returns its path. The name is made a slug
    /// (`deploy-with-ansible`, as Claude Code wants it); a taken one gets
    /// `-2`, `-3`.
    @discardableResult
    public func createSkill(
        name: String, description: String, body: String, project: String = KnowledgeProject.inboxID, tags: [String] = [],
        now: Date = .now
    ) throws -> String {
        let slug = KnowledgeSlug.make(name, maxLength: 64)
        var folderName = slug
        var number = 2
        while FileManager.default.fileExists(atPath: root.appending(path: "\(project)/skills/\(folderName)").path(percentEncoded: false)) {
            folderName = "\(slug)-\(number)"
            number += 1
        }
        let path = "\(project)/skills/\(folderName)/SKILL.md"
        var meta = FrontMatter()
        meta.set("name", text: folderName)
        meta.set("description", text: description.trimmingCharacters(in: .whitespacesAndNewlines))
        let tags = tags.map(KnowledgeTag.normalize).filter { !$0.isEmpty }
        if !tags.isEmpty { meta.set("tags", .list(tags)) }
        meta.set("created", date: now)
        meta.set("updated", date: now)
        try write(FrontMatter.compose(meta, body: Self.bodyText(body)), to: path)
        return path
    }

    /// The files next to a skill's `SKILL.md`, relative to its folder, sorted.
    public func skillFiles(of path: String) -> [String] {
        guard KnowledgePath.classify(path)?.kind == .skill else { return [] }
        let folder = url(for: path).deletingLastPathComponent()
        var prefix = folder.standardizedFileURL.path(percentEncoded: false)
        if !prefix.hasSuffix("/") { prefix += "/" }
        guard let enumerator = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
        else { return [] }
        return enumerator.compactMap { element -> String? in
            guard let url = element as? URL, (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return nil }
            let file = url.standardizedFileURL.path(percentEncoded: false)
            guard file.hasPrefix(prefix) else { return nil }
            let relative = String(file.dropFirst(prefix.count))
            return relative == "SKILL.md" ? nil : relative
        }.sorted()
    }

    // MARK: - Changing items

    /// Adds text at the end of an item's body, after a blank line.
    public func append(_ text: String, to path: String, now: Date = .now) throws {
        try modify(path, now: now) { _, body in
            let existing = body.trimmingCharacters(in: .whitespacesAndNewlines)
            let addition = text.trimmingCharacters(in: .whitespacesAndNewlines)
            body = Self.bodyText(existing.isEmpty ? addition : existing + "\n\n" + addition)
        }
    }

    /// Rewrites an item's file in place:`change` gets its front matter and
    /// body, and `updated` is set to `now`. Every other key stays as written.
    public func modify(_ path: String, now: Date = .now, _ change: (inout FrontMatter, inout String) throws -> Void) throws {
        let (frontMatter, original) = FrontMatter.split(try text(at: path))
        var meta = frontMatter ?? FrontMatter()
        var body = original
        try change(&meta, &body)
        meta.set("updated", date: now)
        try write(FrontMatter.compose(meta, body: body), to: path)
    }

    /// Opens or closes a to-do; `done` is the day and time it was closed.
    public func setStatus(_ status: TodoStatus, of path: String, now: Date = .now) throws {
        try modify(path, now: now) { meta, _ in
            meta.set("status", text: status.rawValue)
            meta.set("done", date: status == .done ? now : nil)
        }
    }

    /// Ticks or unticks the checklist item at `index` (in checklist order).
    public func toggleChecklistItem(_ index: Int, of path: String, now: Date = .now) throws {
        try modify(path, now: now) { _, body in
            body = TodoChecklist.toggling(itemAt: index, in: body)
        }
    }

    /// Saves what the note editor changed and returns the item's path, which
    /// is new when the title or the project of a note or to-do changed (the
    /// file moves). Throws `KnowledgeEditConflict` when the file changed on
    /// disk since `edit.original` was read.
    @discardableResult
    public func save(_ edit: KnowledgeEdit, at path: String, now: Date = .now) throws -> String {
        let current = try text(at: path)
        guard current == edit.original else { throw KnowledgeEditConflict(path: path) }
        guard let (oldProject, kind) = KnowledgePath.classify(path) else { throw KnowledgeEditConflict(path: path) }
        let (frontMatter, _) = FrontMatter.split(current)
        var meta = frontMatter ?? FrontMatter()
        let title = edit.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let titleKey = kind == .skill || kind == .project ? "name" : "title"
        meta.set(titleKey, text: title.isEmpty ? nil : title)
        let tags = edit.tags.map(KnowledgeTag.normalize).filter { !$0.isEmpty }
        var seen: Set<String> = []
        let unique = tags.filter { seen.insert($0).inserted }
        meta.set("tags", unique.isEmpty ? nil : .list(unique))
        if let summaryKey = kind == .skill ? "description" : kind == .project ? "summary" : nil {
            let summary = edit.summary?.trimmingCharacters(in: .whitespacesAndNewlines)
            meta.set(summaryKey, text: summary.flatMap { $0.isEmpty ? nil : $0 })
        }
        if kind == .todo {
            let status = edit.status ?? .open
            if status.rawValue != meta.string("status")?.lowercased() ?? TodoStatus.open.rawValue {
                meta.set("done", date: status == .done ? now : nil)
            }
            meta.set("status", text: status.rawValue)
            meta.set("due", text: edit.due.flatMap { $0.isEmpty ? nil : $0 })
        }
        if meta["created"] == nil, frontMatter == nil { meta.set("created", date: now) }
        meta.set("updated", date: now)

        var target = path
        if kind == .note || kind == .todo {
            let project = edit.project ?? oldProject
            let oldTitle = KnowledgeItem.parse(path: path, text: current, modified: now)?.title
            if project != oldProject {
                let date = meta.date("created") ?? now
                target = unusedPath(kind == .todo
                    ? Self.todoPath(project: project, title: title, date: date) : Self.notePath(project: project, title: title, date: date))
            } else if !title.isEmpty, title != oldTitle {
                // `docker-compose-2.md` already is the file for "Docker Compose".
                let renamed = Self.renamed(path, title: title)
                let stem = String(renamed.dropLast(3)) + "-"
                let isNumbered = path.hasPrefix(stem) && path.dropFirst(stem.count).dropLast(3).allSatisfy(\.isNumber)
                    && path.count > stem.count + 3
                if renamed != path, !isNumbered { target = unusedPath(renamed) }
            }
        }
        try write(FrontMatter.compose(meta, body: Self.bodyText(edit.body)), to: target)
        if target != path {
            try FileManager.default.removeItem(at: url(for: path))
        }
        return target
    }

    /// Writes an edit as a new item next to the one at `path` (in the edit's
    /// project), titled "… (copy)", and returns its path: a to-do for a
    /// to-do, a note for the rest. For the editor's "Copy Mine" after a
    /// conflict: the file at `path` is left as it is, and may be gone.
    @discardableResult
    public func saveCopy(_ edit: KnowledgeEdit, of path: String, now: Date = .now) throws -> String {
        guard let (project, kind) = KnowledgePath.classify(path) else { throw KnowledgeEditConflict(path: path) }
        let title = edit.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let copyTitle = (title.isEmpty ? "Untitled" : title) + " (copy)"
        let target = edit.project ?? project
        guard kind == .todo else {
            return try createNote(title: copyTitle, body: edit.body, project: target, tags: edit.tags, now: now)
        }
        let copy = try createTodo(title: copyTitle, body: edit.body, project: target, tags: edit.tags, due: edit.due, now: now)
        if edit.status == .done { try setStatus(.done, of: copy, now: now) }
        return copy
    }

    /// The path in the same folder with the new title's slug; an inbox
    /// file keeps its day.
    static func renamed(_ path: String, title: String) -> String {
        var components = path.split(separator: "/").map(String.init)
        var name = String(components.removeLast().dropLast(3))
        let day = name.prefixMatch(of: /\d{4}-\d{2}-\d{2}-/).map { String(name[$0.range]) } ?? ""
        name = (components.first == KnowledgeProject.inboxID ? day : "") + KnowledgeSlug.make(title)
        return (components + [name + ".md"]).joined(separator: "/")
    }

    /// A project folder with a README. Returns the README's path.
    @discardableResult
    public func createProject(
        id: String, name: String, summary: String? = nil, symbol: String? = nil, color: ProjectColor? = nil, folders: [String] = []
    ) throws -> String {
        let path = "\(id)/README.md"
        var meta = FrontMatter()
        Self.setProjectKeys(
            &meta, KnowledgeProject(id: id, name: name, summary: summary, symbol: symbol, color: color, folders: folders))
        try write(FrontMatter.compose(meta, body: ""), to: path)
        return path
    }

    /// Writes a project's name, summary, symbol, colour and linked folders
    /// into its README, which is made when it is missing. The README's text
    /// and its other keys stay as written. Returns the README's path.
    @discardableResult
    public func saveProject(_ project: KnowledgeProject, now: Date = .now) throws -> String {
        let path = "\(project.id)/README.md"
        guard exists(path) else {
            return try createProject(
                id: project.id, name: project.name, summary: project.summary, symbol: project.symbol, color: project.color,
                folders: project.folders)
        }
        try modify(path, now: now) { meta, _ in
            meta.set("title", nil)
            Self.setProjectKeys(&meta, project)
        }
        return path
    }

    /// Empty values remove their key.
    private static func setProjectKeys(_ meta: inout FrontMatter, _ project: KnowledgeProject) {
        func nonEmpty(_ text: String?) -> String? {
            text.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
        }
        meta.set("name", text: nonEmpty(project.name) ?? KnowledgeProject.defaultName(for: project.id))
        meta.set("summary", text: nonEmpty(project.summary))
        meta.set("symbol", text: nonEmpty(project.symbol))
        meta.set("color", text: project.color?.rawValue)
        let folders = project.folders.compactMap(nonEmpty)
        meta.set("folders", folders.isEmpty ? nil : .list(folders))
    }

    /// An unused project ID for a name: its slug, then `-2`, `-3`, ….
    public func newProjectID(for name: String) -> String {
        let slug = KnowledgeSlug.make(name)
        var id = slug
        var number = 2
        while FileManager.default.fileExists(atPath: root.appending(path: id).path(percentEncoded: false)) {
            id = "\(slug)-\(number)"
            number += 1
        }
        return id
    }

    /// Moves an item to the Trash (a skill with its folder). The git history
    /// keeps it too.
    public func delete(_ path: String) throws {
        var url = url(for: path)
        if KnowledgePath.classify(path)?.kind == .skill { url = url.deletingLastPathComponent() }
        #if os(macOS)
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            return
        } catch CocoaError.fileNoSuchFile {
            return
        } catch {
            // No Trash on this volume: fall through.
        }
        #endif
        try FileManager.default.removeItem(at: url)
    }

    /// A body as written to a file: no leading blank lines, one newline at the end.
    static func bodyText(_ body: String) -> String {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "" : trimmed + "\n"
    }
}
