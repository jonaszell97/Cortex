import AppKit
import KeyboardShortcuts

/// The menu bar icon and its menu: the host's Open, Settings, Grant
/// Accessibility and Quit, and between them each active module's group of
/// items (docs/ARCHITECTURE.md, "Status item"). The icon is the one an active
/// module asks for, or Cortex's own. Files dropped on the icon go where palette
/// drops go.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate, NSWindowDelegate, NSDraggingDestination {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let modules: ModuleHost
    private let accessibility: AccessibilityPermission
    private let openPalette: () -> Void
    private let openSettings: () -> Void
    private let openOnboarding: () -> Void

    /// The modules' groups follow this.
    private let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettingsAction), keyEquivalent: ",")
    private let accessibilitySeparator = NSMenuItem.separator()
    private let accessibilityItem = NSMenuItem(
        title: "Grant Accessibility Access…", action: #selector(grantAccessibility), keyEquivalent: "")
    private var moduleItems: StatusMenuSection!
    private var isMenuOpen = false

    init(
        modules: ModuleHost,
        accessibility: AccessibilityPermission,
        openPalette: @escaping () -> Void,
        openSettings: @escaping () -> Void,
        openOnboarding: @escaping () -> Void
    ) {
        self.modules = modules
        self.accessibility = accessibility
        self.openPalette = openPalette
        self.openSettings = openSettings
        self.openOnboarding = openOnboarding
        super.init()

        statusItem.menu = makeMenu()
        observeIcon()
        acceptDrops()
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        // Modules say which of their items are enabled (Sync Now while syncing).
        menu.autoenablesItems = false

        let open = NSMenuItem(title: "Open Cortex", action: #selector(openPaletteAction), keyEquivalent: "")
        open.setShortcut(for: .togglePalette)
        menu.addItem(open)
        menu.addItem(settingsItem)
        menu.addItem(accessibilitySeparator)
        menu.addItem(accessibilityItem)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Cortex", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        for item in [open, settingsItem, accessibilityItem] {
            item.target = self
        }
        moduleItems = StatusMenuSection(in: menu, after: settingsItem)
        return menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        accessibility.refresh()
        let hidesAccessibility = accessibility.isGranted || !modules.activePermissions.contains(.accessibility)
        accessibilityItem.isHidden = hidesAccessibility
        accessibilitySeparator.isHidden = hidesAccessibility
        updateModuleItems()
    }

    func menuWillOpen(_ menu: NSMenu) {
        isMenuOpen = true
    }

    func menuDidClose(_ menu: NSMenu) {
        isMenuOpen = false
    }

    /// Kept current while the menu is open (running jobs, the sync line).
    private func updateModuleItems() {
        let groups = withObservationTracking {
            modules.statusMenuGroups
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.isMenuOpen else { return }
                self.updateModuleItems()
            }
        }
        moduleItems.update(groups)
    }

    // MARK: - Icon

    /// Follows what the modules ask for, and which modules are on.
    private func observeIcon() {
        withObservationTracking {
            updateIcon()
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeIcon() }
        }
    }

    private func updateIcon() {
        guard let icon = modules.statusIcon else {
            statusItem.button?.image = NSImage(systemSymbolName: "brain", accessibilityDescription: "Cortex")
            return
        }
        icon.image.accessibilityDescription = icon.accessibilityLabel
        statusItem.button?.image = icon.image
    }

    // MARK: - Dropping files on the icon

    /// The status bar button's window forwards dragging messages to its
    /// delegate.
    private func acceptDrops() {
        guard let window = statusItem.button?.window else { return }
        window.registerForDraggedTypes([.fileURL])
        window.delegate = self
    }

    private func droppedFiles(_ info: any NSDraggingInfo) -> [URL] {
        info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard !droppedFiles(sender).isEmpty else { return [] }
        statusItem.button?.highlight(true)
        return .copy
    }

    func draggingExited(_ sender: (any NSDraggingInfo)?) {
        statusItem.button?.highlight(false)
    }

    /// Like drops on the palette: the first active module that takes them.
    func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        statusItem.button?.highlight(false)
        let files = droppedFiles(sender)
        guard !files.isEmpty else { return false }
        return modules.dropFiles(files)
    }

    @objc private func openPaletteAction() { openPalette() }
    @objc private func openSettingsAction() { openSettings() }
    @objc private func grantAccessibility() { openOnboarding() }
}
