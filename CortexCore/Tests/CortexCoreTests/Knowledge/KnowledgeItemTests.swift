import Foundation
import Testing
@testable import CortexCore

@Suite struct KnowledgeItemTests {
    let date = Date(timeIntervalSince1970: 1_000_000)

    @Test func classifiesPaths() {
        #expect(KnowledgePath.classify("server-config/README.md")! == ("server-config", .project))
        #expect(KnowledgePath.classify("server-config/notes/docker.md")! == ("server-config", .note))
        #expect(KnowledgePath.classify("server-config/notes/deep/er.md")! == ("server-config", .note))
        #expect(KnowledgePath.classify("server-config/loose.md")! == ("server-config", .note))
        #expect(KnowledgePath.classify("server-config/todos/fix.md")! == ("server-config", .todo))
        #expect(KnowledgePath.classify("server-config/skills/deploy/SKILL.md")! == ("server-config", .skill))
        #expect(KnowledgePath.classify("server-config/skills/deploy/notes.md") == nil, "a skill's own file")
        #expect(KnowledgePath.classify("server-config/assets/readme.md") == nil)
        #expect(KnowledgePath.classify("server-config/notes/image.png") == nil)
        #expect(KnowledgePath.classify("README.md") == nil, "not in a project")
        #expect(KnowledgePath.classify(".conflicts/inbox/notes/a.md") == nil)
        #expect(KnowledgePath.classify("inbox/.hidden.md") == nil)
    }

    @Test func readsANote() throws {
        let item = try #require(KnowledgeItem.parse(path: "inbox/notes/2026-10-22-potrace.md", text: """
            ---
            title: Convert a PNG to an SVG with potrace
            tags: [Images, "#cli"]
            created: 2026-10-22T10:12:00Z
            updated: 2026-10-22T11:00:00Z
            ---
            potrace only reads bitmaps.
            """, modified: date))
        #expect(item.kind == .note)
        #expect(item.project == "inbox")
        #expect(item.title == "Convert a PNG to an SVG with potrace")
        #expect(item.tags == ["images", "cli"])
        #expect(item.updated == FrontMatter.parseDate("2026-10-22T11:00:00Z"))
        #expect(item.pasteText == "potrace only reads bitmaps.")
        #expect(item.status == nil)
    }

    @Test func titleFallsBackToHeadingThenFileName() throws {
        let heading = try #require(KnowledgeItem.parse(path: "p/notes/x.md", text: "\n# Docker on a new server\n\nText", modified: date))
        #expect(heading.title == "Docker on a new server")
        #expect(heading.updated == date, "no front matter: the file's date")
        let file = try #require(KnowledgeItem.parse(path: "inbox/notes/2026-10-22-fix-backup.md", text: "Text", modified: date))
        #expect(file.title == "fix-backup")
    }

    @Test func readsSkillsToDosAndProjects() throws {
        let skill = try #require(KnowledgeItem.parse(path: "p/skills/deploy-with-ansible/SKILL.md", text: """
            ---
            name: deploy-with-ansible
            description: Deploys a compose file with Ansible
            ---
            Steps.
            """, modified: date))
        #expect(skill.kind == .skill)
        #expect(skill.title == "deploy-with-ansible")
        #expect(skill.summary == "Deploys a compose file with Ansible")

        let todo = try #require(KnowledgeItem.parse(path: "p/todos/fix.md", text: "---\ntitle: Fix\nstatus: Done\ndue: 2026-10-30\n---\n", modified: date))
        #expect(todo.status == .done)
        #expect(todo.due == "2026-10-30")
        let open = try #require(KnowledgeItem.parse(path: "p/todos/other.md", text: "Just text", modified: date))
        #expect(open.status == .open)

        let readme = try #require(KnowledgeItem.parse(path: "server-config/README.md", text: "---\nsummary: The box\n---\nAbout", modified: date))
        #expect(readme.kind == .project)
        #expect(readme.title == "Server config")
        let project = KnowledgeProject(id: "server-config", readme: readme)
        #expect(project.name == "Server config")
        #expect(project.summary == "The box")
        #expect(project.about == "About")
        #expect(project.color == nil)
        #expect(project.displaySymbol == "folder")
    }

    @Test func projectColors() throws {
        let readme = try #require(KnowledgeItem.parse(
            path: "server/README.md", text: "---\nname: Server\nsymbol: server.rack\ncolor: Teal\n---\n", modified: date))
        let project = KnowledgeProject(id: "server", readme: readme)
        #expect(project.color == .teal)
        #expect(project.tint == .teal)
        #expect(project.displaySymbol == "server.rack")
        #expect(ProjectColor(name: "grey") == .gray)
        #expect(ProjectColor(name: "chartreuse") == nil, "an unknown name is no colour")

        #expect(KnowledgeProject(id: "inbox").tint == .gray)
        #expect(KnowledgeProject(id: "inbox").displaySymbol == "tray")
        let automatic = KnowledgeProject(id: "server-config").tint
        #expect(automatic == ProjectColor.automatic(for: "server-config"), "the same on every launch")
        #expect(ProjectColor.automatic.contains(automatic))
        let tints = Set(["cortex", "server-config", "home", "work", "reading", "garden"].map(ProjectColor.automatic(for:)))
        #expect(tints.count > 2, "projects get different colours")

        #expect(ProjectColor.leastUsed(by: [KnowledgeProject(id: "inbox")]) == .blue)
        let used = [KnowledgeProject(id: "a", color: .blue), KnowledgeProject(id: "b", color: .orange), KnowledgeProject(id: "c", color: .blue)]
        #expect(ProjectColor.leastUsed(by: used) == .green)
    }

    @Test func slugs() {
        #expect(KnowledgeSlug.make("Convert a PNG to an SVG with potrace") == "convert-a-png-to-an-svg-with-potrace")
        #expect(KnowledgeSlug.make("Größe ändern: Übersicht") == "groesse-aendern-uebersicht")
        #expect(KnowledgeSlug.make("Café — résumé!") == "cafe-resume")
        #expect(KnowledgeSlug.make("  ") == "untitled")
        #expect(KnowledgeSlug.make("🎉") == "untitled")
        let long = KnowledgeSlug.make(String(repeating: "word ", count: 30))
        #expect(long.count <= 60)
        #expect(!long.hasSuffix("-"))
    }

    @Test func tags() {
        #expect(KnowledgeTag.normalize("#Docker Compose") == "docker-compose")
        #expect(KnowledgeTag.normalize(" cli ") == "cli")
    }

    @Test func codeBlocks() {
        let body = """
            potrace only reads bitmaps, so convert first:

            ```sh
            magick input.png -threshold 50% input.pbm
            potrace input.pbm -s -o output.svg
            ```

            ~~~~
            plain
            ```
            still inside
            ~~~~

            ```swift title="x"
            let a = 1
            """
        let blocks = KnowledgeMarkdown.codeBlocks(in: body)
        #expect(blocks.count == 3)
        #expect(blocks[0] == .init(language: "sh", code: "magick input.png -threshold 50% input.pbm\npotrace input.pbm -s -o output.svg"))
        #expect(blocks[1] == .init(language: "", code: "plain\n```\nstill inside"))
        #expect(blocks[2] == .init(language: "swift", code: "let a = 1"), "unclosed runs to the end")
        #expect(KnowledgeMarkdown.codeBlocks(in: "Inline ``` is not a fence ```x``` here").isEmpty)
    }

    @Test func checklist() {
        let body = """
            The nightly run has been failing.

            - [x] check the cron log
            - [ ] rotate the S3 key
              * [X] nested and done
            - [ ]
            - not a task
            """
        let checklist = TodoChecklist(body: body)
        #expect(checklist.items.map(\.text) == ["check the cron log", "rotate the S3 key", "nested and done", ""])
        #expect(checklist.items.map(\.isDone) == [true, false, true, false])
        #expect(checklist.doneCount == 2)

        let toggled = TodoChecklist.toggling(itemAt: 1, in: body)
        #expect(toggled.contains("- [x] rotate the S3 key"))
        #expect(TodoChecklist.toggling(itemAt: 1, in: toggled) == body)
        #expect(TodoChecklist.toggling(itemAt: 9, in: body) == body)

        let added = TodoChecklist.adding("run once by hand", to: "- [ ] a\n- [x] b\n\nAfter")
        #expect(added == "- [ ] a\n- [x] b\n- [ ] run once by hand\n\nAfter")
        #expect(TodoChecklist.adding("first", to: "Text\n") == "Text\n\n- [ ] first\n")
    }
}

private func == (lhs: (project: String, kind: KnowledgeKind), rhs: (String, KnowledgeKind)) -> Bool {
    lhs.project == rhs.0 && lhs.kind == rhs.1
}
