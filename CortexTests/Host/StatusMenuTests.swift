import AppKit
import Testing
@testable import Cortex
import CortexCore

/// The modules' groups in the status menu and the icon they ask for.
@MainActor
@Suite struct StatusMenuTests {
    let suiteName = "CortexTests-\(UUID().uuidString)"

    func host(_ types: [any CortexModule.Type]) -> ModuleHost {
        let services = ModuleServices(database: nil, defaults: UserDefaults(suiteName: suiteName)!, secrets: MemorySecrets())
        return ModuleHost(types, services: services, registerHotkey: { _ in }, setHotkeyEnabled: { _, _ in })
    }

    func tearDown() {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
    }

    // MARK: - From the modules

    @Test func groupsComeFromActiveModulesInManifestOrder() async {
        // Listed out of order on purpose: the manifest's `order` decides.
        let host = host([FakeDefault.self, FakeMenuLate.self, FakeMenuEarly.self, FakeMenuNone.self, FakeMenuOff.self])
        defer { tearDown() }
        #expect(host.statusMenuGroups.map { $0.map(\.title) } == [["Early"], ["Late", "Late too"]])
        await host.start()
        await host.setEnabled("menu-off", true).value
        #expect(host.statusMenuGroups.map { $0.map(\.title) } == [["Early"], ["Late", "Late too"], ["Off"]])
        await host.setEnabled("menu-early", false).value
        #expect(host.statusMenuGroups.map { $0.map(\.title) } == [["Late", "Late too"], ["Off"]])
    }

    @Test func theHighestPriorityIconWinsAndTiesGoToTheFirst() async {
        let host = host([FakeDefault.self, FakeMenuLate.self, FakeMenuEarly.self, FakeMenuNone.self, FakeMenuOff.self])
        defer { tearDown() }
        #expect(host.statusIcon?.accessibilityLabel == "late", "beats early's lower priority")
        await host.start()
        await host.setEnabled("menu-late", false).value
        #expect(host.statusIcon?.accessibilityLabel == "early")
        await host.setEnabled("menu-off", true).value
        #expect(host.statusIcon?.accessibilityLabel == "early", "same priority, earlier in order")
        await host.setEnabled("menu-early", false).value
        await host.setEnabled("menu-off", false).value
        #expect(host.statusIcon == nil)
    }

    // MARK: - In the menu

    func menu() -> (NSMenu, NSMenuItem, StatusMenuSection) {
        let menu = NSMenu()
        let anchor = NSMenuItem(title: "Settings…", action: nil, keyEquivalent: "")
        menu.addItem(anchor)
        menu.addItem(withTitle: "Quit", action: nil, keyEquivalent: "")
        return (menu, anchor, StatusMenuSection(in: menu, after: anchor))
    }

    func titles(_ menu: NSMenu) -> [String] {
        menu.items.map { $0.isSeparatorItem ? "---" : $0.title }
    }

    @Test func eachGroupFollowsASeparator() {
        let (menu, _, section) = menu()
        section.update([[.line("A")], [], [.line("B"), .line("C")]])
        #expect(titles(menu) == ["Settings…", "---", "A", "---", "B", "C", "Quit"])
        section.update([])
        #expect(titles(menu) == ["Settings…", "Quit"])
    }

    @Test func itemsAreUpdatedInPlace() {
        let (menu, _, section) = menu()
        section.update([[.line("Synced just now")], [StatusMenuItem("Quick Actions") {}, .line("Job – 10 %")]])
        let before = menu.items
        section.update([[.line("Synced 1 min ago")], [StatusMenuItem("Quick Actions") {}, .line("Job – 20 %")]])
        #expect(titles(menu) == ["Settings…", "---", "Synced 1 min ago", "---", "Quick Actions", "Job – 20 %", "Quit"])
        #expect(zip(before, menu.items).allSatisfy { $0 === $1 }, "same items, new titles")

        // A job ends: the group shrinks, the rest stays.
        section.update([[.line("Synced 1 min ago")], [StatusMenuItem("Quick Actions") {}]])
        #expect(titles(menu) == ["Settings…", "---", "Synced 1 min ago", "---", "Quick Actions", "Quit"])
        #expect(menu.items[4] === before[4])

        // The first group goes: separators and items swap places.
        section.update([[StatusMenuItem("Quick Actions") {}, .line("Job – 30 %")]])
        #expect(titles(menu) == ["Settings…", "---", "Quick Actions", "Job – 30 %", "Quit"])
        #expect(section.items.count == 3)
    }

    @Test func itemsCarryStateAndRunTheirAction() throws {
        let (menu, _, section) = menu()
        var chosen = 0
        section.update([[
            StatusMenuItem("Pause Recording", state: .on, image: "pause") { chosen += 1 },
            StatusMenuItem("Sync Now", isEnabled: false) {},
            .line("Synced just now"),
        ]])
        let pause = try #require(menu.items[2] as? ModuleMenuItem)
        #expect(pause.state == .on && pause.isEnabled && pause.image != nil)
        #expect(!menu.items[3].isEnabled, "the module said so")
        #expect(!menu.items[4].isEnabled && menu.items[4].action == nil, "a line to read")
        menu.performActionForItem(at: 2)
        #expect(chosen == 1)

        section.update([[StatusMenuItem("Pause Recording") { chosen += 10 }, .line("Sync Now"), .line("x")]])
        #expect(pause.state == .off && pause.image == nil)
        menu.performActionForItem(at: 2)
        #expect(chosen == 11, "the new action")
    }
}

// MARK: - Fakes

private func icon(_ label: String, priority: Int) -> StatusIcon {
    StatusIcon(image: NSImage(), accessibilityLabel: label, priority: priority)
}

final class FakeMenuEarly: FakeModule, CortexModule {
    static let manifest = ModuleManifest(id: "menu-early", name: "Early", summary: "", symbol: "circle", order: 10)
    func statusMenuItems() -> [StatusMenuItem] { [.line("Early")] }
    var statusIcon: StatusIcon? { icon("early", priority: 0) }
}

final class FakeMenuLate: FakeModule, CortexModule {
    static let manifest = ModuleManifest(id: "menu-late", name: "Late", summary: "", symbol: "circle", order: 30)
    func statusMenuItems() -> [StatusMenuItem] { [.line("Late"), StatusMenuItem("Late too") {}] }
    var statusIcon: StatusIcon? { icon("late", priority: 5) }
}

final class FakeMenuNone: FakeModule, CortexModule {
    static let manifest = ModuleManifest(id: "menu-none", name: "None", summary: "", symbol: "circle", order: 20)
}

final class FakeMenuOff: FakeModule, CortexModule {
    static let manifest = ModuleManifest(
        id: "menu-off", name: "Off", summary: "", symbol: "circle", enabledByDefault: false, order: 40)
    func statusMenuItems() -> [StatusMenuItem] { [.line("Off")] }
    var statusIcon: StatusIcon? { icon("off", priority: 0) }
}
