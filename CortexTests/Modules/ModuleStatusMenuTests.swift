import Foundation
import Testing
@testable import Cortex
import CortexCore

/// What the real modules put in the status menu and the menu bar icon.
@MainActor
@Suite struct ModuleStatusMenuTests {
    let suiteName = "CortexTests-\(UUID().uuidString)"

    func host() throws -> ModuleHost {
        let services = ModuleServices(
            database: try makeTestDatabase(), defaults: UserDefaults(suiteName: suiteName)!, secrets: MemorySecrets())
        services.palette = FakePaletteHost()
        return ModuleHost(ModuleList.all, services: services, registerHotkey: { _ in }, setHotkeyEnabled: { _, _ in })
    }

    func tearDown() {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
    }

    func titles(_ host: ModuleHost) -> [[String]] {
        host.statusMenuGroups.map { $0.map(\.title) }
    }

    @Test func oneGroupPerModuleThatIsOn() async throws {
        let host = try host()
        defer { tearDown() }
        await host.start()
        #expect(titles(host) == [
            ["Pause Recording", "Clear History…"], ["Snippets…"], ["Reading List", "Add Link from Clipboard"],
            ["Browse Knowledge…", "New To-Do…", "Open Knowledge Folder"], ["Quick Actions"], ["Pick Color"],
        ])
        let quickActions = try #require(host.statusMenuGroups[4].first)
        #expect(quickActions.shortcut == .quickActions)
        let pickColor = try #require(host.statusMenuGroups.last?.first)
        #expect(pickColor.shortcut == .pickColor)

        await host.setEnabled("sync", true).value
        #expect(titles(host).count == 6, "sync is not set up: no line, no Sync Now")
        await host.setEnabled("snippets", false).value
        await host.setEnabled("reading-list", false).value
        await host.setEnabled("clipboard", false).value
        await host.setEnabled("color-picker", false).value
        await host.setEnabled("knowledge", false).value
        #expect(titles(host) == [["Quick Actions"]])
    }

    @Test func pausingRecordingChecksTheItemAndChangesTheIcon() async throws {
        let host = try host()
        defer { tearDown() }
        await host.start()
        let settings = try #require(host.module(ClipboardModule.self)?.service?.settings)
        #expect(host.statusIcon == nil)
        #expect(host.statusMenuGroups[0][0].state == .off)

        host.statusMenuGroups[0][0].action?()
        #expect(settings.isPaused)
        #expect(host.statusMenuGroups[0][0].state == .on)
        #expect(host.statusIcon?.accessibilityLabel == "Cortex (recording paused)")

        await host.setEnabled("clipboard", false).value
        #expect(host.statusIcon == nil, "only while Clipboard is on")
        settings.isPaused = false
    }
}
