import CoreGraphics
import CoreText
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import CortexCore

/// Black text on white, one line per string, drawn from the top left.
func makeTextPNG(
    _ lines: [String], fontSize: CGFloat = 32, width: Int = 1200, height: Int? = nil, top: CGFloat = 40, left: CGFloat = 40
) -> Data {
    let lineHeight = fontSize * 1.5
    let height = height ?? Int(top * 2 + lineHeight * CGFloat(lines.count))
    let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let font = CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
    for (index, text) in lines.enumerated() {
        let string = NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(red: 0, green: 0, blue: 0, alpha: 1),
        ])
        context.textPosition = CGPoint(x: left, y: CGFloat(height) - top - lineHeight * CGFloat(index + 1))
        CTLineDraw(CTLineCreateWithAttributedString(string), context)
    }
    let output = NSMutableData()
    let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    CGImageDestinationFinalize(destination)
    return output as Data
}

/// Black text on white, each string where it is placed (`top` from the top).
func makeLayoutPNG(_ items: [(text: String, x: CGFloat, top: CGFloat)], fontSize: CGFloat = 28, width: Int, height: Int) -> Data {
    let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let font = CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
    for item in items {
        let string = NSAttributedString(string: item.text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(red: 0, green: 0, blue: 0, alpha: 1),
        ])
        context.textPosition = CGPoint(x: item.x, y: CGFloat(height) - item.top - fontSize)
        CTLineDraw(CTLineCreateWithAttributedString(string), context)
    }
    let output = NSMutableData()
    let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    CGImageDestinationFinalize(destination)
    return output as Data
}

@Suite struct CaptureRecognitionTests {
    /// An article: a heading over two columns of wrapped text, the left
    /// one longer.
    static let left = ["Recognition runs on this", "Mac and needs no", "network connection.", "", "Screenshots in the history", "become searchable."]
    static let right = ["The capture hotkey copies", "the words of a region as", "a new clip, like a colour", "picked with the eyedropper."]
    static var article: Data {
        var items: [(text: String, x: CGFloat, top: CGFloat)] = [("Release Notes", 60, 40)]
        for (index, line) in left.enumerated() where !line.isEmpty { items.append((line, 60, 130 + CGFloat(index) * 40)) }
        for (index, line) in right.enumerated() { items.append((line, 640, 130 + CGFloat(index) * 40)) }
        return makeLayoutPNG(items, width: 1200, height: 420)
    }

    @available(macOS 26, *)
    @Test func columnsAreReadOneAfterTheOther() async throws {
        let text = try await TextRecognizer().recognizeCapture(Self.article, joinLines: false)
        let leftEnd = try #require(text.range(of: "become searchable."))
        let rightStart = try #require(text.range(of: "The capture hotkey copies"))
        #expect(text.hasPrefix("Release Notes\n"))
        #expect(leftEnd.upperBound <= rightStart.lowerBound)
        #expect(!text.contains("\t"))
    }

    @available(macOS 26, *)
    @Test func linesOfAParagraphCanBeJoined() async throws {
        let text = try await TextRecognizer().recognizeCapture(Self.article, joinLines: true)
        #expect(text.contains("Screenshots in the history become searchable."))
        #expect(text.contains("The capture hotkey copies the words of a region as a new clip, like a colour picked with the eyedropper."))
    }

    @available(macOS 26, *)
    @Test func aTableBecomesTabSeparatedRows() async throws {
        let rows = [["Name", "Size", "Kind"], ["Cortex.app", "48 MB", "Application"], ["notes.txt", "2 KB", "Text"], ["Screenshot.png", "1.2 MB", "Image"]]
        var items: [(text: String, x: CGFloat, top: CGFloat)] = []
        for (row, cells) in rows.enumerated() {
            for (column, cell) in cells.enumerated() {
                items.append((cell, 60 + CGFloat(column) * 380, 40 + CGFloat(row) * 50))
            }
        }
        let image = makeLayoutPNG(items, fontSize: 26, width: 1200, height: 260)
        let text = try await TextRecognizer().recognizeCapture(image, joinLines: false)
        #expect(text == rows.map { $0.joined(separator: "\t") }.joined(separator: "\n"))
    }

    @Test func aLargeCaptureIsReadInTiles() async throws {
        let lines = ["Recently Deleted", "Shared with you", "Keyboard shortcuts", "Privacy and Security"]
        let image = makeTextPNG(lines, fontSize: 20, width: 4608, height: 2880, top: 1300, left: 2200)
        let text = try await TextRecognizer().recognizeCapture(image, joinLines: true)
        #expect(text == lines.joined(separator: "\n"))
    }

    @Test(arguments: [
        (["recog-", "nition"], "recognition"),
        (["on-", "Device"], "on- Device"),
        (["costs 42 -", "less"], "costs 42 - less"),
        (["  one ", "", "two"], "one two"),
    ])
    func joiningLines(_ lines: [String], _ expected: String) {
        #expect(DocumentText.join(lines) == expected)
    }
}

@Suite struct TextRecognizerTests {
    @Test func linesInReadingOrder() async throws {
        let image = makeTextPNG(["The quick brown fox", "jumps over the lazy dog", "Copied at 10:42"])
        let text = try await TextRecognizer().recognize(image)
        #expect(text == "The quick brown fox\njumps over the lazy dog\nCopied at 10:42")
    }

    @Test func germanWithUmlauts() async throws {
        let image = makeTextPNG(["Grüße aus Köln", "Die Straße ist gesperrt"])
        let text = try await TextRecognizer().recognize(image)
        #expect(text == "Grüße aus Köln\nDie Straße ist gesperrt")
    }

    @Test func chosenLanguage() async throws {
        let image = makeTextPNG(["Übermäßig schöne Größe"])
        let text = try await TextRecognizer(languages: [Locale.Language(identifier: "de-DE")]).recognize(image)
        #expect(text == "Übermäßig schöne Größe")
    }

    @Test func smallTextInAWholeScreenshot() async throws {
        // 22 px text on a 2880 × 1800 Retina screen, like a sidebar entry.
        let image = makeTextPNG(["Downloads", "Recently Deleted"], fontSize: 22, width: 2880, height: 1800)
        let text = try await TextRecognizer().recognize(image)
        #expect(text == "Downloads\nRecently Deleted")
    }

    @Test func smallTextOnA5KScreen() async throws {
        // Read whole, Vision finds hardly any of this.
        let lines = ["Recently Deleted", "Shared with you", "Keyboard shortcuts", "Privacy and Security"]
        let image = makeTextPNG(lines, fontSize: 20, width: 4608, height: 2880, top: 1300, left: 2200)
        let text = try await TextRecognizer().recognize(image)
        #expect(text == lines.joined(separator: "\n"))
    }

    @Test func lineAcrossTilesIsReadOnce() async throws {
        // 2880 px wide is read in three tiles; this line crosses both seams.
        let line = "The quick brown fox jumps over the lazy dog while the October invoice is still open"
        let image = makeTextPNG([line], fontSize: 28, width: 2880, height: 1800, top: 600, left: 600)
        let text = try await TextRecognizer().recognize(image)
        #expect(text == line)
    }

    @Test func noText() async throws {
        let text = try await TextRecognizer().recognize(makePNG(width: 400, height: 300))
        #expect(text == "")
    }

    @Test func notAnImage() async {
        await #expect(throws: TextRecognitionError.self) {
            try await TextRecognizer().recognize(Data("not an image".utf8))
        }
    }

    @Test func oneTileUpToTheTileSize() {
        #expect(TextRecognizer.tiles(length: 1200) == [.init(start: 0, length: 1200, coreStart: 0, coreEnd: 1200)])
        #expect(TextRecognizer.tiles(length: 300) == [.init(start: 0, length: 300, coreStart: 0, coreEnd: 300)])
    }

    @Test(arguments: [1201, 1800, 2880, 4608, 6016])
    func tilesCoverTheImage(_ length: Int) {
        let tiles = TextRecognizer.tiles(length: length)
        #expect(tiles.count > 1)
        #expect(tiles.first?.start == 0)
        #expect(tiles.last.map { $0.start + $0.length } == length)
        for tile in tiles {
            #expect(tile.length == TextRecognizer.tileSize)
            #expect(tile.coreStart >= tile.start && tile.coreEnd <= tile.start + tile.length)
        }
        for (previous, next) in zip(tiles, tiles.dropFirst()) {
            #expect(previous.start + previous.length - next.start >= TextRecognizer.tileOverlap)
            // The cores split the image without gaps or overlaps.
            #expect(previous.coreEnd == next.coreStart)
        }
        #expect(tiles.first?.coreStart == 0)
        #expect(tiles.last?.coreEnd == length)
    }

    @Test func supportedLanguagesIncludeGerman() {
        #expect(TextRecognizer.supportedLanguages.contains { $0.languageCode == .german })
    }
}
