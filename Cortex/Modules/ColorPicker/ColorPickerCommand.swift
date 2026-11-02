import Foundation
import CortexCore

/// `$color`: the eyedropper from the palette, as with ⌃⌥⌘C. It hands over: ⏎
/// only starts picking and returns, so no progress card shows while the user
/// picks; the module copies the colour (Esc copies nothing).
struct ColorPickerCommand: Command {
    let id = "command.color"
    let name = "color"
    let title = "Pick Color"
    let summary = "Shows the eyedropper and copies the color you click."
    let symbol = "eyedropper"
    let verb: String? = "Pick Colour"
    let keywords = ["colour", "picker", "eyedropper", "pipette", "hex", "rgb", "hsl", "pixel"]
    /// Starts the module's pick.
    let startPicking: @MainActor @Sendable () -> Void

    func resolve(_ invocation: CommandInvocation) async throws -> CommandOutcome {
        .handoff(description: summary) { [startPicking] in await startPicking() }
    }
}
