import AppKit
import Testing
@testable import Cortex
import CortexCore

@MainActor
@Suite struct ClipPreviewTests {
    let store: ClipStore

    init() throws {
        store = try makeTestStore()
    }

    func detail(_ representations: [LoadedRepresentation]) async throws -> ClipDetail {
        let snapshot = ClipSnapshot(representations: representations, plainText: nil, isSensitive: false)
        guard case .inserted(let id) = try store.record(snapshot, indexSensitive: true) else {
            Issue.record("expected insert")
            throw CancellationError()
        }
        return try #require(try await store.detail(id: id))
    }

    /// "Hello there" with "there" bold and red, as TextEdit copies it.
    func helloThereRTF() -> Data {
        let text = NSMutableAttributedString(string: "Hello ", attributes: [.font: NSFont.systemFont(ofSize: 12)])
        text.append(NSAttributedString(string: "there", attributes: [
            .font: NSFont.boldSystemFont(ofSize: 12),
            .foregroundColor: NSColor.red,
        ]))
        return text.rtf(from: NSRange(location: 0, length: text.length), documentAttributes: [:])!
    }

    @Test func richTextKeepsBoldAndDropsColour() async throws {
        let detail = try await detail([
            LoadedRepresentation(type: ClipType.rtf, data: helloThereRTF()),
            LoadedRepresentation(type: ClipType.plainText, data: Data("Hello there".utf8)),
        ])

        let preview = try #require(ClipPreviewView.richPreview(detail))
        #expect(preview.string == "Hello there")
        let hello = try #require(preview.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        let there = try #require(preview.attribute(.font, at: 6, effectiveRange: nil) as? NSFont)
        #expect(!hello.fontDescriptor.symbolicTraits.contains(.bold))
        #expect(there.fontDescriptor.symbolicTraits.contains(.bold))
        #expect(preview.attribute(.foregroundColor, at: 6, effectiveRange: nil) == nil)

        let formatted = try #require(ClipPreviewView.formattedText(detail))
        #expect(String(formatted.characters) == "Hello there")
        #expect(formatted.runs.count == 2)
    }

    @Test func plainTextHasNoRichPreview() async throws {
        let detail = try await detail([LoadedRepresentation(type: ClipType.plainText, data: Data("plain".utf8))])
        #expect(ClipPreviewView.richPreview(detail) == nil)
    }

    /// A text clip that is a colour gets a swatch in the row and the preview;
    /// text that only mentions one, or rich text, does not.
    @Test func colourClipsShowASwatch() async throws {
        let colour = try await detail([LoadedRepresentation(type: ClipType.plainText, data: Data("  #1A2B3C\n".utf8))])
        #expect(ClipPreviewView.color(of: colour) == ColorValue(red255: 26, green255: 43, blue255: 60))
        let summary = try #require(try await store.summaries().first { $0.id == colour.item.id })
        #expect(ClipRowView.color(of: summary) == ColorValue(red255: 26, green255: 43, blue255: 60))

        let mention = try await detail([LoadedRepresentation(type: ClipType.plainText, data: Data("color: #1A2B3C".utf8))])
        #expect(ClipPreviewView.color(of: mention) == nil)
        let rich = try await detail([
            LoadedRepresentation(type: ClipType.rtf, data: helloThereRTF()),
            LoadedRepresentation(type: ClipType.plainText, data: Data("#1A2B3C".utf8)),
        ])
        #expect(ClipPreviewView.color(of: rich) == nil)
    }

    @Test func htmlOnlyFallsBackToPlainText() async throws {
        let detail = try await detail([
            LoadedRepresentation(type: ClipType.html, data: Data("<b>web</b>".utf8)),
            LoadedRepresentation(type: ClipType.plainText, data: Data("web".utf8)),
        ])
        #expect(ClipPreviewView.richPreview(detail) == nil)
    }
}
