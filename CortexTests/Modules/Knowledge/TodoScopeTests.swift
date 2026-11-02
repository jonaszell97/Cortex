import Foundation
import Testing
@testable import Cortex
import CortexCore

/// The palette's `!` scope over a knowledge folder in a temporary
/// directory: the list and its order, adding, closing and reopening,
/// ticking the checklist, editing and deleting.
@MainActor
@Suite struct TodoScopeTests {
    let suiteName = "CortexTests-\(UUID().uuidString)"
    let palette = FakePaletteHost()
    let root: URL
    let service: KnowledgeService
    var folder: KnowledgeFolder { service.folder }

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "CortexTodos-\(UUID().uuidString)", directoryHint: .isDirectory)
        let store = UserDefaults(suiteName: suiteName)!
        store.set(root.path(percentEncoded: false), forKey: "knowledge.folder")
        store.set(false, forKey: "knowledge.keepHistory")
        service = KnowledgeService(settings: KnowledgeSettings(defaults: ModuleDefaults(id: "knowledge", store: store)))
        try folder.write("---\nname: Server config\n---\n", to: "server-config/README.md")
        try folder.write("""
            ---
            title: Fix the restic backup
            status: open
            tags: [backup]
            created: 2026-10-20T10:00:00Z
            ---
            The nightly run fails.

            - [x] check the cron log
            - [ ] rotate the S3 key
            - [ ] run once by hand
            """, to: "server-config/todos/fix-the-restic-backup.md")
        try folder.write("---\ntitle: Call Anna\nstatus: open\ncreated: 2026-10-21T10:00:00Z\n---\n", to: "inbox/todos/2026-10-21-call-anna.md")
        try folder.write("---\ntitle: Renew the domain\nstatus: open\ndue: 2026-11-01\ncreated: 2026-10-01T10:00:00Z\n---\n", to: "server-config/todos/renew.md")
        try folder.write("---\ntitle: Install Tailscale\nstatus: done\ndone: 2026-10-01T10:00:00Z\n---\n", to: "server-config/todos/tailscale.md")
        try folder.write("---\ntitle: Backup notes\n---\nnot a to-do", to: "server-config/notes/backup.md")
    }

    func scope() async -> (TodoScope, EditRecorder) {
        await service.start()
        let palette = palette
        let recorder = EditRecorder()
        let scope = TodoScope(service: service, palette: { palette }) { recorder.paths.append($0) }
        service.onChange = { scope.knowledgeDidChange() }
        return (scope, recorder)
    }

    func rows(_ scope: TodoScope, _ query: String) async -> [TodoRow] {
        scope.search(query)
        await scope.loaded()
        return scope.list.items
    }

    func tearDown() {
        service.stop()
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
    }

    func press(_ combo: KeyCombo, in scope: TodoScope) -> Bool? {
        scope.keys.first { $0.combo == combo }?.perform?()
    }

    @Test func listsOpenTodosDueFirstThenByProject() async throws {
        let (scope, _) = await scope()
        defer { tearDown() }
        #expect(await rows(scope, "").map(\.id) == [
            "todo:server-config/todos/renew.md",
            "todo:inbox/todos/2026-10-21-call-anna.md",
            "todo:server-config/todos/fix-the-restic-backup.md",
        ])
        #expect(await rows(scope, "backup").map(\.id) == ["todo:server-config/todos/fix-the-restic-backup.md", "add"],
                "notes are not listed; the last row adds")
        #expect(await rows(scope, "done").map(\.id) == ["todo:server-config/todos/tailscale.md"], "nothing to add")
        #expect(await rows(scope, "@server").map(\.id).count == 2)
    }

    @Test func addsAndStaysOnTheList() async throws {
        let (scope, _) = await scope()
        defer { tearDown() }
        let rows = await rows(scope, "rotate the key @server #urgent")
        guard case .add(let draft) = rows.last else { Issue.record("no add row"); return }
        #expect(draft == TodoDraft(title: "rotate the key", project: "server-config", tags: ["urgent"], isSensitive: false))
        scope.list.select("add")
        #expect(scope.activationHints.map(\.label) == ["Add"])
        #expect(scope.activate(.primary, target: .selected))
        try await waitUntil { palette.searches.last == "@server-config " }
        #expect(palette.closes == 0, "the palette stays open")
        let todo = try #require(try folder.item(at: "server-config/todos/rotate-the-key.md"))
        #expect(todo.status == .open && todo.tags == ["urgent"])

        // The host searches the new query; the new to-do is selected.
        _ = await self.rows(scope, "@server-config ")
        #expect(scope.list.selected?.id == "todo:server-config/todos/rotate-the-key.md")

        _ = await self.rows(scope, "buy milk")
        scope.list.select("add")
        scope.choose(scope.list.selected!)
        try await waitUntil { palette.searches.last == "" }
        #expect(folder.itemFiles().keys.contains { $0.hasPrefix("inbox/todos/") && $0.hasSuffix("-buy-milk.md") })
    }

    @Test func commandDClosesAndReopens() async throws {
        let (scope, _) = await scope()
        defer { tearDown() }
        _ = await rows(scope, "anna")
        #expect(scope.keys.first { $0.combo == .command("d") }?.hint == "Done")
        #expect(press(.command("d"), in: scope) == true)
        try await waitUntil { scope.selectedTodo?.status == .done }
        #expect(scope.list.items.count == 2, "still listed after it was closed")
        #expect(scope.keys.first { $0.combo == .command("d") }?.hint == "Reopen")
        #expect(press(.command("d"), in: scope) == true)
        try await waitUntil { scope.selectedTodo?.status == .open }
        #expect(try folder.item(at: "inbox/todos/2026-10-21-call-anna.md")?.frontMatter["done"] == nil)

        #expect(press(.command("d"), in: scope) == true)
        try await waitUntil { scope.selectedTodo?.status == .done }
        #expect(await rows(scope, "").map(\.id).contains("todo:inbox/todos/2026-10-21-call-anna.md") == false,
                "gone once the query changed")
    }

    @Test func ticksTheChecklist() async throws {
        let (scope, recorder) = await scope()
        defer { tearDown() }
        _ = await rows(scope, "restic")
        #expect(scope.activationHints.map(\.label) == ["Checklist"])
        #expect(press(.tab, in: scope) == true)
        #expect(scope.checklistIndex == 1, "the first open item")
        #expect(scope.activationHints.map(\.label) == ["Tick"])
        scope.move(.vertical(5))
        #expect(scope.checklistIndex == 2)
        #expect(scope.activate(.primary, target: .selected))
        try await waitUntil { scope.checklist.items.last?.isDone == true }
        #expect(scope.checklistIndex == 2, "still in the checklist after the reload")
        #expect(scope.cancel())
        #expect(scope.checklistIndex == nil)
        #expect(!scope.cancel(), "a second esc closes the palette")
        #expect(recorder.paths.isEmpty)

        // Without a checklist, ⏎ edits.
        _ = await rows(scope, "anna")
        #expect(scope.activationHints.map(\.label) == ["Edit"])
        #expect(scope.activate(.primary, target: .selected))
        #expect(recorder.paths == ["inbox/todos/2026-10-21-call-anna.md"])
        #expect(palette.closes == 1)
    }

    @Test func editsOpensAndDeletes() async throws {
        let (scope, recorder) = await scope()
        defer { tearDown() }
        var opened: [URL] = []
        service.openFile = { opened.append($0) }
        _ = await rows(scope, "renew")
        #expect(press(.command("e"), in: scope) == true)
        #expect(recorder.paths == ["server-config/todos/renew.md"])
        #expect(press(KnowledgeScope.openKey, in: scope) == true)
        #expect(opened == [folder.url(for: "server-config/todos/renew.md")])

        #expect(press(.command(.delete), in: scope) == true)
        try #require(palette.overlays.last).activate(.primary)
        try await waitUntil { !folder.exists("server-config/todos/renew.md") }
    }

    @Test func asksBeforeAddingASecret() async throws {
        let (scope, _) = await scope()
        defer { tearDown() }
        _ = await rows(scope, "ghp_abcdefghijklmnopqrstuvwxyz0123456789")
        scope.list.select("add")
        #expect(scope.activate(.primary, target: .selected))
        #expect(palette.overlays.count == 1)
        #expect(!folder.itemFiles().keys.contains { $0.hasPrefix("inbox/todos/") && $0.contains("ghp") })
    }
}

@MainActor
final class EditRecorder {
    var paths: [String] = []
}
