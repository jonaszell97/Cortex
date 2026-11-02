import Foundation
import CortexCore

/// `$ocr`: the capture from the palette, as with ⌃⌥⌘T. It hands over: ⏎ only
/// starts the capture and returns, so no progress card shows while the
/// user selects; the module copies the text (Esc copies nothing).
struct TextRecognitionCommand: Command {
    let id = "command.ocr"
    let name = "ocr"
    let title = "Capture Text"
    let summary = "Select a region of the screen and copy the text in it."
    let symbol = "text.viewfinder"
    let verb: String? = "Capture Text"
    let keywords = ["text", "recognize", "recognise", "screenshot", "scan", "copy text", "region"]
    /// Starts the module's capture.
    let startCapture: @MainActor @Sendable () -> Void

    func resolve(_ invocation: CommandInvocation) async throws -> CommandOutcome {
        .handoff(description: summary) { [startCapture] in await startCapture() }
    }
}
