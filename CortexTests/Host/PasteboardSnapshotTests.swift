import AppKit
import Testing
@testable import Cortex
import CortexCore

/// What `PasteboardReader` makes of different kinds of pasteboard content.
@MainActor
@Suite struct PasteboardSnapshotTests {
    let board = TestPasteboard()

    @Test func plainText() throws {
        board.write([(.string, Data("hello".utf8))])
        let snapshot = try #require(board.snapshot())
        #expect(snapshot.kind == .text)
        #expect(snapshot.representations.map(\.type) == [ClipType.plainText])
        #expect(snapshot.plainText == "hello")
        #expect(snapshot.sourceBundleID == "com.apple.TextEdit")
        #expect(snapshot.sourceAppName == "TextEdit")
        #expect(!snapshot.isSensitive)
    }

    @Test func richTextKeepsRTFAndPlainText() throws {
        board.write([(.rtf, rtfData("Bold")), (.string, Data("Bold".utf8))])
        let snapshot = try #require(board.snapshot())
        #expect(snapshot.kind == .richText)
        #expect(snapshot.representations.map(\.type) == [ClipType.rtf, ClipType.plainText])
    }

    @Test func plainTextIsDerivedFromRTF() throws {
        board.write([(.rtf, rtfData("Only RTF"))])
        let snapshot = try #require(board.snapshot())
        #expect(snapshot.plainText == "Only RTF")
        #expect(snapshot.representations.map(\.type) == [ClipType.rtf, ClipType.plainText])
    }

    @Test func browserHTML() throws {
        board.write([(.html, Data("<b>web</b>".utf8)), (.string, Data("web".utf8))])
        let snapshot = try #require(board.snapshot(source: .safari))
        #expect(snapshot.kind == .richText)
        #expect(snapshot.representations.map(\.type) == [ClipType.html, ClipType.plainText])
    }

    @Test func pngIsKeptAsIs() throws {
        let png = imageData(.png)
        board.write([(.png, png)])
        let snapshot = try #require(board.snapshot())
        #expect(snapshot.kind == .image)
        #expect(snapshot.representations.map(\.data) == [png])
    }

    @Test func tiffIsConvertedToPNG() throws {
        board.write([(.tiff, imageData(.tiff))])
        let snapshot = try #require(board.snapshot())
        #expect(snapshot.kind == .image)
        #expect(snapshot.representations.map(\.type) == [ClipType.png])
        #expect(snapshot.representations.first?.data.prefix(8) == pngSignature)
    }

    @Test func jpegIsConvertedToPNG() throws {
        board.write([(.init("public.jpeg"), imageData(.jpeg))])
        let snapshot = try #require(board.snapshot())
        #expect(snapshot.kind == .image)
        #expect(snapshot.representations.first?.data.prefix(8) == pngSignature)
    }

    @Test func wordStyleCopyIsTextWithPicture() throws {
        board.write([(.png, imageData(.png)), (.rtf, rtfData("Doc")), (.string, Data("Doc".utf8))])
        let snapshot = try #require(board.snapshot())
        #expect(snapshot.kind == .richText)
        #expect(snapshot.representations.map(\.type) == [ClipType.png, ClipType.rtf, ClipType.plainText])
    }

    @Test func filesKeepOnlyTheirURLs() throws {
        let urls = [URL(filePath: "/tmp/a report.pdf"), URL(filePath: "/tmp/b.png")]
        board.pasteboard.clearContents()
        board.pasteboard.writeObjects(urls.map { $0 as NSURL })
        let snapshot = try #require(board.snapshot(source: .init(bundleID: "com.apple.finder", name: "Finder")))
        #expect(snapshot.kind == .files)
        #expect(snapshot.representations.map(\.type) == [ClipType.fileURL])
        #expect(snapshot.representations.first.map { String(decoding: $0.data, as: UTF8.self) }
                == urls.map(\.absoluteString).joined(separator: "\n"))
    }

    @Test func concealedTypeMarksSensitive() throws {
        board.write([(.string, Data("hunter2".utf8)), (.init("org.nspasteboard.ConcealedType"), Data())])
        let snapshot = try #require(board.snapshot())
        #expect(snapshot.isSensitive)
        #expect(snapshot.plainText == "hunter2", "sensitive items are still recorded")
    }

    @Test func passwordManagerMarksSensitive() throws {
        board.write([(.string, Data("token".utf8))])
        let snapshot = try #require(board.snapshot(source: .init(bundleID: "com.1password.1password", name: "1Password")))
        #expect(snapshot.isSensitive)
    }

    @Test func writerNamedOnPasteboardBeatsFrontmostApp() throws {
        board.write([(.string, Data("x".utf8)), (Paster.sourceType, Data("com.apple.TextEdit".utf8))])
        let snapshot = try #require(board.snapshot(source: .safari))
        #expect(snapshot.sourceBundleID == "com.apple.TextEdit")
        #expect(snapshot.sourceAppName == "TextEdit")
    }

    @Test func unsupportedContentIsSkipped() {
        board.write([(.init("com.example.private"), Data("x".utf8))])
        #expect(board.snapshot() == nil)
    }
}

/// Safari's "Copy Image": TIFF, an RTFD holding only the picture, a web
/// archive and HTML, but no plain text.
@MainActor
@Suite struct SafariCopyImageTests {
    let board = TestPasteboard()

    func writeSafariStyleImage() {
        let tiff = imageData(.tiff)
        let attachment = NSTextAttachment(data: imageData(.png), ofType: "public.png")
        let rich = NSAttributedString(attachment: attachment)
        let rtfd = rich.rtfd(from: NSRange(location: 0, length: rich.length), documentAttributes: [:])!
        board.write([
            (.tiff, tiff),
            (.init("com.apple.flat-rtfd"), rtfd),
            (.init("com.apple.webarchive"), Data(repeating: 0, count: 64)),
            (.html, Data(#"<img src="https://example.com/a.png">"#.utf8)),
        ])
    }

    @Test func isRecordedAsImage() throws {
        writeSafariStyleImage()
        let snapshot = try #require(board.snapshot(source: .safari))
        #expect(snapshot.kind == .image)
        #expect(snapshot.representations.first?.type == ClipType.png)
    }

    @Test func showsAsImageWithThumbnail() async throws {
        writeSafariStyleImage()
        let store = try makeTestStore()
        let snapshot = try #require(board.snapshot(source: .safari))
        guard case .inserted(let id) = try store.record(snapshot, indexSensitive: true) else {
            Issue.record("expected insert"); return
        }
        let detail = try #require(try await store.detail(id: id))
        #expect(detail.item.thumbnail != nil)
        #expect(detail.item.preview.hasPrefix("Image "))
        #expect(ClipPreviewView.displayKind(detail) == .image)
    }

    @Test func olderRichTextRecordShowsItsImage() async throws {
        // Recorded as rich text before the fix: PNG and RTFD, no text.
        let store = try makeTestStore()
        let png = imageData(.png)
        let snapshot = ClipSnapshot(
            representations: [LoadedRepresentation(type: ClipType.png, data: png)], plainText: nil, isSensitive: false)
        guard case .inserted(let id) = try store.record(snapshot, indexSensitive: true) else {
            Issue.record("expected insert"); return
        }
        var detail = try #require(try await store.detail(id: id))
        let rich = NSAttributedString(attachment: NSTextAttachment(data: png, ofType: "public.png"))
        detail.item.kind = .richText
        detail.representations.append(LoadedRepresentation(
            type: ClipType.flatRTFD,
            data: rich.rtfd(from: NSRange(location: 0, length: rich.length), documentAttributes: [:])!))

        #expect(ClipPreviewView.displayKind(detail) == .image)
    }
}
