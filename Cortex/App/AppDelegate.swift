import AppKit
import KeyboardShortcuts
import CortexCore

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }

    private let log = Log.logger("app")

    private(set) var database: AppDatabase?
    private(set) var databaseError: (any Error)?
    let paletteSettings = PaletteSettings()
    let accessibility = AccessibilityPermission()
    let launchAtLogin = LaunchAtLogin()
    let keepAwake = KeepAwake()

    private(set) var modules: ModuleHost!
    private(set) var panel: PanelController!
    private(set) var settings: SettingsWindowController!
    private(set) var onboarding: OnboardingWindowController!
    private var statusItem: StatusItemController!

    /// True when the app only hosts the unit tests: then it must not open the
    /// real database, record the real pasteboard or show any windows.
    static var isHostingTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !Self.isHostingTests else { return }
        NSApp.mainMenu = MainMenu.make()
        let notifier = Notifier()
        notifier.start()
        openDatabase()

        onboarding = OnboardingWindowController(accessibility: accessibility)
        let services = ModuleServices(
            database: database, accessibility: accessibility, notifier: notifier,
            requestAccessibility: { [unowned self] in onboarding.show() })
        modules = ModuleHost(ModuleList.all, services: services)
        panel = PanelController(
            routes: modules.paletteRoutes,
            dropFiles: { [unowned self] urls in modules.dropFiles(urls) },
            pasting: services.pasting,
            accessibility: accessibility,
            requestAccessibility: { [unowned self] in showOnboarding() },
            paletteSettings: paletteSettings)
        services.palette = panel
        settings = SettingsWindowController(
            host: modules, accessibility: accessibility, launchAtLogin: launchAtLogin,
            keepAwake: keepAwake, paletteSettings: paletteSettings,
            storage: { [unowned self] in StorageInfo(database: database, error: databaseError) })
        statusItem = StatusItemController(
            modules: modules, accessibility: accessibility,
            openPalette: { [unowned self] in panel.show() },
            openSettings: { [unowned self] in settings.show() },
            openOnboarding: { [unowned self] in showOnboarding() })

        KeyboardShortcuts.onKeyDown(for: .togglePalette) { [unowned self] in
            panel.toggle()
        }
        modules.onChange { [unowned self] in
            panel.setRoutes(modules.paletteRoutes)
        }
        Task { await modules.start() }
        keepAwake.apply()

        // Only while a module that is on needs it (pasting, event taps).
        if !accessibility.isGranted && modules.activePermissions.contains(.accessibility) {
            onboarding.show()
        }
        log.info("Launched")
    }

    func applicationWillTerminate(_ notification: Notification) {
        keepAwake.stop()
    }

    func showOnboarding() {
        onboarding.show()
    }

    // MARK: - Database

    private func openDatabase() {
        do {
            database = try AppDatabase.openDefault()
        } catch let error as AppDatabaseError {
            log.error("Cannot open database: \(error.description, privacy: .public)")
            recoverFromUnreadableDatabase(error)
        } catch {
            log.error("Cannot open database: \(error, privacy: .public)")
            databaseError = error
        }
    }

    /// The database exists but cannot be decrypted (key missing or wrong).
    /// Never delete it silently: offer to move it aside or quit.
    private func recoverFromUnreadableDatabase(_ error: AppDatabaseError) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "The database can't be opened"
        alert.informativeText = """
            \(error.description)

            You can move the old database aside and start with an empty one. \
            The old file is kept next to the new one.
            """
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Move Aside and Start Fresh")

        NSApp.activate()
        guard alert.runModal() == .alertSecondButtonReturn else {
            NSApp.terminate(nil)
            return
        }
        do {
            try AppDatabase.moveAside(databaseAt: AppPaths.databaseURL())
            database = try AppDatabase.openDefault()
        } catch {
            log.error("Starting fresh failed: \(error, privacy: .public)")
            databaseError = error
        }
    }
}
