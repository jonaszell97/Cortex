import AppKit
import Testing
@testable import Cortex
import CortexCore

/// Copy bold text from a text view (what TextEdit does), record it, write it
/// back, paste it into another text view: the text must still be bold.
@MainActor
@Suite struct RichTextRoundTripTests {
    let board = TestPasteboard()
    let store: ClipStore

    init() throws {
        store = try makeTestStore()
    }

    func makeTextView() -> NSTextView {
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
        textView.isRichText = true
        textView.importsGraphics = true
        return textView
    }

    @Test func boldSurvivesCopyRecordPaste() async throws {
        let source = makeTextView()
        source.textStorage?.setAttributedString(NSAttributedString(
            string: "Hello bold", attributes: [.font: NSFont.boldSystemFont(ofSize: 13)]))
        source.setSelectedRange(NSRange(location: 0, length: 10))
        #expect(source.writeSelection(to: board.pasteboard, types: source.writablePasteboardTypes))

        let snapshot = try #require(board.snapshot())
        #expect(snapshot.kind == .richText)
        guard case .inserted(let id) = try store.record(snapshot, indexSensitive: true) else {
            Issue.record("expected insert"); return
        }
        let detail = try #require(try await store.detail(id: id))
        Paster.write(detail, mode: .rich, to: board.pasteboard)

        let target = makeTextView()
        #expect(target.readSelection(from: board.pasteboard))
        let pasted = try #require(target.textStorage)
        #expect(pasted.string == "Hello bold")
        let font = try #require(pasted.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        #expect(font.fontDescriptor.symbolicTraits.contains(.bold))
    }
}
