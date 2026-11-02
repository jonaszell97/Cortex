import Foundation
import Testing
@testable import Cortex
import CortexCore

/// The note editor's model: loading, saving with a rename, the project
/// picker, to-do fields, and a file changed on disk.
@MainActor
@Suite struct NoteEditorModelTests {
    let suiteName = "CortexTests-\(UUID().uuidString)"
    let root: URL
    let service: KnowledgeService
    var folder: KnowledgeFolder { service.folder }

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "CortexEditor-\(UUID().uuidString)", directoryHint: .isDirectory)
        let store = UserDefaults(suiteName: suiteName)!
        store.set(root.path(percentEncoded: false), forKey: "knowledge.folder")
        store.set(false, forKey: "knowledge.keepHistory")
        service = KnowledgeService(settings: KnowledgeSettings(defaults: ModuleDefaults(id: "knowledge", store: store)))
        try folder.write("---\nname: Server config\n---\n", to: "server-config/README.md")
        try folder.write("---\ntitle: Docker\ntags: [docker, setup]\n---\nInstall it.\n", to: "server-config/notes/docker.md")
        try folder.write("---\ntitle: Call Anna\nstatus: open\n---\n", to: "inbox/todos/2026-10-21-call-anna.md")
    }

    func tearDown() {
        service.stop()
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
    }

    @Test func loadsAndSavesWithARename() async throws {
        await service.start()
        defer { tearDown() }
        let model = NoteEditorModel(service: service)
        #expect(await model.open("server-config/notes/docker.md"))
        #expect(model.fields.title == "Docker" && model.fields.tags == "docker, setup" && model.fields.body == "Install it.")
        #expect(model.canMove && !model.isTodo && model.summaryLabel == nil)
        #expect(!model.isDirty)

        model.fields.title = "Docker on a new server"
        model.fields.body = "Install it with the script."
        #expect(model.isDirty)
        #expect(await model.save())
        #expect(model.path == "server-config/notes/docker-on-a-new-server.md")
        #expect(!model.isDirty)
        #expect(!folder.exists("server-config/notes/docker.md"))
        let hits = await service.search(KnowledgeQuery.parse("script"), limit: 5)
        #expect(hits.map(\.item.path) == ["server-config/notes/docker-on-a-new-server.md"], "indexed at once")
    }

    @Test func movesATodoAndClosesIt() async throws {
        await service.start()
        defer { tearDown() }
        let model = NoteEditorModel(service: service)
        #expect(await model.open("inbox/todos/2026-10-21-call-anna.md"))
        #expect(model.isTodo && model.fields.project == "inbox")
        model.fields.project = "server-config"
        model.fields.isDone = true
        model.dueDate = FrontMatter.parseDate("2026-10-30")
        #expect(model.fields.due == "2026-10-30")
        #expect(await model.save())
        #expect(model.path == "server-config/todos/call-anna.md")
        let todo = try #require(try folder.item(at: "server-config/todos/call-anna.md"))
        #expect(todo.status == .done && todo.due == "2026-10-30")
    }

    @Test func asksWhenTheFileChangedOnDisk() async throws {
        await service.start()
        defer { tearDown() }
        let model = NoteEditorModel(service: service)
        #expect(await model.open("server-config/notes/docker.md"))

        // Without edits, a change is read again.
        try folder.write("---\ntitle: Docker\n---\nChanged by an agent.\n", to: "server-config/notes/docker.md")
        model.folderChanged()
        #expect(model.fields.body == "Changed by an agent.")

        // With edits, saving asks.
        model.fields.body = "Mine"
        try folder.write("---\ntitle: Docker\n---\nChanged again.\n", to: "server-config/notes/docker.md")
        model.folderChanged()
        #expect(model.fields.body == "Mine", "edits are kept")
        #expect(await !model.save())
        #expect(model.hasConflict)
        await model.overwrite()
        #expect(!model.hasConflict && !model.isDirty)
        #expect(try folder.item(at: "server-config/notes/docker.md")?.body == "Mine\n")

        try FileManager.default.removeItem(at: folder.url(for: "server-config/notes/docker.md"))
        model.folderChanged()
        #expect(model.isGone)
    }

    @Test func opensAnotherAfterSaving() async throws {
        await service.start()
        defer { tearDown() }
        let model = NoteEditorModel(service: service)
        #expect(await model.open("server-config/notes/docker.md"))
        model.fields.tags = "docker"
        #expect(await model.open("inbox/todos/2026-10-21-call-anna.md"))
        #expect(try folder.item(at: "server-config/notes/docker.md")?.tags == ["docker"], "saved before switching")
    }
}
