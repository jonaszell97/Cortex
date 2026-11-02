import CortexCore
import Foundation

/// A tool as `tools/list` describes it.
struct ToolDefinition: Sendable {
    var name: String
    var title: String
    var description: String
    var properties: [String: JSONValue] = [:]
    var required: [String] = []
    var readOnly = false
    var destructive = false

    var definition: JSONValue {
        [
            "name": .string(name),
            "title": .string(title),
            "description": .string(description),
            "inputSchema": [
                "type": "object",
                "properties": .object(properties),
                "required": .array(required.map(JSONValue.string)),
                "additionalProperties": false,
            ],
            "annotations": [
                "title": .string(title),
                "readOnlyHint": .bool(readOnly),
                "destructiveHint": .bool(destructive),
                "idempotentHint": .bool(readOnly),
                "openWorldHint": false,
            ],
        ]
    }
}

/// A tool call's arguments, checked as they are read.
struct Arguments: Sendable {
    let values: [String: JSONValue]

    init(_ values: [String: JSONValue]) {
        self.values = values
    }

    func string(_ key: String) throws -> String? {
        switch values[key] {
        case nil, .null?: return nil
        case .string(let text)?: return text
        default: throw ToolError("“\(key)” must be a string.")
        }
    }

    func required(_ key: String) throws -> String {
        guard let text = try string(key), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ToolError("“\(key)” is required.")
        }
        return text
    }

    /// A list of strings; a single string is a list of one.
    func strings(_ key: String) throws -> [String]? {
        switch values[key] {
        case nil, .null?: return nil
        case .string(let text)?: return [text]
        case .array(let items)?:
            return try items.map { item in
                guard let text = item.stringValue else { throw ToolError("“\(key)” must be a list of strings.") }
                return text
            }
        default: throw ToolError("“\(key)” must be a list of strings.")
        }
    }

    func int(_ key: String) throws -> Int? {
        switch values[key] {
        case nil, .null?: return nil
        case .int(let value)?: return value
        case .double(let value)? where value.rounded() == value: return Int(value)
        default: throw ToolError("“\(key)” must be a whole number.")
        }
    }

    func bool(_ key: String) throws -> Bool {
        switch values[key] {
        case nil, .null?: return false
        case .bool(let value)?: return value
        default: throw ToolError("“\(key)” must be true or false.")
        }
    }

    /// `[{text, done}]`, or plain strings for open items.
    func checklist(_ key: String) throws -> [(text: String, isDone: Bool)]? {
        switch values[key] {
        case nil, .null?: return nil
        case .array(let items)?:
            return try items.map { item in
                if let text = item.stringValue { return (text, false) }
                guard let text = item["text"]?.stringValue else {
                    throw ToolError("“\(key)” must be a list of {text, done} objects.")
                }
                if case .bool(let done)? = item["done"] { return (text, done) }
                return (text, false)
            }
        default: throw ToolError("“\(key)” must be a list of {text, done} objects.")
        }
    }
}

extension MCPServer {
    // MARK: - The table

    private static func text(_ description: String) -> JSONValue {
        ["type": "string", "description": .string(description)]
    }

    private static func list(_ description: String) -> JSONValue {
        ["type": "array", "items": ["type": "string"], "description": .string(description)]
    }

    private static func choice(_ values: [String], _ description: String) -> JSONValue {
        ["type": "string", "enum": .array(values.map(JSONValue.string)), "description": .string(description)]
    }

    private static let projectArgument = text(
        "Project ID (its folder name) or a unique prefix of it. Omitted or \"current\": the project linked to the working directory, else the inbox.")
    private static let pathArgument = text("The item's path relative to the knowledge folder, as returned by search (a cortex:// URI works too).")
    private static let tagsArgument = list("Tags, lowercase, hyphens for spaces. Prefer tags already in use.")
    private static let confirmArgument: JSONValue = [
        "type": "boolean",
        "description": "Set only after the user confirmed saving text that looks like a password or key.",
    ]
    private static let checklistArgument: JSONValue = [
        "type": "array",
        "description": "The whole checklist, replacing the current one (the Markdown task list in the body). An empty list removes it.",
        "items": [
            "type": "object",
            "properties": ["text": ["type": "string"], "done": ["type": "boolean"]],
            "required": ["text"],
        ],
    ]

    static let tools: [ToolDefinition] = [
        ToolDefinition(
            name: "list_projects", title: "List projects",
            description: "Lists the projects: ID, name, summary, linked folders, item and open to-do counts, and which is current.",
            readOnly: true),
        ToolDefinition(
            name: "search", title: "Search the knowledge base",
            description: "Full-text search over notes, skills, to-dos and projects, best match first. Words match as prefixes. `@project` and `#tag` in the query narrow it too. Without a query: the most recently updated items.",
            properties: [
                "query": text("Words to search for."),
                "project": text("Only this project (ID or unique prefix, or \"current\")."),
                "kind": choice(["note", "skill", "todo", "project"], "Only this kind."),
                "tags": list("Only items with all of these tags (each a prefix)."),
                "status": choice(["open", "done"], "To-dos only: only open or only done ones."),
                "limit": ["type": "integer", "description": "At most this many results (default 20, at most 100)."],
            ],
            readOnly: true),
        ToolDefinition(
            name: "read", title: "Read an item",
            description: "Reads an item: its front matter, body, a to-do's checklist, a skill's other files. Also reads a skill's other files and other text files in the folder by path.",
            properties: ["path": pathArgument], required: ["path"], readOnly: true),
        ToolDefinition(
            name: "create_note", title: "Create a note",
            description: "Writes a new note (Markdown body) and returns its path. The title goes into the front matter; do not repeat it as a heading.",
            properties: [
                "project": projectArgument, "title": text("A short, specific title."), "body": text("The note, in Markdown."),
                "tags": tagsArgument, "confirm_sensitive": confirmArgument,
            ],
            required: ["title"]),
        ToolDefinition(
            name: "update_note", title: "Update an item",
            description: "Changes a note (or any item): title (renames the file), body (replaces it), tags (replace them), project (moves the file), a skill's description or a project's summary. Omitted fields stay as they are.",
            properties: [
                "path": pathArgument, "title": text("The new title."), "body": text("The new body, replacing the old one."),
                "tags": tagsArgument, "project": text("Move a note or to-do to this project."),
                "description": text("A skill's description or a project's summary."), "confirm_sensitive": confirmArgument,
            ],
            required: ["path"]),
        ToolDefinition(
            name: "append_note", title: "Append to an item",
            description: "Adds Markdown text at the end of an item's body, after a blank line.",
            properties: ["path": pathArgument, "text": text("The text to add."), "confirm_sensitive": confirmArgument],
            required: ["path", "text"]),
        ToolDefinition(
            name: "create_skill", title: "Create a skill",
            description: "Writes a skill: `skills/<name>/SKILL.md` in Claude Code's layout, instructions for doing a task. It becomes an MCP prompt and, with Cortex running, a Claude Code skill.",
            properties: [
                "project": projectArgument, "name": text("Lowercase with hyphens, e.g. deploy-with-ansible."),
                "description": text("What it does and when to use it, one sentence."), "body": text("The instructions, in Markdown."),
                "tags": tagsArgument, "confirm_sensitive": confirmArgument,
            ],
            required: ["name", "description", "body"]),
        ToolDefinition(
            name: "list_todos", title: "List to-dos",
            description: "Lists to-dos: open ones due first (soonest first), then by project with the inbox first, newest first; done ones last done first.",
            properties: [
                "project": text("Only this project (ID or unique prefix, or \"current\")."),
                "status": choice(["open", "done", "all"], "Default open."), "tags": list("Only to-dos with all of these tags."),
                "query": text("Only to-dos matching these words."),
                "limit": ["type": "integer", "description": "At most this many (default 100)."],
            ],
            readOnly: true),
        ToolDefinition(
            name: "create_todo", title: "Create a to-do",
            description: "Adds an open to-do and returns its path.",
            properties: [
                "project": projectArgument, "title": text("What to do, as an imperative."), "body": text("Details, in Markdown."),
                "tags": tagsArgument, "due": text("Due day, YYYY-MM-DD."), "checklist": list("Sub-steps, as open checklist items."),
                "confirm_sensitive": confirmArgument,
            ],
            required: ["title"]),
        ToolDefinition(
            name: "update_todo", title: "Update a to-do",
            description: "Changes a to-do: title (renames the file), body, tags, due (empty removes it), status, project (moves the file), checklist (replaces it). Omitted fields stay as they are.",
            properties: [
                "path": pathArgument, "title": text("The new title."), "body": text("The new body; a checklist given separately replaces the one in it."),
                "tags": tagsArgument, "due": text("YYYY-MM-DD, or empty to remove it."),
                "status": choice(["open", "done"], "Close or reopen it."), "project": text("Move it to this project."),
                "checklist": checklistArgument, "confirm_sensitive": confirmArgument,
            ],
            required: ["path"]),
        ToolDefinition(
            name: "complete_todo", title: "Complete a to-do",
            description: "Marks a to-do done.",
            properties: ["path": pathArgument], required: ["path"]),
        ToolDefinition(
            name: "create_project", title: "Create a project",
            description: "Makes a project: a folder with a README holding its name, summary and linked folders. Ask the user before making one.",
            properties: [
                "id": text("The folder name: lowercase with hyphens."), "name": text("The display name."),
                "summary": text("What the project is about, one line."),
                "folders": list("Working directories that belong to it; writes from an agent running inside one go to this project."),
            ],
            required: ["id", "name"]),
        ToolDefinition(
            name: "list_actions", title: "List actions and commands",
            description: "Lists the user's own quick actions (`>`) and `$` commands: the TOML files of the actions folder with their name, trigger, what they take and what they run or open, the files that do not load and why, and the command names already taken.",
            readOnly: true),
        ToolDefinition(
            name: "create_action", title: "Create an action or command",
            description: """
                Writes a TOML file in the actions folder, which Cortex loads within a second. With `trigger` it is a `$` command, typed as `$gh owner/repo`; with `accepts` a `>` quick action on the clipboard, the selection or files; with both it is both. \
                It runs `command` (/bin/zsh -c in the home folder, Homebrew on the PATH) or opens `url`. Placeholders: {argument} is the typed text (percent-encoded in a URL), {input} the file (or a file holding the text or image), {inputs} all files, {output} where to write the result; in a command bare or in double quotes, never single quotes. \
                Call list_actions first, and set `confirm` for a command that changes or deletes something. Never overwrites a file.
                """,
            properties: [
                "name": text("The title in the palette, e.g. “GitHub Repository”."),
                "trigger": text("Makes it a $ command: one word typed after $, e.g. gh for $gh owner/repo. Not a name list_actions shows as taken."),
                "accepts": [
                    "type": "array", "items": ["type": "string", "enum": ["text", "image", "files", "none"]],
                    "description": "Makes it a > action on what the palette finds: text, image, files, or none (runs on nothing).",
                ],
                "argument": choice(["required", "optional", "none"], "A command without accepts: whether it takes typed text. Default required when {argument} is used, else none."),
                "url": text("Opened with the default app, e.g. https://github.com/{argument}. Either url or command."),
                "command": text("A shell command, e.g. ffmpeg -i {input} -vf scale=-2:720 {output}. Either url or command."),
                "extensions": list("Files only: only these extensions, e.g. [\"mov\", \"mp4\"]."),
                "output": choice(["files", "text", "none"], "A command's result: the {output} files, standard output pasted, or a notification. Default: files when {output} is used, text for text input, else a notification."),
                "output_extension": text("{output}'s extension; default the input's."),
                "output_suffix": text("Added to the input's name for {output}, e.g. -720p."),
                "example": text("With a trigger: an example argument, shown as $gh owner/repo."),
                "confirm": ["type": "boolean", "description": "Ask before running."],
                "matches": text("A regular expression: $ suggests clips that match it, and > offers a command with accepts on clipboard text that matches."),
                "symbol": text("An SF Symbol name, e.g. film."),
                "keywords": list("More search words."),
                "file": text("The file name without .toml; default the trigger, else the name in hyphens. A number is added when it is taken."),
                "confirm_sensitive": confirmArgument,
            ],
            required: ["name"]),
        ToolDefinition(
            name: "delete", title: "Delete an item",
            description: "Moves an item to the Trash (a skill with its folder), e.g. an inbox note after merging it into another. The folder's git history keeps it too.",
            properties: ["path": pathArgument], required: ["path"], destructive: true),
    ]

    // MARK: - Calls

    func callTool(_ name: String, arguments: Arguments) async -> JSONValue {
        do {
            let result = try await runTool(name, arguments)
            return ["content": [["type": "text", "text": .string(result.pretty)]], "structuredContent": result]
        } catch let error as ToolError {
            return ["content": [["type": "text", "text": .string(error.message)]], "isError": true]
        } catch {
            return ["content": [["type": "text", "text": .string(error.localizedDescription)]], "isError": true]
        }
    }

    private func runTool(_ name: String, _ arguments: Arguments) async throws -> JSONValue {
        switch name {
        case "list_projects": return try listProjects()
        case "search": return try search(arguments)
        case "read": return try read(path(arguments))
        case "create_note": return try await createNote(arguments)
        case "update_note": return try await update(arguments, todo: false)
        case "append_note": return try await appendNote(arguments)
        case "create_skill": return try await createSkill(arguments)
        case "list_todos": return try listTodos(arguments)
        case "create_todo": return try await createTodo(arguments)
        case "update_todo": return try await update(arguments, todo: true)
        case "complete_todo": return try await completeTodo(arguments)
        case "create_project": return try await createProject(arguments)
        case "list_actions": return listActions()
        case "create_action": return try createAction(arguments)
        case "delete": return try await delete(arguments)
        default: throw ToolError("No tool named “\(name)”.")
        }
    }

    private func listProjects() throws -> JSONValue {
        let index = library.index
        let counts = try index.counts()
        let open = try index.openTodoCounts()
        let current = try currentProject()
        let projects = try index.projects().map { project in
            JSONValue.compact([
                "id": .string(project.id), "name": .string(project.name), "summary": project.summary.map(JSONValue.string),
                "folders": project.folders.isEmpty ? nil : .array(project.folders.map(JSONValue.string)),
                "items": .int(counts[project.id] ?? 0), "open_todos": .int(open[project.id] ?? 0),
                "current": project.id == current ? true : nil,
            ])
        }
        return ["projects": .array(projects), "current": .string(current)]
    }

    private func search(_ arguments: Arguments) throws -> JSONValue {
        var query = KnowledgeQuery.parse(try arguments.string("query") ?? "")
        if let project = try arguments.string("project") {
            query.project = nil
            query.projectID = try resolveProject(project)
        } else if let prefix = query.project {
            // `@x` in the query: the one project it names, else every match.
            if let id = try? resolveProject(prefix) {
                query.project = nil
                query.projectID = id
            }
        }
        if let kind = try arguments.string("kind") {
            guard let kind = KnowledgeKind(rawValue: kind) else { throw ToolError("“kind” must be note, skill, todo or project.") }
            query.kinds = [kind]
        }
        query.tags += (try arguments.strings("tags") ?? []).map(KnowledgeTag.normalize).filter { !$0.isEmpty }
        if let status = try arguments.string("status") {
            guard let status = TodoStatus(rawValue: status) else { throw ToolError("“status” must be open or done.") }
            query.status = status
        }
        let limit = min(max(try arguments.int("limit") ?? 20, 1), 100)
        let hits = try library.index.search(query, limit: limit)
        return ["results": .array(hits.map { summary($0.item, snippet: $0.snippet) })]
    }

    func read(_ path: String) throws -> JSONValue {
        guard KnowledgePath.classify(path) != nil else { return try readFile(path) }
        guard folder.exists(path), let item = try folder.item(at: path) else { throw ToolError("No item at \(path).") }
        let checklist = TodoChecklist(body: item.body)
        let files = folder.skillFiles(of: path)
        let frontMatter = Dictionary(item.frontMatter.entries.map { entry -> (String, JSONValue) in
            switch entry.value {
            case .text(let text): (entry.key, .string(text))
            case .list(let items): (entry.key, .array(items.map(JSONValue.string)))
            case .null: (entry.key, .null)
            case .raw(let raw): (entry.key, .string(raw))
            }
        }, uniquingKeysWith: { _, last in last })
        return .compact([
            "path": .string(path), "uri": .string(Self.uri(for: path)), "project": .string(item.project),
            "kind": .string(item.kind.rawValue), "title": .string(item.title),
            "tags": .array(item.tags.map(JSONValue.string)), "summary": item.summary.map(JSONValue.string),
            "status": item.status.map { .string($0.rawValue) }, "due": item.due.map(JSONValue.string),
            "created": item.created.map { .string(FrontMatter.format($0)) }, "updated": .string(FrontMatter.format(item.updated)),
            "front_matter": .object(frontMatter), "body": .string(item.body),
            "checklist": checklist.isEmpty ? nil : .array(checklist.items.map { ["text": .string($0.text), "done": .bool($0.isDone)] }),
            "files": files.isEmpty ? nil : .array(files.map(JSONValue.string)),
        ])
    }

    /// A file that is not an item: a skill's other files, a README of a
    /// subfolder, anything else outside dot folders that is text.
    private func readFile(_ path: String) throws -> JSONValue {
        guard Self.isSafe(path), folder.exists(path) else { throw ToolError("No item at \(path).") }
        let data = try Data(contentsOf: folder.url(for: path))
        guard let text = String(data: data, encoding: .utf8) else {
            throw ToolError("\(path) is not a text file (\(data.count) bytes).")
        }
        return ["path": .string(path), "text": .string(text)]
    }

    private func createNote(_ arguments: Arguments) async throws -> JSONValue {
        let title = try arguments.required("title")
        let body = try arguments.string("body") ?? ""
        try checkSensitive([title, body], arguments)
        let project = try resolveProject(try arguments.string("project"))
        let path = try folder.createNote(
            title: title, body: body, project: project, tags: try arguments.strings("tags") ?? [], now: now())
        return written(path)
    }

    private func appendNote(_ arguments: Arguments) async throws -> JSONValue {
        let path = try existingItem(arguments)
        let text = try arguments.required("text")
        try checkSensitive([text], arguments)
        try folder.append(text, to: path, now: now())
        return written(path)
    }

    private func createSkill(_ arguments: Arguments) async throws -> JSONValue {
        let name = try arguments.required("name")
        let description = try arguments.required("description")
        let body = try arguments.required("body")
        try checkSensitive([description, body], arguments)
        let project = try resolveProject(try arguments.string("project"))
        let path = try folder.createSkill(
            name: name, description: description, body: body, project: project, tags: try arguments.strings("tags") ?? [], now: now())
        return written(path)
    }

    private func listTodos(_ arguments: Arguments) throws -> JSONValue {
        var query = KnowledgeQuery(text: try arguments.string("query") ?? "", kinds: [.todo])
        if let project = try arguments.string("project") { query.projectID = try resolveProject(project) }
        query.tags = (try arguments.strings("tags") ?? []).map(KnowledgeTag.normalize).filter { !$0.isEmpty }
        let status = try arguments.string("status") ?? "open"
        guard ["open", "done", "all"].contains(status) else { throw ToolError("“status” must be open, done or all.") }
        let limit = max(try arguments.int("limit") ?? 100, 1)
        let index = library.index
        let projects = try index.projects().map(\.id)
        var todos: [KnowledgeItem] = []
        if status != "done" {
            query.status = .open
            todos += TodoList.ordered(try index.search(query, limit: 10_000).map(\.item), projects: projects)
        }
        if status != "open" {
            query.status = .done
            todos += TodoList.orderedDone(try index.search(query, limit: 10_000).map(\.item))
        }
        return ["todos": .array(todos.prefix(limit).map { summary($0, snippet: nil) }), "count": .int(todos.count)]
    }

    private func createTodo(_ arguments: Arguments) async throws -> JSONValue {
        let title = try arguments.required("title")
        var body = try arguments.string("body") ?? ""
        let checklist = try arguments.strings("checklist") ?? []
        try checkSensitive([title, body] + checklist, arguments)
        let due = try day(arguments.string("due"))
        let project = try resolveProject(try arguments.string("project"))
        if !checklist.isEmpty { body = TodoChecklist.replacing(with: checklist.map { ($0, false) }, in: body) }
        let path = try folder.createTodo(
            title: title, body: body, project: project, tags: try arguments.strings("tags") ?? [], due: due, now: now())
        return written(path)
    }

    /// `update_note` and `update_todo`: through `KnowledgeEdit`, like the
    /// note editor, so renames and moves work the same way.
    private func update(_ arguments: Arguments, todo: Bool) async throws -> JSONValue {
        let path = try existingItem(arguments)
        let text = try folder.text(at: path)
        guard let item = KnowledgeItem.parse(path: path, text: text, modified: now()) else { throw ToolError("No item at \(path).") }
        if todo, item.kind != .todo { throw ToolError("\(path) is a \(item.kind.rawValue), not a to-do; use update_note.") }
        var edit = KnowledgeEdit(item, text: text)
        if let title = try arguments.string("title") {
            guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ToolError("“title” cannot be empty.") }
            edit.title = title
        }
        if let body = try arguments.string("body") { edit.body = body }
        if let tags = try arguments.strings("tags") { edit.tags = tags }
        if let project = try arguments.string("project") {
            guard item.kind == .note || item.kind == .todo else {
                throw ToolError("Only notes and to-dos move between projects; a \(item.kind.rawValue) stays where it is.")
            }
            edit.project = try resolveProject(project)
        }
        if !todo, let description = try arguments.string("description") {
            guard item.kind == .skill || item.kind == .project else {
                throw ToolError("Only skills have a description and projects a summary.")
            }
            edit.summary = description
        }
        var checklistTexts: [String] = []
        if todo {
            if let due = try arguments.string("due") { edit.due = try day(due) ?? "" }
            if let status = try arguments.string("status") {
                guard let status = TodoStatus(rawValue: status) else { throw ToolError("“status” must be open or done.") }
                edit.status = status
            }
            if let checklist = try arguments.checklist("checklist") {
                edit.body = TodoChecklist.replacing(with: checklist, in: edit.body)
                checklistTexts = checklist.map(\.text)
            }
        }
        try checkSensitive([edit.title, edit.body, edit.summary] + checklistTexts, arguments, changedFrom: text)
        do {
            let saved = try folder.save(edit, at: path, now: now())
            return written(saved, movedFrom: saved == path ? nil : path)
        } catch is KnowledgeEditConflict {
            throw ToolError("\(path) changed while it was being saved; read it again and retry.")
        }
    }

    private func completeTodo(_ arguments: Arguments) async throws -> JSONValue {
        let path = try existingItem(arguments)
        guard KnowledgePath.classify(path)?.kind == .todo else { throw ToolError("\(path) is not a to-do.") }
        try folder.setStatus(.done, of: path, now: now())
        return written(path)
    }

    private func createProject(_ arguments: Arguments) async throws -> JSONValue {
        let raw = try arguments.required("id")
        let id = KnowledgeSlug.make(raw)
        guard !folder.projectIDs().contains(id),
              !FileManager.default.fileExists(atPath: folder.root.appending(path: id).path(percentEncoded: false))
        else { throw ToolError("A project “\(id)” already exists.") }
        let name = try arguments.string("name").flatMap { $0.isEmpty ? nil : $0 } ?? KnowledgeProject.defaultName(for: id)
        let path = try folder.createProject(
            id: id, name: name, summary: try arguments.string("summary"), folders: try arguments.strings("folders") ?? [])
        return ["id": .string(id), "path": .string(path), "uri": .string(Self.uri(for: path))]
    }

    private func delete(_ arguments: Arguments) async throws -> JSONValue {
        let path = try existingItem(arguments)
        guard KnowledgePath.classify(path)?.kind != .project else {
            throw ToolError("Projects are not deleted through MCP; the user can remove the folder.")
        }
        try folder.delete(path)
        return ["deleted": .string(path)]
    }

    // MARK: - Helpers

    /// The `path` argument without `cortex://` or a leading slash.
    private func path(_ arguments: Arguments) throws -> String {
        var path = try arguments.required("path").trimmingCharacters(in: .whitespacesAndNewlines)
        if path.hasPrefix(Self.uriPrefix) { path = Self.path(fromURI: path) ?? path }
        while path.hasPrefix("/") { path.removeFirst() }
        return path
    }

    private func existingItem(_ arguments: Arguments) throws -> String {
        let path = try path(arguments)
        guard KnowledgePath.classify(path) != nil, folder.exists(path) else {
            throw ToolError("No item at \(path). Paths are relative to the knowledge folder, as search returns them.")
        }
        return path
    }

    /// A project argument: nil or "current" is the current project; else an
    /// ID, or a prefix that names exactly one project.
    func resolveProject(_ argument: String?) throws -> String {
        let argument = argument?.trimmingCharacters(in: .whitespaces).lowercased().replacing("@", with: "") ?? ""
        if argument.isEmpty || argument == "current" { return try currentProject() }
        let projects = try library.index.projects()
        if projects.contains(where: { $0.id == argument }) { return argument }
        let matches = projects.filter { $0.matches(prefix: argument) }
        if matches.count == 1 { return matches[0].id }
        if matches.isEmpty {
            throw ToolError("No project “\(argument)”. The projects are: \(projects.map(\.id).joined(separator: ", ")). Ask the user before creating one with create_project.")
        }
        throw ToolError("“\(argument)” matches several projects: \(matches.map(\.id).joined(separator: ", ")).")
    }

    /// A due day as written, checked.
    private func day(_ text: String?) throws -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        guard text.wholeMatch(of: /\d{4}-\d{2}-\d{2}/) != nil, FrontMatter.parseDate(text) != nil else {
            throw ToolError("“due” must be a day as YYYY-MM-DD.")
        }
        return text
    }

    /// Text that looks like a password or key is not written unless the
    /// user confirmed it. Text that was already in the file does not ask
    /// again.
    func checkSensitive(_ texts: [String?], _ arguments: Arguments, changedFrom original: String? = nil) throws {
        guard try !arguments.bool("confirm_sensitive") else { return }
        let sensitive = texts.compactMap { $0 }.contains { text in
            SensitiveTextDetector.looksSensitive(text) && original?.contains(text) != true
        }
        guard !sensitive else {
            throw ToolError("This text looks like a password or key. Knowledge files are plain text: kept in a git history, synced and readable by any app. Nothing was written. Ask the user; if they want it saved anyway, call again with confirm_sensitive: true.")
        }
    }

    private func written(_ path: String, movedFrom: String? = nil) -> JSONValue {
        .compact(["path": .string(path), "uri": .string(Self.uri(for: path)), "moved_from": movedFrom.map(JSONValue.string)])
    }

    /// An item as search and list_todos return it.
    func summary(_ item: KnowledgeItem, snippet: String?) -> JSONValue {
        let checklist = item.kind == .todo ? TodoChecklist(body: item.body) : nil
        return .compact([
            "path": .string(item.path), "project": .string(item.project), "kind": .string(item.kind.rawValue),
            "title": .string(item.title), "tags": item.tags.isEmpty ? nil : .array(item.tags.map(JSONValue.string)),
            "summary": item.summary.map(JSONValue.string), "status": item.status.map { .string($0.rawValue) },
            "due": item.due.map(JSONValue.string),
            "checklist": checklist.flatMap { $0.isEmpty ? nil : .string("\($0.doneCount)/\($0.items.count)") },
            "updated": .string(FrontMatter.format(item.updated)),
            "snippet": snippet.flatMap { $0.isEmpty ? nil : .string($0) },
        ])
    }

    /// A relative path with no hidden or parent components.
    static func isSafe(_ path: String) -> Bool {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return !components.isEmpty && !components.contains { $0.isEmpty || $0.hasPrefix(".") }
    }
}
