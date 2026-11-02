import AppKit
import SwiftUI
@testable import Cortex
import CortexCore

/// Every module running on demo data (a fresh database, a temporary config
/// and knowledge folder, in-memory secrets), with a palette that is drawn
/// into PNG files instead of shown. Nothing touches the real database,
/// clipboard or settings. Used by `ReadmeScreenshots`; see
/// docs/DEVELOPMENT.md, "Screenshots".
@MainActor
final class ScreenshotStudio {
    let output: URL
    let host: ModuleHost
    let model: PaletteModel
    let settings: PaletteSettings
    let database: AppDatabase
    private let suiteName = "CortexScreenshots-\(UUID().uuidString)"
    private let palette: StudioPaletteHost
    private var windows: [NSAppearance.Name: NSWindow] = [:]

    /// Pixels per point.
    static let scale: CGFloat = 2

    init(output: URL) async throws {
        self.output = output
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        let scratch = FileManager.default.temporaryDirectory
            .appending(path: "CortexScreenshots-\(UUID().uuidString)", directoryHint: .isDirectory)
        let configFolder = scratch.appending(path: "config/cortex", directoryHint: .isDirectory)
        // Actions, `$` commands and projects.toml are read from here.
        setenv("XDG_CONFIG_HOME", scratch.appending(path: "config").path(percentEncoded: false), 1)

        let defaults = UserDefaults(suiteName: suiteName)!
        DemoData.configure(defaults, scratch: scratch)
        let secrets = MemorySecrets()
        try secrets.set(Data("sk-demo".utf8), for: "ai.openai-api-key")

        database = try makeTestDatabase()
        try DemoData.seed(database: database, config: configFolder, knowledge: scratch.appending(path: "knowledge"))

        let services = ModuleServices(database: database, defaults: defaults, secrets: secrets)
        host = ModuleHost(ModuleList.all, services: services, registerHotkey: { _ in }, setHotkeyEnabled: { _, _ in })
        settings = PaletteSettings(defaults: defaults)
        settings.style = .glass
        model = PaletteModel(routes: [])
        palette = StudioPaletteHost(model: model)
        services.palette = palette
        await host.start()
        model.setRoutes(host.paletteRoutes)
        model.prepareForShow()
        // The knowledge index is built in the background.
        try await Task.sleep(for: .seconds(4))
    }

    func tearDown() {
        for window in windows.values { window.orderOut(nil) }
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
    }

    // MARK: - Driving the palette

    /// Puts `text` into the search field, as if typed at once.
    func type(_ text: String, wait: Duration = .milliseconds(700)) async throws {
        model.query = text
        try await Task.sleep(for: wait)
    }

    func press(_ event: PaletteKeyEvent, wait: Duration = .milliseconds(400)) async throws {
        _ = model.handle(event)
        try await Task.sleep(for: wait)
    }

    func down(_ count: Int = 1) async throws {
        for _ in 0..<count { try await press(.move(.vertical(1)), wait: .milliseconds(150)) }
        try await Task.sleep(for: .milliseconds(400))
    }

    // MARK: - Drawing

    /// Draws the palette into `<name>.<dark|light>.png`. The frosted backdrop
    /// is left out (transparent): `scripts/screenshots/compose.sh` blurs the
    /// wallpaper behind it instead, as the window server would.
    func shoot(_ name: String, dark: Bool) throws {
        let window = window(dark: dark)
        let view = window.contentView!
        view.layoutSubtreeIfNeeded()
        let png = try render(view, size: PaletteView.size)
        try png.write(to: output.appending(path: "\(name).\(dark ? "dark" : "light").png"))
    }

    // MARK: - The demo GIF

    private var frames: [(file: String, seconds: Double)] = []

    /// One frame of the GIF, shown for `seconds`.
    func frame(_ seconds: Double = 0.12) throws {
        let name = String(format: "gif/%04d", frames.count)
        try FileManager.default.createDirectory(at: output.appending(path: "gif"), withIntermediateDirectories: true)
        try shoot(name, dark: true)
        frames.append(("\(name).dark.png", seconds))
    }

    /// Types `text` one character at a time, a frame for each.
    func typeFrames(_ text: String, after prefix: String = "") async throws {
        for end in text.indices {
            try await type(prefix + String(text[...end]), wait: .milliseconds(350))
            try frame(0.09)
        }
    }

    /// The frame list for compose.sh: "file seconds" per line.
    func writeFrameList() throws {
        let list = frames.map { "\($0.file) \($0.seconds)" }.joined(separator: "\n") + "\n"
        try list.write(to: output.appending(path: "gif/frames.txt"), atomically: true, encoding: .utf8)
    }

    private func window(dark: Bool) -> NSWindow {
        let appearance: NSAppearance.Name = dark ? .darkAqua : .aqua
        if let window = windows[appearance] { return window }
        let window = NSWindow(
            contentRect: NSRect(origin: CGPoint(x: -6000, y: -6000), size: PaletteView.size),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.appearance = NSAppearance(named: appearance)
        let view = NSHostingView(rootView: PaletteView(model: model, settings: settings))
        view.sizingOptions = []
        window.contentView = view
        window.orderFrontRegardless()
        windows[appearance] = window
        return window
    }

    /// The app icon, as Finder draws it, into `icon.png` (512 pixels).
    func shootIcon() throws {
        let icon = NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
        let size = NSSize(width: 256, height: 256)
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 512, pixelsHigh: 512, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        icon.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        try rep.representation(using: .png, properties: [:])!.write(to: output.appending(path: "icon.png"))
    }

    /// A titled window like the app's own, off screen.
    func makeWindow<Content: View>(size: CGSize, _ content: Content) -> NSWindow {
        // Off screen the window is never key; draw its controls as if it were.
        let window = NSWindow(contentViewController: NSHostingController(
            rootView: content.environment(\.controlActiveState, .key)))
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.setContentSize(size)
        window.setFrameOrigin(CGPoint(x: -8000, y: -8000))
        window.orderFrontRegardless()
        return window
    }

    /// Draws a window's content into `<name>.<dark|light>.window.png`.
    /// compose.sh adds the title bar: the real one draws as inactive, grey
    /// traffic lights and all, since the window is never key. (Switches
    /// still draw grey: their track colour is a layer effect that
    /// `cacheDisplay` leaves out.)
    func shootWindow(_ name: String, _ window: NSWindow, dark: Bool) throws {
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        guard let view = window.contentView else { return }
        view.layoutSubtreeIfNeeded()
        let png = try render(view, size: view.bounds.size, hidingBackdrop: false)
        try png.write(to: output.appending(path: "\(name).\(dark ? "dark" : "light").window.png"))
    }

    private func render(_ view: NSView, size: CGSize, hidingBackdrop: Bool = true) throws -> Data {
        let effects = !hidingBackdrop ? [] : Self.subviews(of: view).compactMap { $0 as? NSVisualEffectView }.filter { $0.blendingMode == .behindWindow }
        let hidden = effects.filter { !$0.isHidden }
        for effect in hidden { effect.isHidden = true }
        defer { for effect in hidden { effect.isHidden = false } }

        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * Self.scale), pixelsHigh: Int(size.height * Self.scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = size
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])!
    }

    private static func subviews(of view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(subviews(of:))
    }
}

/// The palette host for the studio: overlays go to the model, nothing is
/// ever pasted or closed.
@MainActor
final class StudioPaletteHost: PaletteHost {
    let model: PaletteModel
    init(model: PaletteModel) { self.model = model }

    var isVisible: Bool { true }
    var activeModule: ModuleID? { model.activeModule }
    var previousApp: NSRunningApplication? { nil }
    func show() {}
    func open(_ id: ModuleID) { model.open(id) }
    func open(_ id: ModuleID, searching text: String) { model.open(id, searching: text) }
    func toggle(_ id: ModuleID) { model.open(id) }
    func close() {}
    func present(_ overlay: PaletteOverlay) { model.overlay = overlay }
    func focusSearch() { model.focusSearch() }
    func closeAndDeliver(_ action: PasteAction, _ deliver: @escaping @MainActor (NSRunningApplication?) async -> Bool) {}
    func closeAndDeliver(
        _ content: PasteContent, _ action: PasteAction, recording: Paster.Recording, restoringPasteboard: Bool,
        after: (@MainActor (Bool) -> Void)?
    ) {}
    func onShow(_ handler: @escaping () -> Void) {}
}
