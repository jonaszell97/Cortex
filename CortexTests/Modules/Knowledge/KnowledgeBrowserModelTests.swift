import Foundation
import Testing
@testable import Cortex
import CortexCore

/// The knowledge browser's model: a project's items by kind and in order,
/// the selection, revealing an item, the metadata rows, searching, and
/// editing: saving before moving on, tags as chips, following a rename,
/// moving, creating and deleting items, staying on a conflict.
@MainActor
@Suite struct KnowledgeBrowserModelTests {
    let suiteName = "CortexTests-\(UUID().uuidString)"
    let root: URL
    let service: KnowledgeService
    var folder: KnowledgeFolder { service.folder }

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "CortexBrowser-\(UUID().uuidString)", directoryHint: .isDirectory)
        let store = UserDefaults(suiteName: suiteName)!
        store.set(root.path(percentEncoded: false), forKey: "knowledge.folder")
        store.set(false, forKey: "knowledge.keepHistory")
        store.set(false, forKey: "knowledge.linkSkills")
        service = KnowledgeService(settings: KnowledgeSettings(defaults: ModuleDefaults(id: "knowledge", store: store)))
        try folder.write("---\nname: Server config\n---\n", to: "server-config/README.md")
        try folder.write(
            "---\ntitle: Docker\ntags: [docker]\nupdated: 2026-10-20T10:00:00Z\nsource: outline\n---\nInstall it.\n",
            to: "server-config/notes/docker.md")
        try folder.write("---\ntitle: Restic\nupdated: 2026-10-21T10:00:00Z\n---\nBack up.\n", to: "server-config/notes/restic.md")
        try folder.write(
            "---\ntitle: Renew certs\nstatus: done\ndone: 2026-10-19T10:00:00Z\n---\n", to: "server-config/todos/renew-certs.md")
        try folder.write(
            "---\ntitle: Fix backup\nstatus: open\ndue: 2026-10-30\n---\n- [x] Check logs\n- [ ] Rotate key\n",
            to: "server-config/todos/fix-backup.md")
        try folder.write("---\nname: Deploy\ndescription: Deploys the stack\n---\nRun it.\n", to: "server-config/skills/deploy/SKILL.md")
        try folder.write("---\nname: Audit\ndescription: Audits the stack\n---\n", to: "server-config/skills/audit/SKILL.md")
        try folder.write("---\ntitle: Call Anna\n---\n", to: "inbox/todos/2026-10-21-call-anna.md")
    }

    func tearDown() {
        service.stop()
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
    }

    @Test func listsAProjectsItemsByKind() async throws {
        await service.start()
        defer { tearDown() }
        let model = KnowledgeBrowserModel(service: service)
        #expect(model.projectID == "inbox")
        await model.load()
        #expect(model.listed.isEmpty && model.count(of: .todo) == 1)

        await model.selectProject("server-config")
        #expect(model.listed.map(\.path) == ["server-config/notes/restic.md", "server-config/notes/docker.md"], "newest first")
        #expect(model.selectedPath == "server-config/notes/restic.md", "the first is selected")

        await model.selectKind(.todo)
        #expect(model.listed.map(\.title) == ["Fix backup", "Renew certs"], "open ones before done ones")
        #expect(model.selected?.title == "Fix backup")
        #expect(model.editor.path == "server-config/todos/fix-backup.md", "the editor follows the selection")

        await model.selectKind(.skill)
        #expect(model.listed.map(\.title) == ["Audit", "Deploy"], "by name")
    }

    @Test func revealsAnItem() async throws {
        await service.start()
        defer { tearDown() }
        let model = KnowledgeBrowserModel(service: service)
        await model.load()

        await model.reveal("server-config/todos/renew-certs.md")
        #expect(model.projectID == "server-config" && model.kind == .todo)
        #expect(model.selected?.path == "server-config/todos/renew-certs.md")

        await model.reveal("inbox/README.md")
        #expect(model.projectID == "inbox" && model.kind == .todo, "a project keeps the kind")
    }

    @Test func showsTheMetadata() async throws {
        await service.start()
        defer { tearDown() }
        let note = try #require(try folder.item(at: "server-config/notes/docker.md"))
        let rows = KnowledgeBrowserDetail.metadataRows(note, projectName: "Server config")
        #expect(rows.map(\.label) == ["Project", "Updated", "source"], "title and tags are fields")
        #expect(rows.last?.value == "outline", "other front matter as written")

        let todo = try #require(try folder.item(at: "server-config/todos/fix-backup.md"))
        let todoRows = KnowledgeBrowserDetail.metadataRows(todo, projectName: "Server config")
        #expect(todoRows.map(\.label) == ["Project", "Status", "Due", "Checklist", "Updated"])
        #expect(todoRows[3].value == "1 of 2 done")

        let skill = try #require(try folder.item(at: "server-config/skills/deploy/SKILL.md"))
        #expect(KnowledgeBrowserDetail.metadataRows(skill, projectName: "Server config").map(\.label) == ["Project", "Updated"])
    }

    @Test func savesBeforeShowingAnotherItem() async throws {
        await service.start()
        defer { tearDown() }
        let model = KnowledgeBrowserModel(service: service)
        await model.reveal("server-config/notes/docker.md")
        model.editor.fields.body = "Install it with the script."
        model.editor.fields.tags = "docker, setup"
        #expect(model.editor.isDirty)

        await model.select("server-config/notes/restic.md")
        #expect(model.selectedPath == "server-config/notes/restic.md" && !model.editor.isDirty)
        let docker = try #require(try folder.item(at: "server-config/notes/docker.md"))
        #expect(docker.body.trimmingCharacters(in: .newlines) == "Install it with the script.")
        #expect(docker.tags == ["docker", "setup"])
        #expect(docker.frontMatter.string("source") == "outline", "other keys are kept")
    }

    @Test func followsARename() async throws {
        await service.start()
        defer { tearDown() }
        let model = KnowledgeBrowserModel(service: service)
        await model.reveal("server-config/notes/docker.md")
        model.editor.fields.title = "Docker on a new server"
        #expect(await model.save())
        await model.load()
        #expect(model.selectedPath == "server-config/notes/docker-on-a-new-server.md")
        #expect(model.selected?.title == "Docker on a new server")
        #expect(!folder.exists("server-config/notes/docker.md"))
    }

    @Test func movesAnItemToAnotherProject() async throws {
        try folder.write("---\nname: Home\n---\n", to: "home/README.md")
        await service.start()
        defer { tearDown() }
        let model = KnowledgeBrowserModel(service: service)
        await model.reveal("server-config/notes/restic.md")
        model.editor.fields.tags = "backup"

        await model.move(to: "home")
        #expect(!folder.exists("server-config/notes/restic.md"))
        let moved = try #require(try folder.item(at: "home/notes/restic.md"))
        #expect(moved.tags == ["backup"], "other edits are saved with it")
        #expect(model.projectID == "server-config", "the browser stays on the project")
        #expect(model.listed.map(\.path) == ["server-config/notes/docker.md"])
        #expect(model.selectedPath == "server-config/notes/docker.md" && model.editor.path == "server-config/notes/docker.md",
                "the next item is selected")

        await model.selectKind(.skill)
        #expect(!model.editor.canMove, "skills stay where their folder is")
        await model.move(to: "home")
        #expect(folder.exists("server-config/skills/audit/SKILL.md"))
    }

    @Test func searchesTheList() async throws {
        await service.start()
        defer { tearDown() }
        let model = KnowledgeBrowserModel(service: service)
        await model.selectProject("server-config")
        model.filter = "INSTALL"
        #expect(model.filtered.map(\.title) == ["Docker"], "the text, ignoring case")
        model.filter = "docker back"
        #expect(model.filtered.isEmpty, "every word must match")
        model.filter = ""
        #expect(model.filtered.count == 2)
    }

    @Test func editsTagsAsChips() async throws {
        await service.start()
        defer { tearDown() }
        let model = KnowledgeBrowserModel(service: service)
        await model.reveal("server-config/notes/docker.md")
        #expect(model.tags == ["docker"])
        model.newTag = "setup"
        #expect(model.isDirty && !model.editor.isDirty, "a typed tag counts as an edit")
        model.addNewTag()
        model.removeTag("docker")
        #expect(model.tags == ["setup"] && model.newTag.isEmpty)

        model.newTag = "infra"
        await model.select("server-config/notes/restic.md")
        let docker = try #require(try folder.item(at: "server-config/notes/docker.md"))
        #expect(docker.tags == ["setup", "infra"], "a typed tag is saved too")
    }

    @Test func createsAndDeletesItems() async throws {
        await service.start()
        defer { tearDown() }
        let model = KnowledgeBrowserModel(service: service)
        await model.selectProject("server-config")
        await model.selectKind(.todo)
        await model.create(.todo, title: "Renew the domain")
        #expect(model.selectedPath == "server-config/todos/renew-the-domain.md" && model.editor.fields.title == "Renew the domain")

        await model.delete("server-config/todos/renew-the-domain.md")
        #expect(!folder.exists("server-config/todos/renew-the-domain.md"))
        #expect(model.selectedPath != nil && model.listed.count == 2, "another item is shown")
    }

    @Test func closesATodoFromItsRow() async throws {
        await service.start()
        defer { tearDown() }
        let model = KnowledgeBrowserModel(service: service)
        await model.reveal("server-config/todos/fix-backup.md")
        await model.setDone("server-config/todos/fix-backup.md", true)
        #expect(try folder.item(at: "server-config/todos/fix-backup.md")?.status == .done)
        #expect(model.editor.fields.isDone, "the editor shows it")
    }

    @Test func movesAnotherItemFromItsMenu() async throws {
        try folder.write("---\nname: Home\n---\n", to: "home/README.md")
        await service.start()
        defer { tearDown() }
        let model = KnowledgeBrowserModel(service: service)
        await model.reveal("server-config/notes/restic.md")
        await model.move("server-config/notes/docker.md", to: "home")
        #expect(folder.exists("home/notes/docker.md") && !folder.exists("server-config/notes/docker.md"))
        #expect(model.selectedPath == "server-config/notes/restic.md", "the selection stays")
    }

    @Test func staysOnAConflict() async throws {
        await service.start()
        defer { tearDown() }
        let model = KnowledgeBrowserModel(service: service)
        await model.reveal("server-config/notes/docker.md")
        model.editor.fields.body = "Mine"
        try folder.write("---\ntitle: Docker\n---\nTheirs\n", to: "server-config/notes/docker.md")

        await model.selectKind(.todo)
        #expect(model.kind == .note && model.selectedPath == "server-config/notes/docker.md", "nothing else is shown")
        #expect(model.editor.hasConflict && model.editor.fields.body == "Mine")

        // A refresh meanwhile keeps the edits on screen.
        await service.refreshNow()
        await model.load()
        model.editor.folderChanged()
        #expect(model.editor.fields.body == "Mine")

        model.editor.revert()
        #expect(model.editor.fields.body == "Theirs")
        await model.selectKind(.todo)
        #expect(model.kind == .todo)
    }
}
