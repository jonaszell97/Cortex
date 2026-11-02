import Foundation
import KeyboardShortcuts
import CortexCore

/// Creates every module with its own context, checks their manifests and
/// starts the active ones in list order. Switching a module on or off starts
/// or stops it right away, together with the modules that require it.
///
/// A module is active while it is enabled and its requirements are met (the
/// database could be opened, required modules are active). Every module is
/// created, active or not; only active ones are started and found by `api`.
@MainActor
@Observable
final class ModuleHost {
    /// In list order.
    @ObservationIgnored private(set) var modules: [any CortexModule] = []
    /// What is wrong with the manifests (docs/ARCHITECTURE.md, "The registry and
    /// manifest validation"); empty when all is well. Debug builds stop at the
    /// first problem.
    let problems: [String]
    @ObservationIgnored private(set) var isStarted = false

    @ObservationIgnored private let services: ModuleServices
    @ObservationIgnored private let registerHotkey: @MainActor (ModuleHotkey) -> Void
    @ObservationIgnored private let setHotkeyEnabled: @MainActor (KeyboardShortcuts.Name, Bool) -> Void
    /// Each module's switch, as stored.
    private var enabled: [ModuleID: Bool] = [:]
    /// Enabled and with every requirement met.
    private var active: Set<ModuleID> = []
    /// Started and not stopped since.
    @ObservationIgnored private var running: Set<ModuleID> = []
    @ObservationIgnored private var hotkeysRegistered: Set<ModuleID> = []
    @ObservationIgnored private var changeHandlers: [() -> Void] = []
    /// The last start or stop; the next one waits for it.
    @ObservationIgnored private var transition: Task<Void, Never>?

    init(
        _ types: [any CortexModule.Type],
        services: ModuleServices,
        registerHotkey: @escaping @MainActor (ModuleHotkey) -> Void = ModuleHost.register,
        setHotkeyEnabled: @escaping @MainActor (KeyboardShortcuts.Name, Bool) -> Void = ModuleHost.setEnabled
    ) {
        self.services = services
        self.registerHotkey = registerHotkey
        self.setHotkeyEnabled = setHotkeyEnabled
        let manifests = types.map { $0.manifest }
        problems = ModuleManifest.problems(in: manifests)
        for problem in problems {
            Log.logger("modules").fault("\(problem, privacy: .public)")
        }
        assert(problems.isEmpty, problems.joined(separator: "\n"))

        for manifest in manifests {
            enabled[manifest.id] = Self.storedSwitch(of: manifest, in: services.defaults)
        }
        active = resolveActive(manifests)
        modules = types.map { type in
            type.init(context: ModuleContext(id: type.manifest.id, services: services, host: self))
        }
    }

    /// Where a module's switch is stored.
    static func enabledKey(_ id: ModuleID) -> String {
        "module.\(id.rawValue).enabled"
    }

    /// The module's switch; before it was ever set, the legacy switch or the
    /// manifest's default.
    private static func storedSwitch(of manifest: ModuleManifest, in defaults: UserDefaults) -> Bool {
        if let stored = defaults.object(forKey: enabledKey(manifest.id)) as? Bool { return stored }
        if let key = manifest.legacyEnabledKey, let legacy = defaults.object(forKey: key) as? Bool { return legacy }
        return manifest.enabledByDefault
    }

    static func manifest(of module: any CortexModule) -> ModuleManifest {
        type(of: module).manifest
    }

    var manifests: [ModuleManifest] {
        modules.map(Self.manifest(of:))
    }

    /// Enabled and with its requirements met.
    func isActive(_ id: ModuleID) -> Bool {
        active.contains(id)
    }

    /// The module's switch in Settings.
    func isEnabled(_ id: ModuleID) -> Bool {
        enabled[id] ?? false
    }

    /// false while the module cannot run whatever its switch says (no
    /// database): Settings shows the switch off and greyed out.
    func canEnable(_ id: ModuleID) -> Bool {
        guard let manifest = manifests.first(where: { $0.id == id }) else { return false }
        return !manifest.requirements.contains(.database) || services.database != nil
    }

    /// Stores the switch and starts or stops the module, and the modules that
    /// require it, once the previous switch has taken effect. The task ends
    /// when everything has started or stopped.
    @discardableResult
    func setEnabled(_ id: ModuleID, _ isOn: Bool) -> Task<Void, Never> {
        services.defaults.set(isOn, forKey: Self.enabledKey(id))
        enabled[id] = isOn
        active = resolveActive(manifests)
        return reconcile()
    }

    /// Called after modules were started or stopped (the palette rebuilds its
    /// routes, the status menu its items).
    func onChange(_ handler: @escaping () -> Void) {
        changeHandlers.append(handler)
    }

    /// What the active modules ask for (onboarding, Settings → Permissions).
    var activePermissions: Set<ModulePermission> {
        manifests.filter { isActive($0.id) }.reduce(into: []) { $0.formUnion($1.permissions) }
    }

    /// Why a module cannot run ("Needs the database"), or nil if it can.
    func unavailableReason(_ id: ModuleID) -> String? {
        guard let manifest = manifests.first(where: { $0.id == id }) else { return nil }
        let unmet = manifest.requirements.sorted { $0.description < $1.description }.first { requirement in
            switch requirement {
            case .database: services.database == nil
            case .module(let other): !isActive(other)
            }
        }
        switch unmet {
        case .module(let other):
            let name = manifests.first { $0.id == other }?.name ?? other.rawValue
            return "Needs \(name) to be on"
        case let unmet?:
            return unmet.description
        case nil:
            return nil
        }
    }

    /// A module's secrets, for its `.secret` options in Settings.
    func secrets(for id: ModuleID) -> ModuleSecrets {
        ModuleSecrets(id: id, store: services.secrets)
    }

    /// The module of this type, while it is active.
    func module<Module: CortexModule>(_ type: Module.Type) -> Module? {
        guard isActive(type.manifest.id) else { return nil }
        return modules.lazy.compactMap { $0 as? Module }.first
    }

    /// The first active module that provides `type` (a module's API
    /// protocol), or nil.
    func api<T>(_ type: T.Type) -> T? {
        for module in modules where isActive(Self.manifest(of: module).id) {
            if let api = module as? T { return api }
        }
        return nil
    }

    /// Every active module that provides `type`, in list order.
    func apis<T>(_ type: T.Type) -> [T] {
        modules.filter { isActive(Self.manifest(of: $0).id) }.compactMap { $0 as? T }
    }

    /// The palette routes of the active modules with a trigger and a scope,
    /// in manifest order, each followed by its subscopes.
    var paletteRoutes: [PaletteRoute] {
        activeModulesInOrder.flatMap { module in
            let manifest = Self.manifest(of: module)
            var routes: [PaletteRoute] = []
            if let trigger = manifest.trigger, let scope = module.palette {
                routes.append(PaletteRoute(id: manifest.id, trigger: trigger, placeholder: manifest.placeholder, scope: scope))
            }
            for subscope in manifest.subscopes {
                guard let scope = module.palette(subscope.id) else { continue }
                routes.append(PaletteRoute(
                    id: subscope.id, trigger: .prefix(subscope.trigger), placeholder: subscope.placeholder, scope: scope))
            }
            return routes
        }
    }

    /// The active modules' status menu items, one group per module that has
    /// any, in manifest order.
    var statusMenuGroups: [[StatusMenuItem]] {
        activeModulesInOrder.map { $0.statusMenuItems() }.filter { !$0.isEmpty }
    }

    /// The menu bar icon with the highest priority an active module asks
    /// for; the first in manifest order on a tie.
    var statusIcon: StatusIcon? {
        activeModulesInOrder.compactMap(\.statusIcon).reduce(nil) { best, icon in
            guard let best, best.priority >= icon.priority else { return icon }
            return best
        }
    }

    private var activeModulesInOrder: [any CortexModule] {
        modules
            .filter { isActive(Self.manifest(of: $0).id) }
            .sorted { Self.manifest(of: $0).order < Self.manifest(of: $1).order }
    }

    /// Hands dropped files to the first active module that takes them.
    @discardableResult
    func dropFiles(_ urls: [URL]) -> Bool {
        modules.contains { isActive(Self.manifest(of: $0).id) && $0.acceptsDroppedFiles(urls) }
    }

    /// Starts the active modules, one after the other in list order, and
    /// registers each one's hotkeys once it has started.
    func start() async {
        guard !isStarted else { return }
        isStarted = true
        await reconcile().value
    }

    private func reconcile() -> Task<Void, Never> {
        let previous = transition
        let task = Task {
            await previous?.value
            await self.startAndStop()
        }
        transition = task
        return task
    }

    /// Stops what runs but is no longer active, dependants first, then starts
    /// what is active but not running, in list order.
    private func startAndStop() async {
        guard isStarted else { return }
        for module in modules.reversed() {
            let id = Self.manifest(of: module).id
            guard running.contains(id), !isActive(id) else { continue }
            running.remove(id)
            for hotkey in module.hotkeys { setHotkeyEnabled(hotkey.name, false) }
            module.stop()
        }
        for module in modules {
            let id = Self.manifest(of: module).id
            guard isActive(id), !running.contains(id) else { continue }
            running.insert(id)
            await module.start()
            enableHotkeys(of: module)
        }
        for handler in changeHandlers { handler() }
    }

    /// Registered the first time the module starts, switched on and off with
    /// it after that. A press only reaches the module while it is active.
    private func enableHotkeys(of module: any CortexModule) {
        let id = Self.manifest(of: module).id
        guard hotkeysRegistered.insert(id).inserted else {
            for hotkey in module.hotkeys { setHotkeyEnabled(hotkey.name, true) }
            return
        }
        for hotkey in module.hotkeys {
            registerHotkey(ModuleHotkey(hotkey.name, title: hotkey.title, help: hotkey.help) { [weak self] in
                guard self?.isActive(id) == true else { return }
                hotkey.action()
            })
        }
    }

    static func register(_ hotkey: ModuleHotkey) {
        KeyboardShortcuts.onKeyDown(for: hotkey.name) { hotkey.action() }
    }

    static func setEnabled(_ name: KeyboardShortcuts.Name, _ isOn: Bool) {
        if isOn {
            KeyboardShortcuts.enable(name)
        } else {
            KeyboardShortcuts.disable(name)
        }
    }

    /// A module is active while it is enabled and its requirements are met;
    /// a module whose requirement is not met is left out, and so are the
    /// modules that require it.
    private func resolveActive(_ manifests: [ModuleManifest]) -> Set<ModuleID> {
        let byID = Dictionary(manifests.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let hasDatabase = services.database != nil
        var resolved: [ModuleID: Bool] = [:]

        func isActive(_ id: ModuleID, visiting: Set<ModuleID>) -> Bool {
            if let known = resolved[id] { return known }
            guard let manifest = byID[id], enabled[id] == true, !visiting.contains(id) else { return false }
            let met = manifest.requirements.allSatisfy { requirement in
                switch requirement {
                case .database: hasDatabase
                case .module(let other): isActive(other, visiting: visiting.union([id]))
                }
            }
            resolved[id] = met
            return met
        }

        return Set(manifests.map(\.id).filter { isActive($0, visiting: []) })
    }
}
