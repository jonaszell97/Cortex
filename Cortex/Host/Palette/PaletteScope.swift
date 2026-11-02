import AppKit
import SwiftUI

/// A module's part of the palette (docs/ARCHITECTURE.md, "The palette contract"):
/// what the query means, the results and their selection, the view, and what ⏎
/// and the other keys do. The host owns the panel, the search field, trigger
/// resolution, key dispatch, Esc and the hints bar.
///
/// No associated types, so the host can keep `any PaletteScope`; each module
/// keeps its item types and state inside its own scope.
@MainActor
protocol PaletteScope: AnyObject {
    /// The query without the trigger, on every edit while this scope is
    /// active and when it becomes active.
    func search(_ text: String)
    /// The user switched to another scope. Loaded content may stay until
    /// `clear` (the scope may come back before the palette hides).
    func didLeave()
    /// The palette was hidden: drop loaded content. No clip content may stay
    /// in memory while hidden.
    func clear()

    /// What fills the pane between the search field and the hints: a view
    /// that holds the scope (so it observes it), built from the shared
    /// layouts (`PaletteSplitLayout`, `PaletteGridLayout`).
    var body: AnyView { get }

    /// `.list`: ↑↓ move, ←→ stay with the search field. `.grid`: ←→ move
    /// too, and the hints bar says so.
    var navigation: PaletteNavigation { get }
    func move(_ step: PaletteStep)

    /// ⏎, ⇧⏎, ⌥⏎, ⌥⇧⏎ on the selection, ⌘1–9 (with ⇧) on a position, and a
    /// double click. false: nothing to do (the key goes to the field).
    func activate(_ activation: PaletteActivation, target: PaletteTarget) -> Bool
    /// The hints for the activations this scope supports, in hint order.
    var activationHints: [PaletteHint] { get }

    /// Everything else (⌘P, ⌘⌫, ⌘E, ⌘K, ⇥), matched before the search field
    /// sees the key. Each key with a hint shows up in the hints bar, after
    /// `activationHints`.
    var keys: [PaletteKey] { get }

    /// ⌥ held or released (Clipboard reveals sensitive clips).
    func modifiersChanged(_ flags: NSEvent.ModifierFlags)
    /// Esc. true: the scope used it (to step back inside it);
    /// false: the palette closes.
    func cancel() -> Bool
}

extension PaletteScope {
    func didLeave() {}
    var navigation: PaletteNavigation { .list }
    var keys: [PaletteKey] { [] }
    func modifiersChanged(_ flags: NSEvent.ModifierFlags) {}
    func cancel() -> Bool { false }
}

enum PaletteNavigation: Equatable {
    case list
    case grid(columns: Int)
}

/// An arrow key: ↑↓ are `vertical`, ←→ `sideways` (only for grids).
enum PaletteStep: Equatable {
    case vertical(Int)
    case sideways(Int)
}

/// Return with its modifiers (or ⌘1–9 with or without ⇧, or a double click).
enum PaletteActivation: Hashable {
    case primary, shift, option, optionShift

    init(_ modifiers: NSEvent.ModifierFlags) {
        let flags = modifiers.intersection(.deviceIndependentFlagsMask)
        switch (flags.contains(.option), flags.contains(.shift)) {
        case (true, true): self = .optionShift
        case (true, false): self = .option
        case (false, true): self = .shift
        case (false, false): self = .primary
        }
    }

    /// ⌥: only copy, never paste.
    var isCopy: Bool { self == .option || self == .optionShift }
    var hasShift: Bool { self == .shift || self == .optionShift }

    var symbol: String {
        switch self {
        case .primary: "⏎"
        case .shift: "⇧⏎"
        case .option: "⌥⏎"
        case .optionShift: "⌥⇧⏎"
        }
    }
}

enum PaletteTarget: Hashable {
    case selected
    /// 0-based position in the list or grid (⌘1 is 0).
    case position(Int)
}

/// One entry of the hints bar: the keys and what they do.
struct PaletteHint: Equatable {
    let keys: String
    let label: String

    init(keys: String, label: String) {
        self.keys = keys
        self.label = label
    }

    init(_ activation: PaletteActivation, _ label: String) {
        self.init(keys: activation.symbol, label: label)
    }

    /// ⌘1–9.
    static func positions(_ label: String) -> PaletteHint {
        PaletteHint(keys: "⌘1–9", label: label)
    }

    static let move = PaletteHint(keys: "←→↑↓", label: "Move")

    static func escape(_ label: String) -> PaletteHint {
        PaletteHint(keys: "esc", label: label)
    }
}

/// A key a scope or overlay handles itself.
struct PaletteKey {
    let combo: KeyCombo
    /// nil: works, but is not shown in the hints bar.
    let hint: String?
    /// false lets the key through to the search field after all. nil: a hint
    /// only (⌥ Reveal, or ⇥ that the form's fields handle).
    let perform: (@MainActor () -> Bool)?

    init(_ combo: KeyCombo, hint: String? = nil, perform: (@MainActor () -> Bool)? = nil) {
        self.combo = combo
        self.hint = hint
        self.perform = perform
    }
}
