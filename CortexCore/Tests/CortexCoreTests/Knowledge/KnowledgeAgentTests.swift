import Foundation
import Testing
@testable import CortexCore

/// What agents need beyond the palette: skills, appending, replacing a
/// checklist, the project linked to a working directory, the skills
/// symlinks for Claude Code and the filing instructions.
@Suite struct KnowledgeAgentTests {
    let folder: KnowledgeFolder
    let now = Date(timeIntervalSince1970: 1_792_663_920) // 2026-10-22T10:12:00Z

    init() throws {
        folder = try makeKnowledgeFolder()
    }

    @Test func writesASkillInClaudeCodesLayout() throws {
        let path = try folder.createSkill(
            name: "Deploy with Ansible", description: "Deploys a compose file with Ansible. Use when shipping a service.",
            body: "1. Push\n2. Redeploy", project: "server-config", now: now)
        #expect(path == "server-config/skills/deploy-with-ansible/SKILL.md")
        #expect(try folder.text(at: path) == """
            ---
            name: deploy-with-ansible
            description: Deploys a compose file with Ansible. Use when shipping a service.
            created: 2026-10-22T10:12:00Z
            updated: 2026-10-22T10:12:00Z
            ---
            1. Push
            2. Redeploy

            """)
        let second = try folder.createSkill(name: "deploy with ansible", description: "Again", body: "", project: "server-config", now: now)
        #expect(second == "server-config/skills/deploy-with-ansible-2/SKILL.md")
        #expect(try folder.item(at: second)?.title == "deploy-with-ansible-2")

        try folder.write("services: {}\n", to: "server-config/skills/deploy-with-ansible/compose.example.yaml")
        try folder.write("x\n", to: "server-config/skills/deploy-with-ansible/scripts/run.sh")
        #expect(folder.skillFiles(of: path) == ["compose.example.yaml", "scripts/run.sh"])
        #expect(folder.skillFiles(of: "server-config/notes/x.md").isEmpty)
    }

    @Test func appendsToABody() throws {
        let path = try folder.createNote(title: "Docker", body: "First\n\n", project: "p", now: now)
        try folder.append("\nSecond\n", to: path, now: now.addingTimeInterval(60))
        let item = try #require(try folder.item(at: path))
        #expect(item.body == "First\n\nSecond\n")
        #expect(item.updated == now.addingTimeInterval(60))
        let empty = try folder.createNote(title: "Empty", body: "", project: "p", now: now)
        try folder.append("Only", to: empty, now: now)
        #expect(try folder.item(at: empty)?.body == "Only\n")
    }

    @Test func replacesAChecklist() {
        let body = "Intro\n\n- [x] one\n- [ ] two\n\nAfter\n"
        #expect(TodoChecklist.replacing(with: [("a", false), ("b", true)], in: body) == "Intro\n\n- [ ] a\n- [x] b\n\nAfter\n")
        #expect(TodoChecklist.replacing(with: [], in: body) == "Intro\n\nAfter\n")
        #expect(TodoChecklist.replacing(with: [("a", false)], in: "Intro\n") == "Intro\n\n- [ ] a\n")
        #expect(TodoChecklist.replacing(with: [("a", true)], in: "") == "- [x] a\n")
        #expect(TodoChecklist.replacing(with: [], in: "Intro\n") == "Intro\n")
    }

    @Test func findsTheProjectLinkedToAFolder() {
        let projects = [
            KnowledgeProject(id: "inbox"),
            KnowledgeProject(id: "server", folders: ["~/Developer/server-config/"]),
            KnowledgeProject(id: "docs", folders: ["/Users/me/Developer/server-config/docs", "relative/ignored"]),
        ]
        let home = "/Users/me"
        #expect(KnowledgeProject.linked(to: "/Users/me/Developer/server-config", in: projects, home: home)?.id == "server")
        #expect(KnowledgeProject.linked(to: "/Users/me/Developer/server-config/compose", in: projects, home: home)?.id == "server")
        #expect(KnowledgeProject.linked(to: "/Users/me/Developer/server-config/docs/a", in: projects, home: home)?.id == "docs")
        #expect(KnowledgeProject.linked(to: "/Users/me/Developer/server-config-2", in: projects, home: home) == nil)
        #expect(KnowledgeProject.linked(to: "/", in: projects, home: home) == nil)
    }

    @Test func linksSkillsForClaudeCode() throws {
        let skills = folder.root.deletingLastPathComponent()
            .appending(path: "skills-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: skills) }
        let links = KnowledgeSkillLinks(knowledge: folder.root, skills: skills)
        let deploy = try folder.createSkill(name: "deploy", description: "d", body: "", project: "a", now: now)
        let duplicate = try folder.createSkill(name: "deploy", description: "d", body: "", project: "b", now: now)
        let review = try folder.createSkill(name: "review", description: "r", body: "", project: "b", now: now)
        let own = try folder.createSkill(name: "own", description: "o", body: "", project: "b", now: now)

        // Not Cortex's: a folder of its own and a link elsewhere.
        try FileManager.default.createDirectory(at: skills.appending(path: "own"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: skills.appending(path: "elsewhere").path, withDestinationPath: "/tmp")

        var report = try links.update(skillPaths: [deploy, duplicate, review, own])
        #expect(report.linked == ["deploy", "review"])
        #expect(report.added == ["deploy", "review"])
        #expect(report.conflicts == [own, duplicate].sorted())
        let target = try FileManager.default.destinationOfSymbolicLink(atPath: skills.appending(path: "deploy").path)
        #expect(target == folder.root.appending(path: "a/skills/deploy").path(percentEncoded: false))
        #expect(FileManager.default.fileExists(atPath: skills.appending(path: "deploy/SKILL.md").path))

        report = try links.update(skillPaths: [deploy, review])
        #expect(report.added.isEmpty && report.removed.isEmpty && report.linked == ["deploy", "review"])

        report = try links.update(skillPaths: [deploy])
        #expect(report.removed == ["review"])
        #expect(try links.removeAll() == ["deploy"])
        let left = try FileManager.default.contentsOfDirectory(atPath: skills.path).sorted()
        #expect(left == ["elsewhere", "own"])
    }

    @Test func instructionsNameProjectsAndTags() {
        let projects = [KnowledgeProject(id: "inbox"), KnowledgeProject(id: "server", name: "Server", summary: "The box")]
        let text = KnowledgeInstructions.fileThis("potrace notes", projects: projects, tags: ["cli"], current: "server")
        #expect(text.contains("- server: Server — The box (linked to the current working directory)"))
        #expect(text.contains("Tags in use, most used first: cli."))
        #expect(text.hasSuffix("potrace notes"))

        let item = KnowledgeItem(path: "inbox/notes/x.md", project: "inbox", kind: .note, title: "X", updated: now,
                                 body: String(repeating: "a", count: 500))
        let tidy = KnowledgeInstructions.tidyInbox([.init(item)], projects: projects, tags: [])
        #expect(tidy.contains("### inbox/notes/x.md\nnote: X"))
        #expect(tidy.contains(" […]"))
        #expect(KnowledgeInstructions.tidyInbox([], projects: projects, tags: []).contains("The inbox is empty"))
    }

    @Test func indexListsTagsAndOpenTodos() async throws {
        try folder.createNote(title: "A", body: "", project: "p", tags: ["cli", "docker"], now: now)
        try folder.createNote(title: "B", body: "", project: "p", tags: ["cli"], now: now)
        try folder.createTodo(title: "T", project: "p", now: now)
        let done = try folder.createTodo(title: "U", project: "p", now: now)
        try folder.setStatus(.done, of: done, now: now)
        try folder.createSkill(name: "s", description: "", body: "", project: "q", now: now)
        let library = try KnowledgeLibrary(folder: folder)
        try await library.refresh()
        #expect(try library.index.tags().map(\.tag) == ["cli", "docker"])
        #expect(try library.index.openTodoCounts() == ["p": 1])
        #expect(try library.index.paths(of: .skill) == ["q/skills/s/SKILL.md"])
    }
}
