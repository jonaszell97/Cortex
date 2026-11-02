import CortexCore
import Foundation

/// Resources: every item as `cortex://<project>/<path>`, so a client can
/// attach a note to a conversation. Prompts: every skill, plus `file-this`
/// and `tidy-inbox`.
extension MCPServer {
    static let uriPrefix = "cortex://"

    static let resourceTemplate: JSONValue = [
        "uriTemplate": "cortex://{+path}",
        "name": "knowledge-file",
        "title": "Knowledge file",
        "description": "A file of the knowledge folder by its path, e.g. cortex://server-config/notes/docker.md",
        "mimeType": "text/markdown",
    ]

    static func uri(for path: String) -> String {
        uriPrefix + (path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path)
    }

    static func path(fromURI uri: String) -> String? {
        guard uri.hasPrefix(uriPrefix) else { return nil }
        return String(uri.dropFirst(uriPrefix.count)).removingPercentEncoding
    }

    // MARK: - Resources

    func listResources() throws -> JSONValue {
        let items = try library.index.search(KnowledgeQuery(), limit: Int.max).map(\.item)
        return ["resources": .array(items.map { item in
            JSONValue.compact([
                "uri": .string(Self.uri(for: item.path)), "name": .string(item.path), "title": .string(item.title),
                "description": .string(item.summary.map { "\(item.kind.rawValue) in \(item.project): \($0)" }
                    ?? "\(item.kind.rawValue) in \(item.project)"),
                "mimeType": "text/markdown",
                "annotations": ["lastModified": .string(FrontMatter.format(item.updated))],
            ])
        })]
    }

    func readResource(_ uri: String) throws -> JSONValue {
        guard let path = Self.path(fromURI: uri), Self.isSafe(path), folder.exists(path) else {
            throw MCPError(code: -32002, message: "Resource not found: \(uri)")
        }
        let data = try Data(contentsOf: folder.url(for: path))
        let content: JSONValue
        if let text = String(data: data, encoding: .utf8) {
            let mimeType = path.lowercased().hasSuffix(".md") ? "text/markdown" : "text/plain"
            content = ["uri": .string(uri), "mimeType": .string(mimeType), "text": .string(text)]
        } else {
            content = ["uri": .string(uri), "mimeType": "application/octet-stream", "blob": .string(data.base64EncodedString())]
        }
        return ["contents": [content]]
    }

    // MARK: - Prompts

    static let fileThis = "file-this"
    static let tidyInbox = "tidy-inbox"

    /// Skills by prompt name (their folder name). Two of the same name: the
    /// first path wins, as for the links in `~/.claude/skills`; the
    /// built-in prompts' names are not available to skills.
    private func skills() throws -> [(name: String, item: KnowledgeItem)] {
        var seen: Set<String> = [Self.fileThis, Self.tidyInbox]
        return try library.index.paths(of: .skill).compactMap { path in
            let name = path.split(separator: "/").dropLast().last.map(String.init) ?? path
            guard seen.insert(name).inserted, let item = try library.index.item(at: path) else { return nil }
            return (name, item)
        }
    }

    func listPrompts() throws -> JSONValue {
        var prompts: [JSONValue] = [
            [
                "name": .string(Self.fileThis), "title": "File this",
                "description": "Files a text into the knowledge base: picks the project, title and tags, and writes a note, skill or to-do (or adds to an existing one).",
                "arguments": [
                    ["name": "text", "description": "What to file.", "required": true],
                ],
            ],
            [
                "name": .string(Self.tidyInbox), "title": "Tidy the inbox",
                "description": "Proposes a project, title and tags (or a merge) for every inbox item and applies what you confirm.",
                "arguments": [],
            ],
        ]
        for (name, item) in try skills() {
            prompts.append(.compact([
                "name": .string(name), "title": .string(item.title == name ? name : item.title),
                "description": item.summary.map(JSONValue.string),
                "arguments": [
                    ["name": "request", "description": "What to do with it (optional).", "required": false],
                ],
            ]))
        }
        return ["prompts": .array(prompts)]
    }

    func prompt(_ name: String, arguments: [String: String]) throws -> JSONValue {
        let index = library.index
        let text: String
        let description: String
        switch name {
        case Self.fileThis:
            guard let input = arguments["text"], !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw MCPError.invalidParams("file-this needs the text to file")
            }
            description = "File a text into the knowledge base"
            text = KnowledgeInstructions.fileThis(
                input, projects: try index.projects(), tags: try index.tags().map(\.tag), current: try currentProject())
        case Self.tidyInbox:
            description = "Tidy the knowledge base's inbox"
            let items = try index.search(KnowledgeQuery(projectID: KnowledgeProject.inboxID, kinds: [.note, .skill, .todo]), limit: 200)
                .map(\.item)
                .filter { $0.status != .done }
            text = KnowledgeInstructions.tidyInbox(
                items.map(KnowledgeInstructions.InboxEntry.init), projects: try index.projects(), tags: try index.tags().map(\.tag))
        default:
            guard let skill = try skills().first(where: { $0.name == name }) else {
                throw MCPError.invalidParams("No prompt named “\(name)”")
            }
            description = skill.item.summary ?? skill.item.title
            text = skillPrompt(skill.item, request: arguments["request"])
        }
        return [
            "description": .string(description),
            "messages": [["role": "user", "content": ["type": "text", "text": .string(text)]]],
        ]
    }

    /// The skill's instructions, with `$ARGUMENTS` (as in Claude Code's
    /// skills) replaced by the request, or the request after them.
    private func skillPrompt(_ item: KnowledgeItem, request: String?) -> String {
        var body = item.body.trimmingCharacters(in: .whitespacesAndNewlines)
        let request = request?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if body.contains("$ARGUMENTS") {
            body = body.replacing("$ARGUMENTS", with: request)
        } else if !request.isEmpty {
            body += "\n\n---\n\n\(request)"
        }
        let files = folder.skillFiles(of: item.path)
        var header = "Follow the skill “\(item.title)” from my Cortex knowledge base (\(item.path))."
        if !files.isEmpty {
            let folderPath = item.path.split(separator: "/").dropLast().joined(separator: "/")
            header += " Its other files can be read with the read tool: " + files.map { "\(folderPath)/\($0)" }.joined(separator: ", ") + "."
        }
        return header + "\n\n" + body
    }
}
