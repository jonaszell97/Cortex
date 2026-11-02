import SwiftUI

/// A feature of Cortex: clipboard history, snippets, quick actions, emoji,
/// symbols, scrolling, sync. Each is created once at launch by `ModuleHost`
/// with its own `ModuleContext`, listed once in `ModuleList`.
///
/// Every member but `manifest` and `init` has a default, so a module
/// implements only what it uses.
@MainActor
protocol CortexModule: AnyObject {
    static var manifest: ModuleManifest { get }

    /// Called once at launch for every module, enabled or not. No side
    /// effects: no taps, timers, watchers or hotkeys here.
    init(context: ModuleContext)

    /// Registered by the host while the module is active; recorders in Settings.
    var hotkeys: [ModuleHotkey] { get }
    /// Simple settings, drawn on the module's page in Settings.
    var options: [ModuleOption] { get }
    /// What options cannot express (imports, lists, set-up flows), shown
    /// below them. Sections, as in a grouped `Form`.
    var settingsView: AnyView? { get }
    /// Pages of their own in Settings, listed under General while the module
    /// is active (Knowledge's Projects).
    var settingsPanes: [SettingsPane] { get }

    /// The module's part of the palette, under its manifest's trigger. nil
    /// for modules that do not hook into the palette.
    var palette: (any PaletteScope)? { get }
    /// The scope of one of the manifest's `subscopes`.
    func palette(_ subscope: ModuleID) -> (any PaletteScope)?
    /// Files dropped onto the palette (or the menu bar icon): true if the
    /// module took them. The first active module that does gets them.
    func acceptsDroppedFiles(_ urls: [URL]) -> Bool

    /// The module's group in the status menu, while it is active. Asked for
    /// whenever the menu opens, and again while it is open when anything
    /// observable it read changes.
    func statusMenuItems() -> [StatusMenuItem]
    /// The menu bar icon the module asks for right now, or nil. Observed like
    /// the menu items.
    var statusIcon: StatusIcon? { get }

    /// The module was enabled (at launch or in Settings): start listeners,
    /// taps, watchers, timers.
    func start() async
    /// The module was disabled: stop everything `start` began and drop what
    /// the palette loaded. Stored data is kept.
    func stop()
}

/// A page a module adds to Settings, beside its own.
struct SettingsPane {
    /// Unique within the module.
    let id: String
    let title: String
    let symbol: String
    let view: AnyView
}

extension CortexModule {
    var hotkeys: [ModuleHotkey] { [] }
    var options: [ModuleOption] { [] }
    var settingsView: AnyView? { nil }
    var settingsPanes: [SettingsPane] { [] }
    var palette: (any PaletteScope)? { nil }
    func palette(_ subscope: ModuleID) -> (any PaletteScope)? { nil }
    func acceptsDroppedFiles(_ urls: [URL]) -> Bool { false }
    func statusMenuItems() -> [StatusMenuItem] { [] }
    var statusIcon: StatusIcon? { nil }
    func start() async {}
    func stop() {}
}
