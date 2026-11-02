#if os(macOS)
import Foundation

/// "Recognize Text" (docs/modules/TEXT_RECOGNITION.md, "The quick action"): the
/// text in a copied image, an image clip (⌘K) or image files, to paste or copy.
/// Contributed by the Text Recognition module.
public struct RecognizeTextAction: QuickAction {
    public let id = "image.recognize-text"
    public let title = "Recognize Text"
    public let symbol = "text.viewfinder"
    public let keywords = ["ocr", "text", "scan", "screenshot", "read", "extract", "copy text"]

    let recognizer: any TextRecognizing
    let joinLines: Bool

    public init(recognizer: any TextRecognizing = TextRecognizer(), joinLines: Bool = false) {
        self.recognizer = recognizer
        self.joinLines = joinLines
    }

    public func accepts(_ input: ActionInput) -> Bool {
        switch input {
        case .image: true
        case .files(let urls): !urls.isEmpty && urls.allSatisfy(FileKind.image.matches)
        case .none, .text: false
        }
    }

    /// Read like a capture: a screenshot is what it usually is. Several
    /// files give their texts one after the other, with a blank line between.
    public func run(_ input: ActionInput, context: ActionContext) async throws -> ActionOutput {
        var texts: [String] = []
        switch input {
        case .image(let data):
            texts.append(try await recognizer.recognizeCapture(data, joinLines: joinLines))
        case .files(let urls):
            for (index, url) in urls.enumerated() {
                context.progress(Double(index) / Double(urls.count))
                let data = try Data(contentsOf: url)
                do {
                    texts.append(try await recognizer.recognizeCapture(data, joinLines: joinLines))
                } catch is TextRecognitionError {
                    throw QuickActionError("\(url.lastPathComponent) is not an image Cortex can read")
                }
            }
            context.progress(1)
        case .none, .text:
            throw QuickActionError("Recognize Text needs an image")
        }
        let text = texts.filter { !$0.isEmpty }.joined(separator: "\n\n")
        guard !text.isEmpty else { throw QuickActionError("No text found") }
        return .text(text)
    }
}
#endif
