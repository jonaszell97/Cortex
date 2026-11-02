import Foundation
@preconcurrency import KeyboardShortcuts
import Testing
@testable import Cortex
import CortexCore

/// Creating, checking and starting modules, and finding their APIs.
@MainActor
@Suite struct ModuleHostTests {
    let suiteName = "CortexTests-\(UUID().uuidString)"

    func services(database: AppDatabase? = nil) -> ModuleServices {
        ModuleServices(database: database, defaults: UserDefaults(suiteName: suiteName)!, secrets: MemorySecrets())
    }

    // MARK: - Manifests

    func manifest(
        _ id: ModuleID, trigger: PaletteTrigger? = nil, requirements: Set<ModuleRequirement> = []
    ) -> ModuleManifest {
        ModuleManifest(
            id: id, name: id.rawValue, summary: "", symbol: "circle", trigger: trigger,
            requirements: requirements, order: 0)
    }

    @Test func acceptsWellFormedManifests() {
        let problems = ModuleManifest.problems(in: [
            manifest("clipboard", trigger: .default),
            manifest("emoji", trigger: .prefix(":")),
            manifest("symbols", trigger: .prefix("::")),
            manifest("sync", requirements: [.database, .module("clipboard")]),
        ])
        #expect(problems.isEmpty)
    }

    @Test func reportsDuplicateIDsAndTriggers() {
        let problems = ModuleManifest.problems(in: [
            manifest("clipboard", trigger: .default),
            manifest("emoji", trigger: .prefix(":")),
            manifest("emoji"),
            manifest("smileys", trigger: .prefix(":")),
        ])
        #expect(problems == [
            "Module ID \"emoji\" is used twice",
            "Modules \"emoji\" and \"smileys\" both use the trigger \":\"",
        ])
    }

    @Test func needsExactlyOneDefault() {
        #expect(ModuleManifest.problems(in: [manifest("emoji", trigger: .prefix(":"))]) == [
            "Exactly one module must be the palette's default, not none",
        ])
        #expect(ModuleManifest.problems(in: [manifest("a", trigger: .default), manifest("b", trigger: .default)]) == [
            "Exactly one module must be the palette's default, not \"a\", \"b\"",
        ])
    }

    @Test func reportsMalformedIDsEmptyTriggersAndUnknownRequirements() {
        let problems = ModuleManifest.problems(in: [
            manifest("clipboard", trigger: .default),
            manifest("Quick.Actions"),
            manifest("emoji", trigger: .prefix("")),
            manifest("sync", requirements: [.module("cloud")]),
            manifest("loop", requirements: [.module("loop")]),
        ])
        #expect(problems == [
            "Module ID \"Quick.Actions\" is not lowercase letters, digits and hyphens",
            "Module \"emoji\" has an empty trigger",
            "Module \"sync\" requires the unknown module \"cloud\"",
            "Module \"loop\" requires itself",
        ])
    }

    @Test func checksSubscopes() {
        func withSubscopes(_ id: ModuleID, _ subscopes: [PaletteSubscope]) -> ModuleManifest {
            ModuleManifest(id: id, name: id.rawValue, summary: "", symbol: "circle", trigger: .prefix("?"), subscopes: subscopes, order: 0)
        }
        let problems = ModuleManifest.problems(in: [
            manifest("clipboard", trigger: .default),
            manifest("emoji", trigger: .prefix(":")),
            withSubscopes("knowledge", [
                PaletteSubscope(id: "todos", trigger: "!", placeholder: "to-dos"),
                PaletteSubscope(id: "emoji", trigger: ":", placeholder: nil),
                PaletteSubscope(id: "todos", trigger: "", placeholder: nil),
                PaletteSubscope(id: "To Dos", trigger: "!!", placeholder: nil),
            ]),
        ])
        #expect(problems == [
            "Scope ID \"emoji\" of \"knowledge\" is used twice",
            "Modules \"emoji\" and \"knowledge\" both use the trigger \":\"",
            "Scope ID \"todos\" of \"knowledge\" is used twice",
            "Module \"knowledge\" has a scope with an empty trigger",
            "Scope ID \"To Dos\" of \"knowledge\" is not lowercase letters, digits and hyphens",
        ])
    }

    // MARK: - Starting

    @Test func createsEveryModuleAndStartsTheActiveOnesInListOrder() async {
        let host = ModuleHost(
            [FakeDefault.self, FakeOff.self, FakeStored.self, FakeDependent.self, FakePlain.self],
            services: services())
        #expect(host.modules.count == 5)
        #expect(host.manifests.map(\.id) == ["default", "off", "stored", "dependent", "plain"])

        await host.start()
        let started = host.modules.compactMap { $0 as? FakeModule }.filter { $0.startIndex != nil }
        #expect(started.map { $0.context.id } == ["default", "plain"])
        #expect(started[0].startIndex! < started[1].startIndex!)
    }

    @Test func leavesOutModulesWhoseRequirementsAreNotMet() throws {
        let withoutDatabase = ModuleHost([FakeDefault.self, FakeStored.self, FakeDependent.self], services: services())
        #expect(!withoutDatabase.isActive("stored"))
        #expect(!withoutDatabase.isActive("dependent"))
        #expect(withoutDatabase.unavailableReason("stored") == "Needs the database")
        #expect(withoutDatabase.unavailableReason("dependent") == "Needs Stored to be on")
        #expect(withoutDatabase.unavailableReason("default") == nil)

        let withDatabase = ModuleHost(
            [FakeDefault.self, FakeStored.self, FakeDependent.self], services: services(database: try makeTestDatabase()))
        #expect(withDatabase.isActive("stored"))
        #expect(withDatabase.isActive("dependent"))
    }

    @Test func collectsThePermissionsOfActiveModules() {
        let host = ModuleHost([FakeDefault.self, FakeAsking.self, FakeStored.self], services: services())
        #expect(host.activePermissions == [.accessibility])
    }

    @Test func startsOnlyOnce() async {
        let host = ModuleHost([FakeDefault.self], services: services())
        await host.start()
        await host.start()
        #expect((host.modules[0] as? FakeModule)?.starts == 1)
    }

    // MARK: - Hotkeys

    @Test func registersTheHotkeysOfActiveModulesOnceStarted() async throws {
        var registered: [ModuleHotkey] = []
        let host = ModuleHost(
            [FakeDefault.self, FakeStored.self, FakePlain.self], services: services(),
            registerHotkey: { registered.append($0) }, setHotkeyEnabled: { _, _ in })
        #expect(registered.isEmpty)

        await host.start()
        #expect(registered.map(\.name.rawValue) == ["fakePlain"])
        let plain = try #require(host.module(FakePlain.self))
        registered[0].action()
        #expect(plain.hotkeyPresses == 1)
    }

    // MARK: - Switching on and off

    @Test func readsTheStoredSwitchThenTheLegacyOneThenTheManifest() {
        let store = UserDefaults(suiteName: suiteName)!
        defer { store.removePersistentDomain(forName: suiteName) }
        let types: [any CortexModule.Type] = [FakeDefault.self, FakeOff.self, FakeLegacy.self, FakePlain.self]

        var host = ModuleHost(types, services: services())
        #expect(!host.isEnabled("off") && !host.isEnabled("legacy") && host.isEnabled("plain"))

        store.set(true, forKey: "fakeLegacySwitch")
        store.set(false, forKey: ModuleHost.enabledKey("plain"))
        host = ModuleHost(types, services: services())
        #expect(host.isActive("legacy") && !host.isActive("plain"))

        // Once set, the module's own switch wins.
        store.set(false, forKey: ModuleHost.enabledKey("legacy"))
        host = ModuleHost(types, services: services())
        #expect(!host.isEnabled("legacy"))
    }

    @Test func switchingOffStopsTheModuleAndItsDependantsAndOnStartsThemAgain() async throws {
        let store = UserDefaults(suiteName: suiteName)!
        defer { store.removePersistentDomain(forName: suiteName) }
        var changes = 0
        let host = ModuleHost(
            [FakeDefault.self, FakeStored.self, FakeDependent.self], services: services(database: try makeTestDatabase()))
        host.onChange { changes += 1 }
        await host.start()
        let stored = try #require(host.modules[1] as? FakeModule)
        let dependent = try #require(host.modules[2] as? FakeModule)
        #expect(stored.starts == 1 && dependent.starts == 1 && changes == 1)

        await host.setEnabled("stored", false).value
        #expect(store.object(forKey: "module.stored.enabled") as? Bool == false)
        #expect(!host.isActive("stored") && !host.isActive("dependent"))
        #expect(host.isEnabled("dependent"))
        #expect(host.unavailableReason("dependent") == "Needs Stored to be on")
        #expect(stored.stops == 1 && dependent.stops == 1)
        // Dependants stop first.
        #expect(dependent.stopIndex! < stored.stopIndex!)
        #expect(host.api((any FakeGreeting).self) == nil)
        #expect(changes == 2)

        await host.setEnabled("stored", true).value
        #expect(host.isActive("stored") && host.isActive("dependent"))
        #expect(stored.starts == 2 && dependent.starts == 2)
        #expect(stored.startIndex! < dependent.startIndex!)
        #expect(changes == 3)
    }

    @Test func quickSwitchesEndInTheLastOne() async throws {
        let host = ModuleHost([FakeDefault.self, FakePlain.self], services: services())
        defer { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }
        await host.start()
        let plain = try #require(host.modules[1] as? FakeModule)
        host.setEnabled("plain", false)
        await host.setEnabled("plain", true).value
        #expect(plain.starts == 1 && plain.stops == 0, "off and on again before it took effect: nothing to do")

        host.setEnabled("plain", true)
        host.setEnabled("plain", false)
        await host.setEnabled("plain", false).value
        #expect(plain.starts == 1 && plain.stops == 1)
        #expect(!host.isActive("plain"))
    }

    @Test func aSwitchBeforeStartingOnlyDecidesWhatStarts() async throws {
        let host = ModuleHost([FakeDefault.self, FakeOff.self], services: services())
        defer { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }
        await host.setEnabled("off", true).value
        let off = try #require(host.modules[1] as? FakeModule)
        #expect(off.starts == 0)
        await host.start()
        #expect(off.starts == 1)
    }

    @Test func noDatabaseMeansTheSwitchCannotBeTurnedOn() {
        let host = ModuleHost([FakeDefault.self, FakeStored.self], services: services())
        #expect(!host.canEnable("stored") && host.canEnable("default"))
    }

    @Test func hotkeysFollowTheSwitch() async throws {
        var registered: [ModuleHotkey] = []
        var switched: [String] = []
        let host = ModuleHost(
            [FakeDefault.self, FakePlain.self], services: services(),
            registerHotkey: { registered.append($0) },
            setHotkeyEnabled: { switched.append("\($0.rawValue) \($1 ? "on" : "off")") })
        defer { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }
        await host.start()
        let plain = try #require(host.module(FakePlain.self))

        await host.setEnabled("plain", false).value
        #expect(switched == ["fakePlain off"])
        // A press that gets through anyway does nothing.
        registered[0].action()
        #expect(plain.hotkeyPresses == 0)

        await host.setEnabled("plain", true).value
        #expect(switched == ["fakePlain off", "fakePlain on"])
        #expect(registered.count == 1, "registered once")
        registered[0].action()
        #expect(plain.hotkeyPresses == 1)
    }

    @Test func paletteRoutesFollowTheSwitch() async {
        let host = ModuleHost([FakeDefault.self, FakeOff.self], services: services())
        defer { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }
        #expect(host.paletteRoutes.isEmpty)
        await host.start()
        await host.setEnabled("off", true).value
        #expect(host.paletteRoutes.map(\.id) == ["off"])
    }

    @Test func subscopesFollowTheirModule() async {
        let host = ModuleHost([FakeDefault.self, FakeOff.self, FakeTwoScopes.self], services: services())
        defer { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }
        await host.start()
        #expect(host.paletteRoutes.map(\.id) == ["two", "two-more"])
        #expect(host.paletteRoutes.map(\.trigger) == [.prefix("?"), .prefix("!")])
        #expect(PaletteRouting.placeholder(for: host.paletteRoutes) == "Search ?notes · !more")
        #expect(PaletteRouting.resolve("!milk", in: host.paletteRoutes).route?.id == "two-more")
        await host.setEnabled("two", false).value
        #expect(host.paletteRoutes.isEmpty)
    }

    // MARK: - APIs

    @Test func findsTheAPIOfAnActiveModule() throws {
        let host = ModuleHost([FakeDefault.self, FakePlain.self], services: services())
        let greeter = try #require(host.api((any FakeGreeting).self))
        #expect(greeter.greet() == "hello from plain")
        #expect(host.module(FakePlain.self) === greeter)
    }

    @Test func hidesTheAPIOfAnInactiveModule() {
        let host = ModuleHost([FakeDefault.self, FakeStored.self], services: services())
        #expect(host.api((any FakeGreeting).self) == nil)
        #expect(host.module(FakeStored.self) == nil)
    }

    @Test func modulesFindEachOtherThroughTheirContext() throws {
        let host = ModuleHost([FakeDefault.self, FakePlain.self], services: services())
        let first = try #require(host.modules[0] as? FakeModule)
        #expect(first.context.api((any FakeGreeting).self)?.greet() == "hello from plain")
    }

    // MARK: - Context

    @Test func scopesDefaultsAndSecretsByModule() throws {
        let host = ModuleHost([FakeDefault.self], services: services())
        let context = try #require(host.modules[0] as? FakeModule).context
        let store = UserDefaults(suiteName: suiteName)!

        context.defaults.set(3, for: "count")
        #expect(store.integer(forKey: "default.count") == 3)
        #expect(context.defaults.integer("count") == 3)
        #expect(context.defaults.bool("missing") == nil)

        context.defaults.set(true, for: .legacy("pastePlainByDefault"))
        #expect(store.bool(forKey: "pastePlainByDefault"))

        let key = context.secrets.key("token", title: "Token")
        #expect(key.account == "default.token")
        #expect(context.secrets.string(for: key) == nil)
        try context.secrets.set("s3cret", for: key)
        #expect(context.secrets.string(for: key) == "s3cret")
        try context.secrets.remove(key)
        #expect(!context.secrets.isSet(key))

        store.removePersistentDomain(forName: suiteName)
    }
}

// MARK: - Fakes

@MainActor protocol FakeGreeting: AnyObject {
    func greet() -> String
}

@MainActor private enum StartCounter {
    static var next = 0
}

@MainActor class FakeModule {
    let context: ModuleContext
    private(set) var startIndex: Int?
    private(set) var starts = 0
    private(set) var stopIndex: Int?
    private(set) var stops = 0

    required init(context: ModuleContext) {
        self.context = context
    }

    func start() async {
        starts += 1
        StartCounter.next += 1
        startIndex = StartCounter.next
    }

    func stop() {
        stops += 1
        StartCounter.next += 1
        stopIndex = StartCounter.next
    }
}

final class FakeDefault: FakeModule, CortexModule {
    static let manifest = ModuleManifest(id: "default", name: "Default", summary: "", symbol: "circle", trigger: .default, order: 10)
}

final class FakeOff: FakeModule, CortexModule {
    static let manifest = ModuleManifest(
        id: "off", name: "Off", summary: "", symbol: "circle", trigger: .prefix(";"), enabledByDefault: false, order: 20)
    private let scope = FakeScope()
    var palette: (any PaletteScope)? { scope }
}

final class FakeTwoScopes: FakeModule, CortexModule {
    static let manifest = ModuleManifest(
        id: "two", name: "Two", summary: "", symbol: "circle", trigger: .prefix("?"), placeholder: "notes",
        subscopes: [PaletteSubscope(id: "two-more", trigger: "!", placeholder: "more")], order: 24)
    private let scope = FakeScope(), more = FakeScope()
    var palette: (any PaletteScope)? { scope }
    func palette(_ subscope: ModuleID) -> (any PaletteScope)? { subscope == "two-more" ? more : nil }
}

final class FakeLegacy: FakeModule, CortexModule {
    static let manifest = ModuleManifest(
        id: "legacy", name: "Legacy", summary: "", symbol: "circle", enabledByDefault: false,
        legacyEnabledKey: "fakeLegacySwitch", order: 22)
}

final class FakeStored: FakeModule, CortexModule, FakeGreeting {
    static let manifest = ModuleManifest(
        id: "stored", name: "Stored", summary: "", symbol: "circle", requirements: [.database], order: 30)
    func greet() -> String { "hello from stored" }
    var hotkeys: [ModuleHotkey] { [ModuleHotkey(.init("fakeStored"), title: "Stored:") {}] }
}

final class FakeAsking: FakeModule, CortexModule {
    static let manifest = ModuleManifest(
        id: "asking", name: "Asking", summary: "", symbol: "circle", permissions: [.accessibility], order: 25)
}

final class FakeDependent: FakeModule, CortexModule {
    static let manifest = ModuleManifest(
        id: "dependent", name: "Dependent", summary: "", symbol: "circle", requirements: [.module("stored")], order: 40)
}

final class FakePlain: FakeModule, CortexModule, FakeGreeting {
    static let manifest = ModuleManifest(id: "plain", name: "Plain", summary: "", symbol: "circle", order: 50)
    func greet() -> String { "hello from plain" }
    private(set) var hotkeyPresses = 0
    var hotkeys: [ModuleHotkey] {
        [ModuleHotkey(.init("fakePlain"), title: "Plain:") { [unowned self] in hotkeyPresses += 1 }]
    }
}
