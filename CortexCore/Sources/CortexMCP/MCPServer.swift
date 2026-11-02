import CortexCore
import Foundation

/// The Model Context Protocol server of `cortex-mcp` (docs/modules/KNOWLEDGE.md,
/// "The MCP server"): the knowledge folder's tools, resources and prompts for
/// Claude Code, Claude Desktop, Cursor and anything else that speaks MCP over
/// stdio, and tools to list and write the action files of Quick Actions.
///
/// It works on the files, never on the app: the index is its own, in
/// memory, refreshed before every request, so it sees what the app, an
/// editor or another Mac wrote. Writes are atomic, and the app's folder
/// watcher picks them up within a second. No network, no database, no
/// Keychain.
///
/// One JSON-RPC message per line in, the lines to send back out
/// (`receive`); `StdioTransport` connects it to stdin and stdout.
public actor MCPServer {
    public static let name = "cortex"
    public static let version = "0.1.0"
    /// Newest first; a client asking for another gets the newest.
    static let protocolVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]

    let folder: KnowledgeFolder
    let library: KnowledgeLibrary
    /// The Quick Actions folder, whose TOML files are actions and commands.
    let actionsDirectory: URL
    /// The directory the client started the server in.
    let workingDirectory: String
    let now: @Sendable () -> Date

    /// The client's roots (its open folders), when it shares them.
    private(set) var roots: [String] = []
    private var clientSupportsRoots = false
    private var rootsRequest = 0

    public init(
        folder: KnowledgeFolder, actionsDirectory: URL = UserActionLibrary.defaultDirectory(), workingDirectory: String,
        now: @escaping @Sendable () -> Date = { .now }
    ) throws {
        self.folder = folder
        library = try KnowledgeLibrary(folder: folder)
        self.actionsDirectory = actionsDirectory
        self.workingDirectory = workingDirectory
        self.now = now
    }

    // MARK: - Messages

    /// Handles one line (a message or a batch) and returns the lines to send.
    public func receive(_ line: String) async -> [String] {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let message: JSONValue
        do {
            message = try JSONValue.parse(trimmed)
        } catch {
            return [Self.errorResponse(id: .null, MCPError(code: -32700, message: "Parse error: \(error.localizedDescription)")).line]
        }
        if case .array(let batch) = message {
            var responses: [JSONValue] = []
            var requests: [JSONValue] = []
            for message in batch {
                let (response, outgoing) = await handle(message)
                if let response { responses.append(response) }
                requests += outgoing
            }
            return (responses.isEmpty ? [] : [JSONValue.array(responses).line]) + requests.map(\.line)
        }
        let (response, outgoing) = await handle(message)
        return (response.map { [$0.line] } ?? []) + outgoing.map(\.line)
    }

    /// The response (nil for a notification or a response) and requests of
    /// the server's own to send after it.
    private func handle(_ message: JSONValue) async -> (response: JSONValue?, outgoing: [JSONValue]) {
        guard case .object(let object) = message else {
            return (Self.errorResponse(id: .null, MCPError(code: -32600, message: "Invalid request")), [])
        }
        let id = object["id"]
        guard let method = object["method"]?.stringValue else {
            // A response to one of the server's requests.
            if let id { receiveResponse(id: id, result: object["result"]) }
            return (nil, [])
        }
        let params = object["params"]?.objectValue ?? [:]
        guard let id else {
            return (nil, notification(method, params: params))
        }
        do {
            let result = try await request(method, params: params)
            return (["jsonrpc": "2.0", "id": id, "result": result], [])
        } catch let error as MCPError {
            return (Self.errorResponse(id: id, error), [])
        } catch {
            return (Self.errorResponse(id: id, MCPError(code: -32603, message: error.localizedDescription)), [])
        }
    }

    private func request(_ method: String, params: [String: JSONValue]) async throws -> JSONValue {
        switch method {
        case "initialize": return initialize(params)
        case "ping": return [:]
        case "tools/list": return ["tools": .array(Self.tools.map(\.definition))]
        case "tools/call":
            guard let name = params["name"]?.stringValue else { throw MCPError.invalidParams("tools/call needs a name") }
            guard Self.tools.contains(where: { $0.name == name }) else { throw MCPError.invalidParams("No tool named “\(name)”") }
            try await refresh()
            return await callTool(name, arguments: Arguments(params["arguments"]?.objectValue ?? [:]))
        case "resources/list":
            try await refresh()
            return try listResources()
        case "resources/templates/list":
            return ["resourceTemplates": [Self.resourceTemplate]]
        case "resources/read":
            guard let uri = params["uri"]?.stringValue else { throw MCPError.invalidParams("resources/read needs a uri") }
            return try readResource(uri)
        case "prompts/list":
            try await refresh()
            return try listPrompts()
        case "prompts/get":
            guard let name = params["name"]?.stringValue else { throw MCPError.invalidParams("prompts/get needs a name") }
            try await refresh()
            let arguments = (params["arguments"]?.objectValue ?? [:]).compactMapValues(\.stringValue)
            return try prompt(name, arguments: arguments)
        default:
            throw MCPError(code: -32601, message: "Method not found: \(method)")
        }
    }

    private func notification(_ method: String, params: [String: JSONValue]) -> [JSONValue] {
        switch method {
        case "notifications/initialized", "notifications/roots/list_changed":
            guard clientSupportsRoots else { return [] }
            rootsRequest += 1
            return [["jsonrpc": "2.0", "id": .string("roots-\(rootsRequest)"), "method": "roots/list"]]
        default:
            return []
        }
    }

    private func receiveResponse(id: JSONValue, result: JSONValue?) {
        guard id == .string("roots-\(rootsRequest)"), let list = result?["roots"]?.arrayValue else { return }
        roots = list.compactMap { root in
            guard let uri = root["uri"]?.stringValue, let url = URL(string: uri), url.isFileURL else { return nil }
            return url.path(percentEncoded: false)
        }
    }

    private func initialize(_ params: [String: JSONValue]) -> JSONValue {
        let requested = params["protocolVersion"]?.stringValue ?? ""
        clientSupportsRoots = params["capabilities"]?["roots"] != nil
        return [
            "protocolVersion": .string(Self.protocolVersions.contains(requested) ? requested : Self.protocolVersions[0]),
            "capabilities": [
                "tools": ["listChanged": false],
                "resources": ["listChanged": false, "subscribe": false],
                "prompts": ["listChanged": false],
            ],
            "serverInfo": ["name": .string(Self.name), "title": "Cortex knowledge base", "version": .string(Self.version)],
            "instructions": .string(Self.instructions),
        ]
    }

    static let instructions = """
        Cortex is my knowledge base: notes, skills and to-dos as Markdown files, one folder per project, also used from the Cortex app's palette. \
        Search before creating, so nothing is written twice. Paths are relative to the knowledge folder (`server-config/notes/docker.md`). \
        Writes without a project go to the project linked to the working directory, else to the inbox; sorting the inbox can wait. \
        The prompts are my skills, plus file-this (file a text) and tidy-inbox. \
        The palette's own quick actions (`>`) and `$` commands are TOML files in the actions folder: list_actions shows them, create_action writes one.
        """

    // MARK: - Shared

    /// Reads what changed on disk since the last request.
    func refresh() async throws {
        try await library.refresh()
    }

    /// The project linked to a root of the client or the working directory,
    /// else the inbox.
    func currentProject() throws -> String {
        let projects = try library.index.projects()
        for directory in roots + [workingDirectory] {
            if let project = KnowledgeProject.linked(to: directory, in: projects) { return project.id }
        }
        return KnowledgeProject.inboxID
    }

    static func errorResponse(id: JSONValue, _ error: MCPError) -> JSONValue {
        ["jsonrpc": "2.0", "id": id, "error": ["code": .int(error.code), "message": .string(error.message)]]
    }
}

/// A JSON-RPC error.
struct MCPError: Error, Equatable {
    var code: Int
    var message: String

    static func invalidParams(_ message: String) -> MCPError {
        MCPError(code: -32602, message: message)
    }
}

/// A tool that failed in a way the model should see and can correct: the
/// result says so (`isError`) rather than the protocol.
struct ToolError: Error, Equatable {
    var message: String

    init(_ message: String) {
        self.message = message
    }
}
