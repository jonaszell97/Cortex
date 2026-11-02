import Foundation
import Testing
@testable import CortexCore

/// To-dos and edits: writing, closing, ticking, the editor's save with its
/// renames and moves, the `!` query and the list order.
@Suite struct KnowledgeTodoTests {
    let folder: KnowledgeFolder
    let now = Date(timeIntervalSince1970: 1_792_663_920) // 2026-10-22T10:12:00Z
    let utc = TimeZone(identifier: "UTC")!

    init() throws {
        folder = try makeKnowledgeFolder()
    }

    @Test func writesATodo() throws {
        let path = try folder.createTodo(title: "Fix the backup", project: "server-config", tags: ["#Backup"], due: "2026-10-30", now: now)
        #expect(path == "server-config/todos/fix-the-backup.md")
        #expect(try folder.text(at: path) == """
            ---
            title: Fix the backup
            status: open
            tags: [backup]
            due: 2026-10-30
            created: 2026-10-22T10:12:00Z
            updated: 2026-10-22T10:12:00Z
            ---

            """)
        let inbox = try folder.createTodo(title: "Call Anna", now: now)
        #expect(inbox.hasPrefix("inbox/todos/") && inbox.hasSuffix("-call-anna.md"))
        #expect(try folder.createTodo(title: "Fix the backup", project: "server-config", now: now) == "server-config/todos/fix-the-backup-2.md")
    }

    @Test func closesAndReopensKeepingOtherKeys() throws {
        try folder.write("---\ntitle: Fix it\nstatus: open\nowner: me # who\nextra:\n  nested: map\n---\nBody\n", to: "p/todos/fix-it.md")
        try folder.setStatus(.done, of: "p/todos/fix-it.md", now: now)
        var item = try #require(try folder.item(at: "p/todos/fix-it.md"))
        #expect(item.status == .done)
        #expect(item.frontMatter.date("done") == now)
        #expect(item.updated == now)
        #expect(item.frontMatter.string("owner") == "me")
        #expect(try folder.text(at: "p/todos/fix-it.md").contains("extra:\n  nested: map\n"))
        #expect(item.body == "Body\n")

        try folder.setStatus(.open, of: "p/todos/fix-it.md", now: now)
        item = try #require(try folder.item(at: "p/todos/fix-it.md"))
        #expect(item.status == .open)
        #expect(item.frontMatter["done"] == nil)
    }

    @Test func ticksChecklistItems() throws {
        try folder.write("---\ntitle: T\n---\nIntro\n\n- [x] one\n- [ ] two\n", to: "p/todos/t.md")
        try folder.toggleChecklistItem(1, of: "p/todos/t.md", now: now)
        try folder.toggleChecklistItem(0, of: "p/todos/t.md", now: now)
        let item = try #require(try folder.item(at: "p/todos/t.md"))
        #expect(item.body == "Intro\n\n- [ ] one\n- [x] two\n")
    }

    // MARK: - The editor's save

    func edit(_ path: String) throws -> KnowledgeEdit {
        let text = try folder.text(at: path)
        return KnowledgeEdit(try #require(KnowledgeItem.parse(path: path, text: text, modified: now)), text: text)
    }

    @Test func savesAnEditInPlace() throws {
        try folder.write("---\ntitle: Docker\ntags: [docker]\nsource: outline\n---\nOld body\n", to: "p/notes/docker.md")
        var edit = try edit("p/notes/docker.md")
        #expect(edit.project == "p" && edit.body == "Old body")
        edit.body = "New body"
        edit.tags = ["docker", "Setup", "docker"]
        let path = try folder.save(edit, at: "p/notes/docker.md", now: now)
        #expect(path == "p/notes/docker.md")
        #expect(try folder.text(at: path) == """
            ---
            title: Docker
            tags: [docker, setup]
            source: outline
            updated: 2026-10-22T10:12:00Z
            ---
            New body

            """)
    }

    @Test func aNewTitleRenamesTheFile() throws {
        try folder.write("---\ntitle: Docker\n---\nBody\n", to: "p/notes/docker.md")
        try folder.write("---\ntitle: Potrace\n---\n", to: "inbox/notes/2026-10-01-potrace.md")
        try folder.write("x", to: "p/notes/docker-compose.md")

        var edit = try edit("p/notes/docker.md")
        edit.title = "Docker Compose"
        #expect(try folder.save(edit, at: "p/notes/docker.md", now: now) == "p/notes/docker-compose-2.md")
        #expect(!folder.exists("p/notes/docker.md"))

        edit = try self.edit("inbox/notes/2026-10-01-potrace.md")
        edit.title = "PNG to SVG"
        #expect(try folder.save(edit, at: "inbox/notes/2026-10-01-potrace.md", now: now) == "inbox/notes/2026-10-01-png-to-svg.md",
                "an inbox file keeps its day")

        edit = try self.edit("p/notes/docker-compose-2.md")
        edit.title = "docker compose"
        #expect(try folder.save(edit, at: "p/notes/docker-compose-2.md", now: now) == "p/notes/docker-compose-2.md",
                "the same slug: no move")
    }

    @Test func anotherProjectMovesTheFile() throws {
        let path = try folder.createTodo(title: "Fix the backup", now: now)
        var edit = try edit(path)
        edit.project = "server-config"
        edit.status = .done
        edit.due = "2026-11-01"
        let moved = try folder.save(edit, at: path, now: now)
        #expect(moved == "server-config/todos/fix-the-backup.md")
        #expect(!folder.exists(path))
        let item = try #require(try folder.item(at: moved))
        #expect(item.status == .done && item.due == "2026-11-01")
        #expect(item.frontMatter.date("done") == now)
    }

    @Test func refusesToOverwriteAChangeOnDisk() throws {
        try folder.write("---\ntitle: A\n---\nOne\n", to: "p/notes/a.md")
        var edit = try edit("p/notes/a.md")
        try folder.write("---\ntitle: A\n---\nChanged by an agent\n", to: "p/notes/a.md")
        edit.body = "Mine"
        #expect(throws: KnowledgeEditConflict(path: "p/notes/a.md")) { try folder.save(edit, at: "p/notes/a.md", now: now) }
        #expect(try folder.text(at: "p/notes/a.md").contains("Changed by an agent"))
    }

    @Test func savesASkillAndAProjectUnderTheirOwnKeys() throws {
        try folder.write("---\nname: deploy\ndescription: Deploy it\n---\nSteps\n", to: "p/skills/deploy/SKILL.md")
        var edit = try edit("p/skills/deploy/SKILL.md")
        #expect(edit.project == nil && edit.summary == "Deploy it")
        edit.title = "deploy-with-ansible"
        edit.summary = "Deploy with Ansible"
        #expect(try folder.save(edit, at: "p/skills/deploy/SKILL.md", now: now) == "p/skills/deploy/SKILL.md", "skills never move")
        let skill = try #require(try folder.item(at: "p/skills/deploy/SKILL.md"))
        #expect(skill.title == "deploy-with-ansible" && skill.summary == "Deploy with Ansible")
        #expect(skill.frontMatter["title"] == nil)
    }

    @Test func copyMineWritesANewItemAndLeavesTheOriginal() throws {
        let path = try folder.createTodo(title: "Fix the backup", project: "p", due: "2026-10-30", now: now)
        var edit = try edit(path)
        edit.body = "- [ ] mine"
        edit.status = .done
        edit.tags = ["ops"]
        try folder.write("---\ntitle: Fix the backup\nstatus: open\n---\nTheirs\n", to: path)
        let copy = try folder.saveCopy(edit, of: path, now: now)
        #expect(copy == "p/todos/fix-the-backup-copy.md")
        let item = try #require(try folder.item(at: copy))
        #expect(item.title == "Fix the backup (copy)" && item.body == "- [ ] mine\n")
        #expect(item.status == .done && item.due == "2026-10-30" && item.tags == ["ops"])
        #expect(try folder.text(at: path).contains("Theirs"))

        try folder.write("---\nname: Server\n---\nAbout\n", to: "server/README.md")
        var readme = try self.edit("server/README.md")
        readme.body = "My about"
        try FileManager.default.removeItem(at: folder.url(for: "server/README.md"))
        let note = try folder.saveCopy(readme, of: "server/README.md", now: now)
        #expect(note == "server/notes/server-copy.md", "a README's copy is a note in its project, even when it is gone")
    }

    @Test func asksAboutSecretsOnlyWhereTheyAreNew() throws {
        let key = "ghp_" + String(repeating: "a1B2", count: 9)
        #expect(KnowledgeEdit(title: "Deploy", body: "token: \(key)", original: "").addsSensitiveText)
        #expect(KnowledgeEdit(title: key, body: "", original: "").addsSensitiveText)
        #expect(!KnowledgeEdit(title: "Deploy", body: "Run make deploy\nThen check the logs", original: "").addsSensitiveText)

        let original = "---\ntitle: Deploy\n---\nIntro\ntoken: \(key)\n"
        #expect(!KnowledgeEdit(title: "Deploy", body: "Intro, longer\ntoken: \(key)", original: original).addsSensitiveText,
                "the key was there before")
        #expect(KnowledgeEdit(title: "Deploy", body: "token: \(key)\nother: sk-proj-\(String(repeating: "x9", count: 20))",
                              original: original).addsSensitiveText)
    }

    // MARK: - The `!` list

    @Test func parsesTheTodoQuery() {
        var query = TodoQuery.parse("fix the backup @server #urgent")
        #expect(!query.showsDone && query.newTitle == "fix the backup")
        #expect(query.query.project == "server" && query.query.tags == ["urgent"])
        #expect(query.query.kinds == [.todo] && query.query.status == .open)

        query = TodoQuery.parse("done backup")
        #expect(query.showsDone && query.newTitle == nil && query.query.text == "backup" && query.query.status == .done)
        #expect(TodoQuery.parse("Done").showsDone)
        #expect(!TodoQuery.parse("doneness").showsDone)
        #expect(TodoQuery.parse("@server").newTitle == nil)
    }

    @Test func ordersDueFirstThenByProject() {
        func todo(_ path: String, due: String? = nil, updated: TimeInterval) -> KnowledgeItem {
            KnowledgeItem(
                path: path, project: String(path.split(separator: "/")[0]), kind: .todo, title: path, status: .open, due: due,
                updated: Date(timeIntervalSince1970: updated), body: "")
        }
        let items = [
            todo("server/todos/a.md", updated: 3),
            todo("inbox/todos/b.md", updated: 1),
            todo("server/todos/c.md", due: "2026-11-01", updated: 0),
            todo("inbox/todos/d.md", updated: 2),
            todo("cortex/todos/e.md", due: "2026-10-30", updated: 0),
        ]
        #expect(TodoList.ordered(items, projects: ["inbox", "cortex", "server"]).map(\.path) == [
            "cortex/todos/e.md", "server/todos/c.md", "inbox/todos/d.md", "inbox/todos/b.md", "server/todos/a.md",
        ])
        #expect(TodoList.isOverdue("2026-10-21", now: now, timeZone: utc))
        #expect(!TodoList.isOverdue("2026-10-22", now: now, timeZone: utc))
    }
}
