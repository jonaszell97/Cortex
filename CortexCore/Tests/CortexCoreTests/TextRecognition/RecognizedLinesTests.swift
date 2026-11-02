import CoreGraphics
import Foundation
import Testing
@testable import CortexCore

@Suite struct RecognizedLinesTests {
    /// A box in a 1000 × 1000 image, `top` measured from the top like on
    /// screen (boxes are stored with the origin at the bottom left).
    static func box(_ text: String, x: CGFloat, top: CGFloat, width: CGFloat = 80, height: CGFloat = 20) -> RecognizedBox {
        RecognizedBox(text: text, bounds: CGRect(x: x, y: 1000 - top - height, width: width, height: height))
    }

    @Test func emptyImage() {
        #expect(RecognizedLines.text(from: []) == "")
    }

    @Test func linesTopToBottom() {
        let boxes = [
            Self.box("third", x: 10, top: 100),
            Self.box("first", x: 10, top: 10),
            Self.box("second", x: 10, top: 50),
        ]
        #expect(RecognizedLines.text(from: boxes) == "first\nsecond\nthird")
    }

    @Test func wordsLeftToRight() {
        let boxes = [
            Self.box("world", x: 100, top: 10),
            Self.box("Hello", x: 10, top: 12),
        ]
        #expect(RecognizedLines.text(from: boxes) == "Hello world")
    }

    @Test func slantedLineStaysOneLine() {
        // Each word a little lower than the one before, as in a photo taken
        // at an angle; the first and last do not overlap each other.
        let boxes = [
            Self.box("one", x: 10, top: 10),
            Self.box("two", x: 100, top: 18),
            Self.box("three", x: 190, top: 26, width: 100, height: 22),
            Self.box("next", x: 10, top: 60),
        ]
        #expect(RecognizedLines.text(from: boxes) == "one two three\nnext")
    }

    @Test func columnsAreSeparatedByTabs() {
        // Two columns read row by row; the wide gap becomes a tab, so a
        // table pastes into Numbers cell by cell.
        let boxes = [
            Self.box("Name", x: 10, top: 10),
            Self.box("Size", x: 500, top: 10),
            Self.box("Cortex", x: 10, top: 40),
            Self.box("12 MB", x: 500, top: 40),
        ]
        #expect(RecognizedLines.text(from: boxes) == "Name\tSize\nCortex\t12 MB")
    }

    @Test func gapIsMeasuredInLineHeights() {
        // 30 px between words is a space for 20 px text, a tab for 10 px text.
        let large = [Self.box("a", x: 10, top: 10, width: 50), Self.box("b", x: 90, top: 10, width: 50)]
        #expect(RecognizedLines.text(from: large) == "a b")
        let small = [
            Self.box("a", x: 10, top: 10, width: 50, height: 10),
            Self.box("b", x: 90, top: 10, width: 50, height: 10),
        ]
        #expect(RecognizedLines.text(from: small) == "a\tb")
    }

    @Test func blankBoxesAreDropped() {
        let boxes = [
            Self.box("  ", x: 10, top: 10),
            Self.box(" kept ", x: 10, top: 50),
        ]
        #expect(RecognizedLines.text(from: boxes) == "kept")
    }
}
