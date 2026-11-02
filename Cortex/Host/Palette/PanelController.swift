import AppKit
import SwiftUI
import CortexCore

/// Shows and hides the palette panel, hands its keys to the palette model,
/// and delivers what a scope picked into the app that was frontmost before
/// the panel opened. Placement, focus loss and closing on lock and sleep are
/// in PanelController+Window.swift.
@MainActor
final class PanelController: NSObject, PaletteHost {
    private let log = Log.logger("panel")
    private let model: PaletteModel
    // Also used by the window half in PanelController+Window.swift.
    let panel: PalettePanel
    let paletteSettings: PaletteSettings
    private let pasting: PasteService
    private let accessibility: AccessibilityPermission
    private let requestAccessibility: () -> Void

    /// The app that was frontmost when the panel opened; pastes go there.
    private(set) var previousApp: NSRunningApplication?
    /// Called each time the palette opens (sync checks whether it's stale).
    private var showHandlers: [() -> Void] = []
    /// Waits for the end of a possible drag onto the palette.
    var mouseUpMonitor: Any?
    /// True while the panel is placed in code, so only the user's moves are remembered.
    var isPlacing = false

    init(
        routes: [PaletteRoute],
        dropFiles: @escaping ([URL]) -> Bool,
        pasting: PasteService,
        accessibility: AccessibilityPermission,
        requestAccessibility: @escaping () -> Void,
        paletteSettings: PaletteSettings
    ) {
        self.pasting = pasting
        self.accessibility = accessibility
        self.requestAccessibility = requestAccessibility
        self.paletteSettings = paletteSettings
        model = PaletteModel(routes: routes)
        panel = PalettePanel(contentRect: NSRect(origin: .zero, size: PaletteView.size))
        super.init()

        model.onDropFiles = { [unowned self] urls in
            // A drop may come while the panel is up but not key.
            panel.makeKeyAndOrderFront(nil)
            // An overlay that takes files (a `$` form's path field) first.
            if let drop = model.overlay?.dropFiles, drop(urls) { return true }
            return dropFiles(urls)
        }

        let hostingView = NSHostingView(rootView: PaletteView(model: model, settings: paletteSettings))
        hostingView.sizingOptions = []
        panel.contentView = hostingView
        panel.delegate = self
        panel.onCancel = { [unowned self] in cancel() }
        panel.keyHandler = { [unowned self] event in handleKey(event) }

        observeLockAndSleep()
    }

    var isVisible: Bool { panel.isVisible }

    var activeModule: ModuleID? { model.activeModule }

    func toggle() {
        isVisible ? close() : show()
    }

    /// Modules were switched on or off: if that changed the routes, the
    /// palette closes and routes by the new triggers.
    func setRoutes(_ routes: [PaletteRoute]) {
        guard routes.map(\.id) != model.routes.map(\.id) else { return }
        close()
        model.setRoutes(routes)
    }

    func open(_ id: ModuleID) {
        open(id, searching: "")
    }

    func open(_ id: ModuleID, searching text: String) {
        show()
        // A drop or a Services request may have come while the panel was up
        // but not key.
        panel.makeKeyAndOrderFront(nil)
        model.open(id, searching: text)
    }

    func toggle(_ id: ModuleID) {
        if isVisible && model.activeModule == id {
            close()
        } else {
            open(id)
        }
    }

    func present(_ overlay: PaletteOverlay) {
        model.overlay = overlay
    }

    func focusSearch() {
        model.focusSearch()
    }

    func onShow(_ handler: @escaping () -> Void) {
        showHandlers.append(handler)
    }

    func show() {
        guard !isVisible else { return }

        let frontmost = NSWorkspace.shared.frontmostApplication
        previousApp = frontmost == .current ? nil : frontmost

        model.prepareForShow()
        for handler in showHandlers { handler() }
        isPlacing = true
        panel.setFrameOrigin(origin(on: screenWithMouse()))
        isPlacing = false
        panel.makeKeyAndOrderFront(nil)
        // The window is transparent, so its shadow follows what it draws. Work
        // it out again once the panel has drawn (the style may have changed
        // since it was last open), instead of from a stale or empty frame.
        DispatchQueue.main.async { [weak self] in self?.panel.invalidateShadow() }
        log.debug("Shown over \(self.previousApp?.bundleIdentifier ?? "-", privacy: .public)")
    }

    func close() {
        removeMouseUpMonitor()
        guard isVisible else { return }
        panel.orderOut(nil)
        model.clear()
        restoreFocus()
    }

    /// Esc: leaves the overlay, the fill-in form or what the scope has open,
    /// or closes the palette.
    private func cancel() {
        if !model.cancel() { close() }
    }

    /// The panel never activates Cortex, so normally the previous app is still
    /// active and gets its key window back by itself. If something did activate
    /// Cortex in the meantime, hand activation back explicitly.
    private func restoreFocus() {
        defer { previousApp = nil }
        guard let previousApp, !previousApp.isTerminated,
              NSWorkspace.shared.frontmostApplication == .current
        else { return }
        previousApp.activate()
    }

    // MARK: - Keys

    private func handleKey(_ event: NSEvent) -> Bool {
        if event.type == .flagsChanged {
            model.modifiersChanged(event.modifierFlags)
            return false
        }
        let key = PaletteKeyMap.event(
            keyCode: Int(event.keyCode), modifiers: event.modifierFlags, characters: event.charactersIgnoringModifiers)
        guard let key else { return false }
        return model.handle(key)
    }

    // MARK: - Delivering

    func closeAndDeliver(
        _ content: PasteContent, _ action: PasteAction, recording: Paster.Recording, restoringPasteboard: Bool,
        after: (@MainActor (Bool) -> Void)?
    ) {
        closeAndDeliver(action) { [pasting] target in
            let delivered = await pasting.deliver(
                content, action, recording: recording, restoringPasteboard: restoringPasteboard, into: target)
            after?(delivered)
            return delivered
        }
    }

    func closeAndDeliver(_ action: PasteAction, _ deliver: @escaping @MainActor (NSRunningApplication?) async -> Bool) {
        let target = previousApp
        close()
        Task {
            let pasted = await deliver(target)
            if !pasted, case .paste = action, !accessibility.isGranted {
                requestAccessibility()
            }
        }
    }
}
