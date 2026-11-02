import Foundation
import os
import CortexCore

/// The host's shared services, created once by `AppDelegate` and handed to
/// every module through its `ModuleContext`.
@MainActor
final class ModuleServices {
    /// nil if it could not be opened.
    let database: AppDatabase?
    let defaults: UserDefaults
    let secrets: any SecretStore
    let accessibility: AccessibilityPermission
    let pasting: PasteService
    let pasteboard: PasteboardActivity
    let notifier: Notifier
    /// Set once the panel exists, which is after the modules are created and
    /// before any of them starts.
    var palette: (any PaletteHost)?
    /// Opens onboarding at the Accessibility step.
    var requestAccessibility: () -> Void

    init(
        database: AppDatabase? = nil,
        defaults: UserDefaults = .standard,
        secrets: any SecretStore = KeychainStore.app,
        accessibility: AccessibilityPermission = AccessibilityPermission(),
        pasting: PasteService? = nil,
        pasteboard: PasteboardActivity = PasteboardActivity(),
        notifier: Notifier = Notifier(),
        requestAccessibility: @escaping () -> Void = {}
    ) {
        self.database = database
        self.defaults = defaults
        self.secrets = secrets
        self.accessibility = accessibility
        self.pasting = pasting ?? PasteService(accessibility: accessibility)
        self.pasteboard = pasteboard
        self.notifier = notifier
        self.requestAccessibility = requestAccessibility
    }
}

/// What a module may use from the host. Handed to `init`, so a module never
/// reaches for `AppDelegate`.
@MainActor
final class ModuleContext {
    let id: ModuleID
    /// nil if it could not be opened.
    let database: AppDatabase?
    /// UserDefaults, keys "<id>.<name>" or legacy keys.
    let defaults: ModuleDefaults
    /// Keychain, accounts "<id>.<name>" or legacy accounts.
    let secrets: ModuleSecrets
    let accessibility: AccessibilityPermission
    /// Pasteboard writes and ⌘V.
    let pasting: PasteService
    /// "Cortex is borrowing the pasteboard".
    let pasteboard: PasteboardActivity
    /// User notifications.
    let notifier: Notifier
    /// `Log.logger("<id>")`
    let log: Logger

    private let services: ModuleServices
    private unowned let host: ModuleHost

    init(id: ModuleID, services: ModuleServices, host: ModuleHost) {
        self.id = id
        self.services = services
        self.host = host
        database = services.database
        defaults = ModuleDefaults(id: id, store: services.defaults)
        secrets = ModuleSecrets(id: id, store: services.secrets)
        accessibility = services.accessibility
        pasting = services.pasting
        pasteboard = services.pasteboard
        notifier = services.notifier
        log = Log.logger(id.rawValue)
    }

    /// Open, close, paste. Only from `start()` on: the panel is created after
    /// the modules.
    var palette: any PaletteHost {
        guard let palette = services.palette else {
            preconditionFailure("The palette is used before the modules were started")
        }
        return palette
    }

    /// Another module's API, or nil while that module is off or unavailable
    /// (docs/ARCHITECTURE.md, "Modules talking to each other").
    func api<T>(_ type: T.Type) -> T? {
        host.api(type)
    }

    /// Every active module that provides `type`, in list order (Sync's
    /// contributions).
    func apis<T>(_ type: T.Type) -> [T] {
        host.apis(type)
    }

    /// Runs `start` with the value while `wanted` returns one and stops when
    /// it returns nil; retries when Accessibility is granted.
    func whileWanted<Value>(
        _ wanted: @escaping @MainActor () -> Value?,
        start: @escaping @MainActor (Value) -> Bool,
        stop: @escaping @MainActor () -> Void
    ) -> ModuleTask {
        Cortex.whileWanted(accessibility: accessibility, wanted, start: start, stop: stop)
    }

    /// `whileWanted` for something that is either on or off.
    func whileWanted(
        _ wanted: @escaping @MainActor () -> Bool,
        start: @escaping @MainActor () -> Bool,
        stop: @escaping @MainActor () -> Void
    ) -> ModuleTask {
        Cortex.whileWanted(accessibility: accessibility, wanted, start: start, stop: stop)
    }

    /// Opens onboarding at the Accessibility step.
    func requestAccessibility() {
        services.requestAccessibility()
    }
}
