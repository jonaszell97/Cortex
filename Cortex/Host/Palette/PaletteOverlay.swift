import SwiftUI

/// Something that takes over the pane for a moment, such as a snippet's
/// fill-in form: the search field is disabled, the overlay has its own keys,
/// and Esc leaves it first. Any scope can present one through
/// `PaletteHost.present(_:)`.
struct PaletteOverlay {
    enum Escape {
        /// Back to the scope.
        case dismiss
        /// Close the palette (it was opened just for this overlay, as by
        /// keyword expansion).
        case closePalette
    }

    let body: AnyView
    /// Hints for the activations `activate` handles, in hint order.
    let activationHints: [PaletteHint]
    /// Hints that follow what the overlay shows (a form's ⏎ says what it
    /// will do); used instead of `activationHints` when set.
    var currentHints: (@MainActor () -> [PaletteHint])?
    var keys: [PaletteKey] = []
    /// ⏎ and friends. Typing and ⇥ belong to the overlay's own fields.
    let activate: @MainActor (PaletteActivation) -> Void
    let escape: Escape
    /// The arrow keys, before the focused field sees them (a form's
    /// suggestion list). false, or nil: the field gets them.
    var move: (@MainActor (PaletteStep) -> Bool)?
    /// Files dropped onto the palette while the overlay shows (a form's
    /// path field). false, or nil: the modules get them as usual.
    var dropFiles: (@MainActor ([URL]) -> Bool)?
    /// The overlay is gone: Esc went back to the scope, or the palette took
    /// it away (another module opened, it was shown again or hidden).
    var dismissed: (@MainActor () -> Void)?
}
