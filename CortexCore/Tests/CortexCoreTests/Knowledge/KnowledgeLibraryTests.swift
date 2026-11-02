import Foundation
import Testing
@testable import CortexCore

/// A knowledge folder in a fresh temporary directory.
func makeKnowledgeFolder() throws -> KnowledgeFolder {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "CortexKnowledgeTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return KnowledgeFolder(root: root)
}

@Suite struct KnowledgeLibraryTests {
    let folder: KnowledgeFolder
    let library: KnowledgeLibrary

    init() throws {
        folder = try makeKnowledgeFolder()
        library = try KnowledgeLibrary(folder: folder)
    }

    func write(_ path: String, _ text: String) throws {
        try folder.write(text, to: path)
    }

    func titles(_ query: String) throws -> [String] {
        try library.index.search(KnowledgeQuery.parse(query)).map(\.item.title)
    }

    func fill() throws {
        try write("server-config/README.md", "---\nname: Server config\nsummary: The home server\n---\nAbout it.")
        try write("server-config/notes/docker-on-a-new-server.md", """
            ---
            title: Docker on a new server
            tags: [docker, setup]
            updated: 2026-10-20T10:00:00Z
            ---
            Install docker with the convenience script, then add the user to the group.
            """)
        try write("server-config/notes/copy-a-docker-volume.md", """
            ---
            title: Copy a Docker volume
            tags: [docker]
            updated: 2026-10-21T10:00:00Z
            ---
            Use a throwaway container that mounts both volumes.
            """)
        try write("server-config/skills/deploy-with-ansible/SKILL.md", """
            ---
            name: deploy-with-ansible
            description: Deploy a compose file to the server with Ansible
            ---
            1. Push the compose file.
            """)
        try write("server-config/todos/fix-restic-backup.md", "---\ntitle: Fix the restic backup\nstatus: open\ntags: [backup]\n---\n- [ ] rotate the key")
        try write("inbox/notes/2026-10-22-potrace.md", """
            ---
            title: Convert a PNG to an SVG with potrace
            tags: [images, cli]
            updated: 2026-10-22T10:00:00Z
            ---
            potrace only reads bitmaps, so convert first with magick.
            """)
        try write("cortex/notes/réglages.md", "# Réglages des Mac\n\nNothing about servers here.")
        try write("cortex/assets/notes.md", "an asset, not a note")
        try write(".conflicts/inbox/notes/2026-10-22-potrace.md", "potrace conflict")
        try write("inbox/notes/.draft.md", "hidden")
    }

    @Test func indexesTheFolder() async throws {
        try fill()
        let changes = try await library.refresh()
        #expect(changes.updated.count == 7)
        #expect(try library.index.count() == 7)
        #expect(try library.index.projects().map(\.id) == ["inbox", "cortex", "server-config"], "the inbox first, then by name")
        #expect(try library.index.projects().last?.summary == "The home server")
        #expect(try library.index.counts() == ["server-config": 4, "inbox": 1, "cortex": 1])
    }

    @Test func searchesTitlesTagsAndBodies() async throws {
        try fill()
        try await library.refresh()
        #expect(try titles("potrace") == ["Convert a PNG to an SVG with potrace"])
        #expect(try titles("dock").first == "Copy a Docker volume" || titles("dock").first == "Docker on a new server")
        #expect(Set(try titles("docker")) == ["Docker on a new server", "Copy a Docker volume"])
        #expect(try titles("throwaway cont") == ["Copy a Docker volume"], "every word as a prefix")
        #expect(try titles("reglages") == ["Réglages des Mac"], "accents do not matter")
        #expect(try titles("ansible") == ["deploy-with-ansible"], "the skill's description")
        #expect(try titles("home") == ["Server config"], "the project's README")
        #expect(try titles("nothingmatches").isEmpty)
        #expect(try titles("conflict").isEmpty, "dot folders are not indexed")
    }

    @Test func titlesRankAboveBodies() async throws {
        try write("p/notes/a.md", "---\ntitle: Something else\n---\nrestic restic restic restic")
        try write("p/notes/b.md", "---\ntitle: Restic\n---\nUnrelated text.")
        try await library.refresh()
        #expect(try titles("restic") == ["Restic", "Something else"])
    }

    @Test func filtersByProjectAndTag() async throws {
        try fill()
        try await library.refresh()
        #expect(Set(try titles("@server docker")) == ["Docker on a new server", "Copy a Docker volume"])
        #expect(try titles("@inbox docker").isEmpty)
        #expect(try titles("@Server docker").count == 2, "by name, any case")
        #expect(try titles("@nope docker").isEmpty)
        #expect(try titles("#setup") == ["Docker on a new server"])
        #expect(try titles("#dock").count == 2, "a tag prefix")
        #expect(try titles("docker #setup") == ["Docker on a new server"])
        #expect(try titles("@server #backup") == ["Fix the restic backup"])
        let snippet = try library.index.search(.parse("throwaway")).first?.snippet
        #expect(snippet?.contains("throwaway container") == true)
    }

    @Test func listsByDateWithoutWords() async throws {
        try fill()
        try await library.refresh()
        let recent = try library.index.search(KnowledgeQuery(kinds: [.note, .skill, .todo]), limit: 3).map(\.item)
        #expect(recent.count == 3)
        #expect(recent.map(\.updated) == recent.map(\.updated).sorted(by: >), "newest first")
        #expect(!recent.contains { $0.kind == .project })
        let notes = try library.index.search(KnowledgeQuery(project: "server", kinds: [.note])).map(\.item.title)
        #expect(notes == ["Copy a Docker volume", "Docker on a new server"])
        let open = try library.index.search(KnowledgeQuery(status: .open)).map(\.item.title)
        #expect(open == ["Fix the restic backup"])
    }

    @Test func refreshReadsOnlyWhatChanged() async throws {
        try fill()
        try await library.refresh()
        #expect(try await library.refresh().isEmpty)

        try write("inbox/notes/2026-10-22-potrace.md", "---\ntitle: Potrace, rewritten\n---\nNew body about inkscape.")
        try FileManager.default.removeItem(at: folder.url(for: "cortex/notes/réglages.md"))
        try write("cortex/README.md", "---\nname: Cortex app\n---\n")
        let changes = try await library.refresh()
        #expect(changes.updated == ["cortex/README.md", "inbox/notes/2026-10-22-potrace.md"])
        #expect(changes.removed == ["cortex/notes/réglages.md"])
        #expect(try titles("inkscape") == ["Potrace, rewritten"])
        #expect(try titles("potrace") == ["Potrace, rewritten"])
        #expect(try titles("reglages").isEmpty)
        #expect(try library.index.projects().map(\.name) == ["Inbox", "Cortex app", "Server config"])
    }

    @Test func capturesNotes() async throws {
        let now = Date(timeIntervalSince1970: 1_761_127_920)
        let utc = TimeZone(identifier: "UTC")!
        #expect(KnowledgeFolder.notePath(project: "inbox", title: "Fix: the backup!", date: now, timeZone: utc) == "inbox/notes/2025-10-22-fix-the-backup.md")
        #expect(KnowledgeFolder.notePath(project: "server", title: "Docker", date: now) == "server/notes/docker.md")

        let first = try folder.createNote(title: "Docker", body: "\n\nBody\n\n", project: "server", tags: ["#Setup"], now: now)
        let second = try folder.createNote(title: "Docker", body: "", project: "server", now: now)
        #expect(first == "server/notes/docker.md")
        #expect(second == "server/notes/docker-2.md")
        #expect(try folder.text(at: first) == """
            ---
            title: Docker
            tags: [setup]
            created: 2025-10-22T10:12:00Z
            updated: 2025-10-22T10:12:00Z
            ---
            Body

            """)
        let item = try #require(try folder.item(at: second))
        #expect(item.title == "Docker")
        #expect(item.body.isEmpty)

        try folder.prepare()
        try folder.write("x", to: "p/skills/s/SKILL.md")
        try folder.write("y", to: "p/skills/s/extra.txt")
        try folder.delete("p/skills/s/SKILL.md")
        #expect(!folder.exists("p/skills/s/extra.txt"), "a skill goes with its folder")
        try folder.delete(first)
        #expect(!folder.exists(first))
        #expect(folder.exists("inbox"))
    }

    @Test func savesProjects() async throws {
        let now = Date(timeIntervalSince1970: 1_761_127_920)
        let path = try folder.saveProject(
            KnowledgeProject(id: "server", name: "Server", summary: " ", symbol: "server.rack", color: .teal, folders: ["~/a", ""]),
            now: now)
        #expect(path == "server/README.md")
        #expect(try folder.text(at: path) == """
            ---
            name: Server
            symbol: server.rack
            color: teal
            folders: [~/a]
            ---

            """)

        try folder.write("---\ntitle: Old\nowner: me\ncolor: red\n---\nAbout it.\n", to: path)
        try folder.saveProject(KnowledgeProject(id: "server", name: "Home server", summary: "The box"), now: now)
        #expect(try folder.text(at: path) == """
            ---
            owner: me
            name: Home server
            summary: The box
            updated: 2025-10-22T10:12:00Z
            ---
            About it.

            """, "other keys and the text stay, empty ones go")

        _ = try await library.refresh()
        let project = try #require(try library.index.projects().first { $0.id == "server" })
        #expect(project.name == "Home server")
        #expect(project.color == nil)
        try folder.saveProject(KnowledgeProject(id: "server", name: "Home server", color: .indigo), now: now)
        _ = try await library.refresh()
        #expect(try library.index.projects().first { $0.id == "server" }?.color == .indigo, "the index keeps the colour")
    }

    @Test func defaultDirectoryIsNextToTheActions() {
        #expect(KnowledgeFolder.defaultDirectory(environment: ["XDG_CONFIG_HOME": "/tmp/config"]).path == "/tmp/config/cortex/knowledge")
    }

    @Test func parsesQueries() {
        #expect(KnowledgeQuery.parse("@server docker #CLI #") == KnowledgeQuery(text: "docker", project: "server", tags: ["cli"]))
        #expect(KnowledgeQuery.parse("@ docker") == KnowledgeQuery(text: "docker"))
        #expect(!KnowledgeQuery.parse("@server").hasText)
    }
}
