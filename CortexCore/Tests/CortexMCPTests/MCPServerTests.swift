import CortexCore
import Foundation
import Testing
@testable import CortexMCP

/// The MCP server as a client sees it: JSON-RPC lines in, lines out,
/// against a temporary knowledge folder.
@Suite struct MCPServerTests {
    let folder: KnowledgeFolder
    let actions: URL
    let server: MCPServer
    let now = Date(timeIntervalSince1970: 1_792_663_920) // 2026-10-22T10:12:00Z

    init() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "CortexMCPTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        folder = KnowledgeFolder(root: root)
        try folder.prepare()
        try folder.createProject(id: "server-config", name: "Server config", summary: "The home server", folders: ["/work/server"])
        try folder.createProject(id: "server-old", name: "Old server")
        actions = root.appending(path: ".actions", directoryHint: .isDirectory)
        server = try MCPServer(folder: folder, actionsDirectory: actions, workingDirectory: "/work/server/compose") { [now] in now }
    }

    // MARK: - Helpers

    private var nextID = Counter()

    /// Sends a request and returns its result (or error object).
    @discardableResult
    func request(_ method: String, _ params: JSONValue = [:]) async throws -> JSONValue {
        let id = nextID.next()
        let lines = await server.receive((["jsonrpc": "2.0", "id": .int(id), "method": .string(method), "params": params] as JSONValue).line)
        let response = try JSONValue.parse(try #require(lines.first))
        #expect(response["id"] == .int(id))
        return response["result"] ?? response["error"] ?? .null
    }

    /// Calls a tool; returns its structured result, or the error text.
    func call(_ tool: String, _ arguments: JSONValue = [:]) async throws -> (result: JSONValue, error: String?) {
        let result = try await request("tools/call", ["name": .string(tool), "arguments": arguments])
        if result["isError"] == true {
            return (.null, result["content"]?.arrayValue?.first?["text"]?.stringValue)
        }
        return (try #require(result["structuredContent"]), nil)
    }

    // MARK: - Protocol

    @Test func negotiatesTheProtocolVersion() async throws {
        var result = try await request("initialize", ["protocolVersion": "2025-06-18", "capabilities": [:]])
        #expect(result["protocolVersion"] == "2025-06-18")
        #expect(result["serverInfo"]?["name"] == "cortex")
        #expect(result["capabilities"]?["tools"] != nil && result["capabilities"]?["prompts"] != nil)
        result = try await request("initialize", ["protocolVersion": "1999-01-01"])
        #expect(result["protocolVersion"] == .string(MCPServer.protocolVersions[0]))
        #expect(try await request("ping") == [:])
        #expect(try await request("nope")["code"] == -32601)
    }

    @Test func answersBadInputWithErrors() async throws {
        let parse = try JSONValue.parse(try #require(await server.receive("{oops").first))
        #expect(parse["error"]?["code"] == -32700 && parse["id"] == .null)
        #expect(await server.receive(#"{"jsonrpc":"2.0","method":"notifications/cancelled"}"#).isEmpty)
        #expect(try await request("tools/call", ["name": "nope"])["code"] == -32602)
        let batch = await server.receive(#"[{"jsonrpc":"2.0","id":1,"method":"ping"},{"jsonrpc":"2.0","id":2,"method":"ping"}]"#)
        #expect(try JSONValue.parse(try #require(batch.first)).arrayValue?.count == 2)
    }

    @Test func asksForRootsAndUsesThemForTheCurrentProject() async throws {
        let server = try MCPServer(folder: folder, workingDirectory: "/") { [now] in now }
        _ = await server.receive(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{"roots":{}}}}"#)
        let out = await server.receive(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        let rootsRequest = try JSONValue.parse(try #require(out.first))
        #expect(rootsRequest["method"] == "roots/list")
        let id = try #require(rootsRequest["id"]?.stringValue)
        #expect(await server.receive(#"{"jsonrpc":"2.0","id":"\#(id)","result":{"roots":[{"uri":"file:///work/server/","name":"server"}]}}"#).isEmpty)
        try await server.refresh()
        #expect(try await server.currentProject() == "server-config")
    }

    @Test func listsTheTools() async throws {
        let tools = try #require(try await request("tools/list")["tools"]?.arrayValue)
        let names = tools.compactMap { $0["name"]?.stringValue }
        #expect(names == [
            "list_projects", "search", "read", "create_note", "update_note", "append_note", "create_skill",
            "list_todos", "create_todo", "update_todo", "complete_todo", "create_project", "list_actions", "create_action", "delete",
        ])
        #expect(tools.allSatisfy { $0["inputSchema"]?["type"] == "object" })
        #expect(tools.first { $0["name"] == "delete" }?["annotations"]?["destructiveHint"] == true)
    }

    // MARK: - Tools

    @Test func writesToTheProjectLinkedToTheWorkingDirectory() async throws {
        let (note, _) = try await call("create_note", ["title": "Docker on a new server", "body": "Install it.", "tags": ["Docker"]])
        #expect(note["path"] == "server-config/notes/docker-on-a-new-server.md")
        #expect(note["uri"] == "cortex://server-config/notes/docker-on-a-new-server.md")
        let item = try #require(try folder.item(at: "server-config/notes/docker-on-a-new-server.md"))
        #expect(item.tags == ["docker"] && item.body == "Install it.\n" && item.created == now)

        let projects = try await call("list_projects").result
        #expect(projects["current"] == "server-config")
        let listed = try #require(projects["projects"]?.arrayValue)
        #expect(listed.first?["id"] == "inbox")
        #expect(listed.first { $0["id"] == "server-config" }?["items"] == 1)

        // A prefix that names one project, "inbox", and one that names several.
        #expect(try await call("create_note", ["title": "A", "project": "server-c"]).result["path"] == "server-config/notes/a.md")
        #expect(try await call("create_note", ["title": "B", "project": "inbox"]).result["path"] == "inbox/notes/2026-10-22-b.md")
        let ambiguous = try await call("create_note", ["title": "C", "project": "server"]).error
        #expect(ambiguous?.contains("several projects") == true)
    }

    @Test func createsCommandsAndActions() async throws {
        var (result, error) = try await call("create_action", [
            "name": "GitHub Repository", "trigger": "$gh", "url": "https://github.com/{argument}", "example": "owner/repo",
        ])
        #expect(error == nil)
        #expect(result["kind"] == "command" && result["usage"] == "$gh …")
        #expect(result["path"]?.stringValue?.hasSuffix(".actions/gh.toml") == true)
        #expect(result["contents"]?.stringValue?.hasPrefix("name = \"GitHub Repository\"\ntrigger = \"$gh\"\n") == true)

        (result, error) = try await call("create_action", [
            "name": "Shrink video", "accepts": ["files"], "command": "ffmpeg -i {input} -vf scale=-2:720 {output}",
            "output_suffix": "-720p", "confirm": true,
        ])
        #expect(error == nil && result["kind"] == "action" && result["usage"] == nil)

        let listed = try await call("list_actions").result
        #expect(listed["files"]?.arrayValue?.map { $0["file"] } == ["gh.toml", "shrink-video.toml"])
        #expect(listed["files"]?.arrayValue?.last?["accepts"] == ["files"])
        #expect(listed["taken_triggers"]?.arrayValue?.contains("gh") == true)
        #expect(listed["taken_triggers"]?.arrayValue?.contains("ask") == true)
        #expect(listed["problems"] == nil)

        // Taken names, files that would not load, secrets.
        error = try await call("create_action", ["name": "GH", "trigger": "gh", "command": "gh browse"]).error
        #expect(error == "Nothing was written: “gh” is already the trigger of gh.toml.")
        error = try await call("create_action", ["name": "Ask", "trigger": "Ask", "command": "say hi"]).error
        #expect(error?.contains("one of the app's commands") == true)
        error = try await call("create_action", ["name": "Quote", "trigger": "q", "command": "jq '.{argument}'"]).error
        #expect(error?.contains("single quotes") == true)
        let key = "curl -H 'Authorization: Bearer sk-proj-abcdefghijklmnopqrstuvwxyz0123456789ABCD' {argument}"
        error = try await call("create_action", ["name": "Call", "trigger": "call", "command": .string(key)]).error
        #expect(error?.contains("confirm_sensitive") == true)
        try FileManager.default.createDirectory(at: actions, withIntermediateDirectories: true)
        try Data("name = 1".utf8).write(to: actions.appending(path: "bad.toml"))
        #expect(try await call("list_actions").result["problems"]?.arrayValue?.first?["file"] == "bad.toml")
        #expect(try FileManager.default.contentsOfDirectory(atPath: actions.path).count == 3)
    }

    @Test func searchesAndReads() async throws {
        try folder.createNote(title: "Convert a PNG with potrace", body: "```sh\npotrace in.pbm\n```", project: "server-config", tags: ["cli"], now: now)
        try folder.createNote(title: "Potrace elsewhere", body: "", project: "server-old", now: now)
        var results = try #require(try await call("search", ["query": "potr"]).result["results"]?.arrayValue)
        #expect(results.count == 2)
        // "server-config" exactly, though "server" is a prefix of both.
        results = try #require(try await call("search", ["query": "potrace", "project": "server-config"]).result["results"]?.arrayValue)
        #expect(results.map { $0["project"] } == ["server-config"])
        results = try #require(try await call("search", ["query": "#cli"]).result["results"]?.arrayValue)
        #expect(results.count == 1)
        #expect(try await call("search", ["kind": "bogus"]).error != nil)

        let read = try await call("read", ["path": "cortex://server-config/notes/convert-a-png-with-potrace.md"]).result
        #expect(read["title"] == "Convert a PNG with potrace")
        #expect(read["front_matter"]?["tags"] == ["cli"])
        #expect(read["body"] == "```sh\npotrace in.pbm\n```\n")
        #expect(try await call("read", ["path": "../etc/passwd"]).error != nil)
        #expect(try await call("read", ["path": "server-config/.git/config"]).error != nil)
    }

    @Test func updatesRenamesMovesAndAppends() async throws {
        let path = try folder.createNote(title: "Docker", body: "One", project: "server-config", now: now)
        let (updated, _) = try await call("update_note", ["path": .string(path), "title": "Docker Compose", "tags": ["compose"]])
        #expect(updated["path"] == "server-config/notes/docker-compose.md")
        #expect(updated["moved_from"] == .string(path))
        let (moved, _) = try await call("update_note", ["path": "server-config/notes/docker-compose.md", "project": "inbox"])
        let movedPath = try #require(moved["path"]?.stringValue)
        #expect(movedPath == "inbox/notes/2026-10-22-docker-compose.md")
        _ = try await call("append_note", ["path": .string(movedPath), "text": "Two"])
        let item = try #require(try folder.item(at: movedPath))
        #expect(item.body == "One\n\nTwo\n" && item.tags == ["compose"])
        #expect(try await call("update_note", ["path": "inbox/notes/missing.md", "body": "x"]).error?.contains("No item") == true)
    }

    @Test func handlesTodos() async throws {
        let (created, _) = try await call("create_todo", [
            "title": "Fix the restic backup", "checklist": ["check the log", "rotate the key"], "due": "2026-10-30", "tags": ["backup"],
        ])
        let path = try #require(created["path"]?.stringValue)
        #expect(path == "server-config/todos/fix-the-restic-backup.md")
        #expect(try folder.item(at: path)?.body == "- [ ] check the log\n- [ ] rotate the key\n")
        #expect(try await call("create_todo", ["title": "x", "due": "next week"]).error?.contains("YYYY-MM-DD") == true)

        _ = try await call("update_todo", ["path": .string(path), "checklist": [["text": "check the log", "done": true], "rotate the key", "run once"]])
        var item = try #require(try folder.item(at: path))
        #expect(TodoChecklist(body: item.body).items.map(\.isDone) == [true, false, false])

        try folder.createTodo(title: "Older", project: "inbox", now: now.addingTimeInterval(-60))
        var todos = try #require(try await call("list_todos").result["todos"]?.arrayValue)
        #expect(todos.map { $0["title"] } == ["Fix the restic backup", "Older"], "due ones first")
        #expect(todos.first?["checklist"] == "1/3")

        _ = try await call("complete_todo", ["path": .string(path)])
        item = try #require(try folder.item(at: path))
        #expect(item.status == .done && item.frontMatter.date("done") == now)
        todos = try #require(try await call("list_todos", ["status": "done"]).result["todos"]?.arrayValue)
        #expect(todos.map { $0["title"] } == ["Fix the restic backup"])

        _ = try await call("update_todo", ["path": .string(path), "status": "open", "due": ""])
        item = try #require(try folder.item(at: path))
        #expect(item.status == .open && item.due == nil && item.frontMatter["done"] == nil)
        let note = try folder.createNote(title: "N", body: "", project: "inbox", now: now)
        #expect(try await call("update_todo", ["path": .string(note), "status": "done"]).error?.contains("not a to-do") == true)
    }

    @Test func refusesSecretsUnlessConfirmed() async throws {
        let secret = "ghp_abcdefghijklmnopqrstuvwxyz0123456789"
        let refused = try await call("create_note", ["title": "Token", "body": .string(secret)])
        #expect(refused.error?.contains("confirm_sensitive") == true)
        #expect(folder.itemFiles().keys.allSatisfy { $0.hasSuffix("README.md") })
        let saved = try await call("create_note", ["title": "Token", "body": .string(secret), "confirm_sensitive": true])
        let path = try #require(saved.result["path"]?.stringValue)
        // Already in the file: retagging it does not ask again.
        #expect(try await call("update_note", ["path": .string(path), "tags": ["keys"]]).error == nil)
    }

    @Test func createsSkillsProjectsAndDeletes() async throws {
        let (skill, _) = try await call("create_skill", [
            "name": "Deploy with Ansible", "description": "Deploys a compose file.", "body": "1. Push", "project": "server-config",
        ])
        #expect(skill["path"] == "server-config/skills/deploy-with-ansible/SKILL.md")
        try folder.write("services: {}\n", to: "server-config/skills/deploy-with-ansible/compose.yaml")
        let read = try await call("read", ["path": "server-config/skills/deploy-with-ansible/SKILL.md"]).result
        #expect(read["files"] == ["compose.yaml"])
        #expect(try await call("read", ["path": "server-config/skills/deploy-with-ansible/compose.yaml"]).result["text"] == "services: {}\n")

        let (project, _) = try await call("create_project", ["id": "Home Lab", "name": "Home lab", "folders": ["~/lab"]])
        #expect(project["id"] == "home-lab")
        #expect(try folder.item(at: "home-lab/README.md")?.frontMatter.list("folders") == ["~/lab"])
        #expect(try await call("create_project", ["id": "home-lab", "name": "Again"]).error?.contains("already exists") == true)

        let note = try folder.createNote(title: "Gone", body: "", project: "inbox", now: now)
        #expect(try await call("delete", ["path": .string(note)]).result["deleted"] == .string(note))
        #expect(!folder.exists(note))
        #expect(try await call("delete", ["path": "home-lab/README.md"]).error != nil)
    }

    // MARK: - Resources and prompts

    @Test func servesFilesAsResources() async throws {
        let path = try folder.createNote(title: "Docker", body: "Body", project: "server-config", now: now)
        let resources = try #require(try await request("resources/list")["resources"]?.arrayValue)
        #expect(resources.contains { $0["uri"] == .string("cortex://\(path)") && $0["title"] == "Docker" })
        let contents = try await request("resources/read", ["uri": .string("cortex://\(path)")])["contents"]?.arrayValue
        #expect(contents?.first?["text"]?.stringValue?.hasSuffix("Body\n") == true)
        #expect(contents?.first?["mimeType"] == "text/markdown")
        #expect(try await request("resources/read", ["uri": "cortex://../x.md"])["code"] == -32002)
        #expect(try await request("resources/templates/list")["resourceTemplates"]?.arrayValue?.count == 1)
    }

    @Test func servesSkillsAndInstructionsAsPrompts() async throws {
        try folder.createSkill(name: "review", description: "Reviews a diff.", body: "Review $ARGUMENTS carefully.", project: "server-config", now: now)
        try folder.createSkill(name: "deploy", description: "Deploys.", body: "Push it.", project: "server-config", now: now)
        try folder.createSkill(name: "file-this", description: "Shadowed", body: "x", project: "server-config", now: now)
        try folder.createNote(title: "Loose idea", body: "Something about backups", project: "inbox", now: now)

        let prompts = try #require(try await request("prompts/list")["prompts"]?.arrayValue).compactMap { $0["name"]?.stringValue }
        #expect(prompts == ["file-this", "tidy-inbox", "deploy", "review"])

        func text(_ result: JSONValue) -> String? {
            result["messages"]?.arrayValue?.first?["content"]?["text"]?.stringValue
        }
        let review = try await request("prompts/get", ["name": "review", "arguments": ["request": "the last commit"]])
        #expect(text(review)?.hasSuffix("Review the last commit carefully.") == true)
        let deploy = try await request("prompts/get", ["name": "deploy", "arguments": ["request": "the API"]])
        #expect(text(deploy)?.hasSuffix("Push it.\n\n---\n\nthe API") == true)

        let fileThis = try await request("prompts/get", ["name": "file-this", "arguments": ["text": "potrace converts bitmaps"]])
        #expect(text(fileThis)?.contains("server-config: Server config — The home server (linked to the current working directory)") == true)
        #expect(text(fileThis)?.hasSuffix("potrace converts bitmaps") == true)
        #expect(try await request("prompts/get", ["name": "file-this"])["code"] == -32602)

        let tidy = try await request("prompts/get", ["name": "tidy-inbox"])
        #expect(text(tidy)?.contains("note: Loose idea") == true)
        #expect(try await request("prompts/get", ["name": "missing"])["code"] == -32602)
    }
}

/// Request IDs, counting up.
final class Counter: @unchecked Sendable {
    private var value = 0
    func next() -> Int {
        value += 1
        return value
    }
}
