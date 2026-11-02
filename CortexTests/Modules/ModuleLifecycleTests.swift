import Foundation
import Testing
@testable import Cortex
import CortexCore

/// Every real module started, switched off and on again: nothing it began
/// keeps running while it is off, and starting again does not double up.
@MainActor
@Suite struct ModuleLifecycleTests {
    let suiteName = "CortexTests-\(UUID().uuidString)"
    let palette = FakePaletteHost()

    func host() throws -> ModuleHost {
        let services = ModuleServices(
            database: try makeTestDatabase(), defaults: UserDefaults(suiteName: suiteName)!, secrets: MemorySecrets())
        services.palette = palette
        return ModuleHost(ModuleList.all, services: services, registerHotkey: { _ in }, setHotkeyEnabled: { _, _ in })
    }

    func tearDown() {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
    }

    /// Off, on, off and on again.
    func cycle(_ id: ModuleID, in host: ModuleHost, check: (_ isOn: Bool) async throws -> Void) async throws {
        try await check(true)
        await host.setEnabled(id, false).value
        try await check(false)
        await host.setEnabled(id, true).value
        try await check(true)
    }

    @Test func clipboardStopsRecordingAndPurging() async throws {
        let host = try host()
        defer { tearDown() }
        await host.start()
        let service = try #require(host.module(ClipboardModule.self)?.service)
        try await cycle("clipboard", in: host) { isOn in
            #expect(service.isRunning == isOn)
            #expect(await service.isRecording() == isOn)
        }
    }

    @Test func snippetsStopTheKeywordTap() async throws {
        UserDefaults(suiteName: suiteName)!.set(true, forKey: "snippetKeywordExpansion")
        let host = try host()
        defer { tearDown() }
        await host.start()
        let module = try #require(host.module(SnippetsModule.self))
        var tasks: [ModuleTask] = []
        try await cycle("snippets", in: host) { isOn in
            if isOn {
                let task = try #require(module.keywordExpansion)
                #expect(!task.isCancelled)
                tasks.append(task)
            } else {
                #expect(module.keywordExpansion == nil)
                #expect(!module.expander.isRunning)
                #expect(tasks.allSatisfy { $0.isCancelled })
            }
        }
        #expect(tasks.count == 2 && tasks[0] !== tasks[1])
    }

    @Test func readingListStopsPurgingAndDropsWhatItLoaded() async throws {
        let host = try host()
        defer { tearDown() }
        await host.start()
        let module = try #require(host.module(ReadingListModule.self))
        let service = try #require(module.service)
        let scope = try #require(module.palette as? ReadingListScope)
        try await service.add(url: "https://example.com/a")
        try await cycle("reading-list", in: host) { isOn in
            #expect(service.isRunning == isOn)
            if isOn {
                scope.search("")
                await scope.loaded()
                #expect(!scope.list.isEmpty)
            } else {
                #expect(scope.list.isEmpty)
                #expect(!host.paletteRoutes.contains { $0.id == "reading-list" })
            }
        }
    }

    @Test func actionsStopWatchingTheFolderAndRefuseIntents() async throws {
        let host = try host()
        defer { tearDown() }
        await host.start()
        let service = try #require(host.module(ActionsModule.self)?.service)
        try await cycle("actions", in: host) { isOn in
            #expect(service.isRunning == isOn)
            #expect(service.isWatching == isOn)
        }
        await host.setEnabled("actions", false).value
        await #expect(throws: QuickActionError.self) {
            try await service.runForIntent(actionID: "upper", input: .text("x"))
        }
    }

    @Test func createSnippetFollowsTheSnippetsSwitch() async throws {
        let host = try host()
        defer { tearDown() }
        await host.start()
        let actions = try #require(host.module(ActionsModule.self)?.service)
        func offersCreateSnippet() -> Bool { actions.allActions.contains { $0.id == TextAction.createSnippetID } }
        #expect(offersCreateSnippet())
        await host.setEnabled("snippets", false).value
        #expect(!offersCreateSnippet())
        await host.setEnabled("snippets", true).value
        #expect(offersCreateSnippet())
    }

    @Test func aiActionsFollowTheAISwitch() async throws {
        let host = try host()
        defer { tearDown() }
        await host.start()
        let actions = try #require(host.module(ActionsModule.self)?.service)
        func offersAI() -> Bool { actions.allActions.contains { $0.id == "ai.proofread" } }
        #expect(!offersAI(), "off by default")
        await host.setEnabled("ai", true).value
        #expect(offersAI())
        #expect(actions.shortcutActions.contains { $0.id == "ai.summarize" })
        await host.setEnabled("actions", false).value
        #expect(!host.isActive("ai"), "needs Quick Actions")
        await host.setEnabled("actions", true).value
        #expect(offersAI())
        await host.setEnabled("ai", false).value
        #expect(!offersAI())
    }

    @Test func aiCommandsFollowTheAISwitch() async throws {
        let host = try host()
        defer { tearDown() }
        await host.start()
        let scope = try #require(host.module(CommandsModule.self)?.palette as? CommandsScope)
        func offersAsk() -> Bool {
            scope.search("ask")
            return scope.list.items.contains { $0.id == "ai.ask" }
        }
        #expect(!offersAsk(), "off by default")
        await host.setEnabled("ai", true).value
        #expect(offersAsk())
        await host.setEnabled("ai", false).value
        #expect(!offersAsk())
    }

    @Test func colorCommandFollowsTheColorPickerSwitch() async throws {
        let host = try host()
        defer { tearDown() }
        await host.start()
        let scope = try #require(host.module(CommandsModule.self)?.palette as? CommandsScope)
        func offersColor() -> Bool {
            scope.search("color")
            return scope.list.items.contains { $0.id == "command.color" }
        }
        #expect(offersColor(), "on by default")
        await host.setEnabled("color-picker", false).value
        #expect(!offersColor())
        await host.setEnabled("color-picker", true).value
        #expect(offersColor())
    }

    @Test func commandsNeedQuickActionsAndDropWhatTheyLoaded() async throws {
        let host = try host()
        defer { tearDown() }
        await host.start()
        let scope = try #require(host.module(CommandsModule.self)?.palette as? CommandsScope)
        scope.search("port 3000")
        #expect(!scope.list.isEmpty)
        await host.setEnabled("actions", false).value
        #expect(!host.isActive("commands"), "needs Quick Actions")
        #expect(scope.list.isEmpty)
        await host.setEnabled("actions", true).value
        #expect(host.isActive("commands"))
        scope.search("port")
        #expect(scope.list.selected?.id == "command.port")
    }

    @Test func scrollingStopsItsTap() async throws {
        let host = try host()
        defer { tearDown() }
        await host.setEnabled("scrolling", true).value
        await host.start()
        let module = try #require(host.module(ScrollingModule.self))
        try await cycle("scrolling", in: host) { isOn in
            #expect((module.reversal?.isCancelled == false) == isOn)
            if !isOn { #expect(!module.reverser.isRunning) }
        }
    }

    @Test func syncStopsItsCycles() async throws {
        let host = try host()
        defer { tearDown() }
        await host.start()
        #expect(!host.isActive("sync"), "off by default")
        await host.setEnabled("sync", true).value
        let service = try #require(host.module(SyncModule.self)?.service)
        try await cycle("sync", in: host) { isOn in
            #expect(service.isRunning == isOn)
            if !isOn { #expect(service.status == .off) }
        }
    }

    @Test func syncCarriesWhatTheActiveModulesContribute() async throws {
        let host = try host()
        defer { tearDown() }
        await host.setEnabled("sync", true).value
        await host.start()
        let service = try #require(host.module(SyncModule.self)?.service)
        #expect(service.contributions.map(\.collection) == [.clip, .snippet, .reading, .knowledge, .action])
        await host.setEnabled("snippets", false).value
        #expect(service.contributions.map(\.collection) == [.clip, .reading, .knowledge, .action])
        await host.setEnabled("clipboard", false).value
        await host.setEnabled("reading-list", false).value
        await host.setEnabled("knowledge", false).value
        await host.setEnabled("actions", false).value
        #expect(service.contributions.isEmpty)
    }

    @Test func syncReadsTheOldSwitchUntilItsOwnIsSet() throws {
        UserDefaults(suiteName: suiteName)!.set(true, forKey: "syncEnabled")
        UserDefaults(suiteName: suiteName)!.set(true, forKey: "scrollReversal")
        let host = try host()
        defer { tearDown() }
        #expect(host.isEnabled("sync") && host.isEnabled("scrolling"))
    }

    @Test func glyphModulesDropWhatTheyLoaded() async throws {
        let host = try host()
        defer { tearDown() }
        await host.start()
        let emoji = try #require(host.modules.first { $0 is EmojiModule }?.palette as? EmojiScope)
        emoji.search("smile")
        await emoji.loaded()
        #expect(!emoji.grid.isEmpty)
        await host.setEnabled("emoji", false).value
        #expect(emoji.grid.isEmpty)
        #expect(!host.paletteRoutes.contains { $0.id == "emoji" })
    }

    @Test func clipboardOffLeavesThePaletteWithoutADefault() async throws {
        let host = try host()
        defer { tearDown() }
        await host.start()
        await host.setEnabled("clipboard", false).value
        let model = PaletteModel(routes: host.paletteRoutes)
        #expect(model.activeScope == nil, "the landing view lists the triggers")
        #expect(model.placeholder == "Search ;snippets · +reading · ?notes · !todos · >actions · $cmd · :emoji · =calc · ::symbols")
    }

    @Test func calculatorDropsItsResults() async throws {
        let host = try host()
        defer { tearDown() }
        await host.start()
        let scope = try #require(host.module(CalculatorModule.self)?.palette as? CalculatorScope)
        scope.search("2+2")
        #expect(!scope.list.isEmpty)
        await host.setEnabled("calculator", false).value
        #expect(scope.list.isEmpty)
        #expect(!host.paletteRoutes.contains { $0.id == "calculator" })
        await host.setEnabled("calculator", true).value
        #expect(host.paletteRoutes.contains { $0.id == "calculator" })
    }

    @Test func knowledgeStopsWatchingItsFolder() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "CortexKnowledge-\(UUID().uuidString)", directoryHint: .isDirectory)
        UserDefaults(suiteName: suiteName)!.set(folder.path(percentEncoded: false), forKey: "knowledge.folder")
        UserDefaults(suiteName: suiteName)!.set(false, forKey: "knowledge.keepHistory")
        let host = try host()
        defer {
            tearDown()
            try? FileManager.default.removeItem(at: folder)
        }
        await host.start()
        let module = try #require(host.module(KnowledgeModule.self))
        #expect(module.service.folder.root == folder)
        let scope = try #require(module.palette as? KnowledgeScope)
        try await cycle("knowledge", in: host) { isOn in
            #expect(module.service.isWatching == isOn)
            if isOn {
                scope.search("")
                await scope.loaded()
                #expect(!scope.list.isEmpty, "the inbox")
            } else {
                #expect(scope.list.isEmpty)
            }
        }
    }
}
