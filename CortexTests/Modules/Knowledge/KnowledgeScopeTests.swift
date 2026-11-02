import Foundation
import Testing
@testable import Cortex
import CortexCore

/// The palette's `?` scope over a knowledge folder in a temporary
/// directory: listing, searching, pasting, code blocks, capturing, deleting
/// and opening files.
@MainActor
@Suite struct KnowledgeScopeTests {
    let suiteName = "CortexTests-\(UUID().uuidString)"
    let palette = FakePaletteHost()
    let root: URL
    let service: KnowledgeService
    var folder: KnowledgeFolder { service.folder }

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "CortexKnowledge-\(UUID().uuidString)", directoryHint: .isDirectory)
        let store = UserDefaults(suiteName: suiteName)!
        store.set(root.path(percentEncoded: false), forKey: "knowledge.folder")
        store.set(false, forKey: "knowledge.keepHistory")
        service = KnowledgeService(settings: KnowledgeSettings(defaults: ModuleDefaults(id: "knowledge", store: store)))
        try service.folder.write("---\nname: Server config\nsummary: The home server\n---\n", to: "server-config/README.md")
        try service.folder.write("""
            ---
            title: Convert a PNG to an SVG with potrace
            tags: [images, cli]
            ---
            potrace only reads bitmaps, so convert first:

            ```sh
            magick input.png input.pbm
            ```

            ```sh
            potrace input.pbm -s -o output.svg
            ```
            """, to: "inbox/notes/2026-10-22-potrace.md")
        try service.folder.write("---\ntitle: Docker on a new server\ntags: [docker]\n---\nInstall docker.", to: "server-config/notes/docker.md")
    }

    func scope(clipboard: String? = nil, browse: @escaping @MainActor (String?) -> Void = { _ in }) async -> KnowledgeScope {
        await service.start()
        let palette = palette
        let scope = KnowledgeScope(
            service: service, moduleID: "knowledge", clipboardText: { clipboard }, palette: { palette }, browse: browse)
        service.onChange = { scope.knowledgeDidChange() }
        return scope
    }

    func rows(_ scope: KnowledgeScope, _ query: String) async -> [KnowledgeRow] {
        scope.search(query)
        await scope.loaded()
        return scope.list.items
    }

    func tearDown() {
        service.stop()
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
    }

    func press(_ combo: KeyCombo, in scope: KnowledgeScope) -> Bool? {
        scope.keys.first { $0.combo == combo }?.perform?()
    }

    @Test func listsProjectsThenRecentItems() async throws {
        let scope = await scope()
        defer { tearDown() }
        let rows = await rows(scope, "")
        #expect(rows.map(\.id) == [
            "project:inbox", "project:server-config",
            "item:server-config/notes/docker.md", "item:inbox/notes/2026-10-22-potrace.md",
        ] || rows.map(\.id) == [
            "project:inbox", "project:server-config",
            "item:inbox/notes/2026-10-22-potrace.md", "item:server-config/notes/docker.md",
        ])
        guard case .project(let server, let count) = rows[1] else { Issue.record("not a project"); return }
        #expect(server.name == "Server config")
        #expect(count == 1)
    }

    @Test func searchesAndPastesTheBody() async throws {
        let scope = await scope()
        defer { tearDown() }
        let rows = await rows(scope, "potrace")
        #expect(rows.map(\.id) == ["item:inbox/notes/2026-10-22-potrace.md"])
        #expect(scope.activationHints.map(\.label) == ["Paste", "Copy", "Paste code block"])
        #expect(scope.activate(.primary, target: .selected))
        let delivery = try #require(palette.deliveries.last)
        #expect(delivery.content?.text?.hasPrefix("potrace only reads bitmaps") == true)
        #expect(delivery.content?.text?.contains("---") == false, "no front matter")
        #expect(delivery.action == .paste(.plainText))

        #expect(scope.activate(.option, target: .selected))
        #expect(palette.deliveries.last?.action == .copyOnly)
    }

    @Test func commandDigitsPasteCodeBlocks() async throws {
        let scope = await scope()
        defer { tearDown() }
        _ = await rows(scope, "potrace")
        #expect(scope.codeBlocks.count == 2)
        #expect(scope.activate(.primary, target: .position(1)))
        #expect(palette.deliveries.last?.content?.text == "potrace input.pbm -s -o output.svg")
        #expect(!scope.activate(.primary, target: .position(2)), "no third block")
    }

    @Test func narrowsToAProject() async throws {
        let scope = await scope()
        defer { tearDown() }
        #expect(await rows(scope, "@server").map(\.id) == ["item:server-config/notes/docker.md"])
        #expect(await rows(scope, "@inbox docker").map(\.id).allSatisfy { $0.hasPrefix("capture:") })

        let projects = await rows(scope, "")
        scope.list.select(projects[1].id)
        #expect(scope.activationHints.map(\.label) == ["Search in project"])
        #expect(scope.activate(.primary, target: .selected))
        #expect(palette.searches.last == "@server-config ")
    }

    @Test func offersToCreateAProjectThatDoesNotExist() async throws {
        let scope = await scope()
        defer { tearDown() }
        #expect(await rows(scope, "@serv").allSatisfy { !$0.id.hasPrefix("new-project:") }, "an existing one")
        #expect(await rows(scope, "@!!!").isEmpty, "nothing to name a folder after")

        let rows = await rows(scope, "@homelab")
        #expect(rows.map(\.id) == ["new-project:homelab"])
        guard case .newProject(let project) = rows[0] else { Issue.record("not a new project"); return }
        #expect(project == NewProject(name: "Homelab", id: "homelab", query: "@homelab "))
        #expect(scope.activationHints.map(\.label) == ["Create project"])

        #expect(scope.activate(.primary, target: .selected))
        try await waitUntil { palette.searches.last == "@homelab " }
        let readme = try #require(try folder.item(at: "homelab/README.md"))
        #expect(readme.kind == .project && readme.title == "Homelab")
        #expect(service.projects.contains { $0.id == "homelab" && $0.name == "Homelab" })
        #expect(await self.rows(scope, "@homelab").isEmpty, "now it names the project")
    }

    @Test func aNewProjectKeepsTheTypedNameAndTheRestOfTheQuery() async throws {
        let scope = await scope()
        defer { tearDown() }
        let rows = await rows(scope, "fix the nas #hw @HomeLab-NAS")
        #expect(rows.map(\.id) == ["new-project:homelab-nas", "capture:text"])
        guard case .newProject(let project) = rows[0] else { Issue.record("not a new project"); return }
        #expect(project.name == "HomeLab NAS")

        #expect(scope.activate(.primary, target: .selected))
        try await waitUntil { palette.searches.last == "@homelab-nas fix the nas #hw" }
        // The capture now goes into the new project.
        let captures = await self.rows(scope, "@homelab-nas fix the nas #hw")
        guard case .capture(let capture) = captures.first else { Issue.record("no capture"); return }
        #expect(capture.project == "homelab-nas")
    }

    @Test func capturesWhatWasTyped() async throws {
        let scope = await scope(clipboard: "magick convert first")
        defer { tearDown() }
        let rows = await rows(scope, "nothing like this #cli @server")
        #expect(rows.map(\.id) == ["capture:text", "capture:clipboard"])
        guard case .capture(let capture) = rows[1] else { Issue.record("not a capture"); return }
        #expect(capture.title == "nothing like this")
        #expect(capture.project == "server-config", "the one project @server names")
        #expect(capture.tags == ["cli"])

        scope.list.select(rows[1].id)
        #expect(scope.activationHints.map(\.label) == ["Save"])
        #expect(scope.activate(.primary, target: .selected))
        #expect(palette.closes == 1)
        try await waitUntil { folder.exists("server-config/notes/nothing-like-this.md") }
        let item = try #require(try folder.item(at: "server-config/notes/nothing-like-this.md"))
        #expect(item.title == "nothing like this")
        #expect(item.body == "magick convert first\n")
        #expect(item.tags == ["cli"])
    }

    @Test func capturesIntoTheInboxWithTheDate() async throws {
        let scope = await scope()
        defer { tearDown() }
        let rows = await rows(scope, "Fix the backup")
        #expect(rows.map(\.id) == ["capture:text"], "no clipboard text, no second row")
        #expect(scope.activate(.primary, target: .selected))
        let path = KnowledgeFolder.notePath(project: "inbox", title: "Fix the backup", date: .now)
        try await waitUntil { folder.exists(path) }
        #expect(try folder.item(at: path)?.body == "")
    }

    @Test func asksBeforeSavingASecret() async throws {
        let scope = await scope(clipboard: "-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW\n-----END OPENSSH PRIVATE KEY-----")
        defer { tearDown() }
        let rows = await rows(scope, "my key")
        guard case .capture(let capture) = rows[1] else { Issue.record("not a capture"); return }
        #expect(capture.isSensitive)
        scope.list.select(rows[1].id)
        #expect(scope.activate(.primary, target: .selected))
        let overlay = try #require(palette.overlays.last)
        #expect(palette.closes == 0, "nothing saved yet")
        overlay.activate(.primary)
        let path = KnowledgeFolder.notePath(project: "inbox", title: "my key", date: .now)
        try await waitUntil { folder.exists(path) }
    }

    @Test func deletesAfterAsking() async throws {
        let scope = await scope()
        defer { tearDown() }
        _ = await rows(scope, "docker")
        #expect(press(.command(.delete), in: scope) == true)
        let overlay = try #require(palette.overlays.last)
        #expect(folder.exists("server-config/notes/docker.md"))
        overlay.activate(.primary)
        try await waitUntil { !folder.exists("server-config/notes/docker.md") }
        try await waitUntil { palette.searches.last == "docker" }
    }

    @Test func opensTheFileInAnEditor() async throws {
        let scope = await scope()
        defer { tearDown() }
        var opened: [URL] = []
        service.openFile = { opened.append($0) }
        _ = await rows(scope, "docker")
        #expect(scope.keys.contains { $0.combo == KnowledgeScope.openKey && $0.hint != nil })
        #expect(press(KnowledgeScope.openKey, in: scope) == true)
        #expect(opened == [folder.url(for: "server-config/notes/docker.md")])
        #expect(palette.closes == 1)

        _ = await rows(scope, "")
        #expect(press(KnowledgeScope.openKey, in: scope) == false, "a project: ⌘⏎ is ⏎")
    }

    @Test func browsesTheSelectedItemOrProject() async throws {
        var browsed: [String?] = []
        let scope = await scope { browsed.append($0) }
        defer { tearDown() }
        _ = await rows(scope, "docker")
        #expect(press(.command("o"), in: scope) == true)
        _ = await rows(scope, "")
        scope.list.select("project:server-config")
        #expect(press(.command("o"), in: scope) == true)
        #expect(browsed == ["server-config/notes/docker.md", "server-config/README.md"])
        #expect(palette.closes == 2)
    }

    @Test func reloadsWhenFilesChange() async throws {
        let scope = await scope()
        defer { tearDown() }
        #expect(await rows(scope, "restic").allSatisfy { $0.id.hasPrefix("capture:") })
        try folder.write("---\ntitle: Fix the restic backup\n---\n", to: "server-config/todos/restic.md")
        // The folder watcher picks the file up and the scope searches again.
        try await waitUntil { scope.list.items.first?.id == "item:server-config/todos/restic.md" }
    }

    @Test func settingsKeepTheirKeys() {
        defer { tearDown() }
        let store = UserDefaults(suiteName: suiteName)!
        #expect(service.settings.folderOverride == root.path(percentEncoded: false), "knowledge.folder")
        service.settings.keepHistory = true
        #expect(store.object(forKey: "knowledge.keepHistory") as? Bool == true)
        #expect(KnowledgeSettings(defaults: ModuleDefaults(id: "knowledge", store: store)).keepHistory)
        service.settings.linkSkills = false
        #expect(store.object(forKey: "knowledge.linkSkills") as? Bool == false)
        #expect(!KnowledgeSettings(defaults: ModuleDefaults(id: "knowledge", store: store)).linkSkills)
    }

    @Test func historyCommitsTheFolder() async throws {
        guard await KnowledgeHistory.isGitAvailable() else { return }
        defer { tearDown() }
        service.settings.keepHistory = true
        await service.start()
        let history = KnowledgeHistory(folder: root)
        #expect(history.isRepository, "made at start")
        #expect(try await history.commitAll() == nil, "the existing files were committed at start")

        service.commitDelay = .milliseconds(50)
        try await service.capture(KnowledgeCapture(title: "New", body: "", project: "inbox", tags: [], fromClipboard: false, isSensitive: false))
        try await waitUntil {
            let result = try? await ProcessRunner.run(URL(filePath: "/usr/bin/git"), arguments: ["-C", root.path(percentEncoded: false), "log", "--format=%s"])
            return result?.outputText.hasPrefix("Add inbox/notes/") == true
        }
    }
}

/// Polls until `condition` holds, for work that happens in a task or on a
/// file system event.
@MainActor
func waitUntil(timeout: Duration = .seconds(5), _ condition: @MainActor () async -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while !(await condition()) {
        guard ContinuousClock.now < deadline else {
            Issue.record("Timed out")
            return
        }
        try await Task.sleep(for: .milliseconds(20))
    }
}
