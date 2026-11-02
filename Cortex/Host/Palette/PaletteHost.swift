import AppKit
import CortexCore

/// What a module or its scope can do with the palette panel
/// (docs/ARCHITECTURE.md, "PaletteHost"). `PanelController` provides it.
@MainActor
protocol PaletteHost: AnyObject {
    var isVisible: Bool { get }
    /// The module whose scope is showing.
    var activeModule: ModuleID? { get }
    /// The app that was frontmost when the palette opened; pastes go there.
    var previousApp: NSRunningApplication? { get }

    /// Shows the palette with an empty query.
    func show()
    /// Shows the palette on a module's scope: the query becomes its trigger.
    /// Already there, the scope searches again.
    func open(_ id: ModuleID)
    /// `open` with `text` typed after the trigger: the calculator's ⇥ puts
    /// a result back into the field.
    func open(_ id: ModuleID, searching text: String)
    /// `open`, or close the palette if that scope is already showing.
    func toggle(_ id: ModuleID)
    func close()
    func present(_ overlay: PaletteOverlay)
    /// Back to the search field (after an option field had focus).
    func focusSearch()

    /// Closes the palette and runs `deliver` on the app it was opened over;
    /// asks for Accessibility if a paste failed for want of it. `deliver`
    /// returns false for that case.
    func closeAndDeliver(_ action: PasteAction, _ deliver: @escaping @MainActor (NSRunningApplication?) async -> Bool)
    /// `closeAndDeliver` for content that is ready: pastes or copies it.
    /// `recording` says whether the history keeps it; `after` learns whether
    /// it was delivered.
    func closeAndDeliver(
        _ content: PasteContent, _ action: PasteAction, recording: Paster.Recording, restoringPasteboard: Bool,
        after: (@MainActor (Bool) -> Void)?)

    /// Called on every show (Sync checks whether it is stale).
    func onShow(_ handler: @escaping () -> Void)
}
