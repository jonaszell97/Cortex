import AppKit
@testable import Cortex
import CortexCore

/// A palette that records what scopes ask of it instead of showing a panel
/// or pasting.
@MainActor
final class FakePaletteHost: PaletteHost {
    struct Delivery {
        var content: PasteContent?
        var action: PasteAction
        var recording: Paster.Recording = .skip
        var restoringPasteboard: Bool
    }

    var isVisible = true
    var activeModule: ModuleID?
    var previousApp: NSRunningApplication?
    private(set) var opened: [ModuleID] = []
    /// What `open(_:searching:)` put after the trigger, in order.
    private(set) var searches: [String] = []
    private(set) var closes = 0
    private(set) var overlays: [PaletteOverlay] = []
    private(set) var deliveries: [Delivery] = []
    private(set) var focusRequests = 0
    /// What `closeAndDeliver` with a closure reports back.
    var delivers = true
    /// `closeAndDeliver` work, run by `delivered()`.
    private var pending: [@MainActor (NSRunningApplication?) async -> Bool] = []

    func show() { isVisible = true }
    func open(_ id: ModuleID) {
        isVisible = true
        activeModule = id
        opened.append(id)
    }
    func open(_ id: ModuleID, searching text: String) {
        open(id)
        searches.append(text)
    }
    func toggle(_ id: ModuleID) { open(id) }
    func close() {
        isVisible = false
        closes += 1
    }
    func present(_ overlay: PaletteOverlay) { overlays.append(overlay) }
    func focusSearch() { focusRequests += 1 }

    func closeAndDeliver(_ action: PasteAction, _ deliver: @escaping @MainActor (NSRunningApplication?) async -> Bool) {
        close()
        deliveries.append(Delivery(content: nil, action: action, restoringPasteboard: false))
        pending.append(deliver)
    }

    func closeAndDeliver(
        _ content: PasteContent, _ action: PasteAction, recording: Paster.Recording, restoringPasteboard: Bool,
        after: (@MainActor (Bool) -> Void)?
    ) {
        close()
        deliveries.append(
            Delivery(content: content, action: action, recording: recording, restoringPasteboard: restoringPasteboard))
        after?(delivers)
    }

    /// Runs the work handed to `closeAndDeliver`, as the panel would after
    /// closing.
    func delivered() async {
        let work = pending
        pending = []
        for deliver in work { _ = await deliver(nil) }
    }

    func onShow(_ handler: @escaping () -> Void) {}
}

extension PasteContent {
    var text: String? {
        if case .text(let text) = self { return text }
        return nil
    }

    var isImage: Bool {
        if case .image = self { return true }
        return false
    }
}
