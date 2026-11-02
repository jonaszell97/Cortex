import AppKit
import Testing
@testable import Cortex
import CortexCore

/// Writing a clip back to the pasteboard.
@MainActor
@Suite struct PasterTests {
    let board = TestPasteboard()
    let store: ClipStore

    init() throws {
        store = try makeTestStore()
    }

    /// Records what is on the test pasteboard and loads it back like the
    /// palette does before pasting.
    func recordAndLoad() async throws -> (ClipSnapshot, ClipDetail) {
        let snapshot = try #require(board.snapshot())
        guard case .inserted(let id) = try store.record(snapshot, indexSensitive: true) else {
            Issue.record("expected insert")
            throw CancellationError()
        }
        return (snapshot, try #require(try await store.detail(id: id)))
    }

    var types: Set<String> { Set((board.pasteboard.types ?? []).map(\.rawValue)) }

    @Test func richRoundTripKeepsContent() async throws {
        board.write([(.rtf, rtfData("Bold")), (.html, Data("<b>Bold</b>".utf8)), (.string, Data("Bold".utf8))])
        let (original, detail) = try await recordAndLoad()

        Paster.write(detail, mode: .rich, to: board.pasteboard)

        #expect(types.isSuperset(of: [ClipType.rtf, ClipType.html, ClipType.plainText]))
        #expect(board.snapshot()?.contentHash == original.contentHash)
    }

    @Test func plainModeWritesOnlyText() async throws {
        board.write([(.rtf, rtfData("Bold")), (.string, Data("Bold".utf8))])
        let (_, detail) = try await recordAndLoad()

        Paster.write(detail, mode: .plainText, to: board.pasteboard)

        #expect(!types.contains(ClipType.rtf))
        #expect(board.pasteboard.string(forType: .string) == "Bold")
    }

    @Test func plainModeOnAnImageWritesItsText() async throws {
        board.write([(.png, imageData(.png))])
        let (_, detail) = try await recordAndLoad()
        let id = try #require(detail.item.id)
        try store.setRecognizedText("Boarding pass\nGate B12", id: id, indexSensitive: true)
        let withText = try #require(try await store.detail(id: id))

        Paster.write(withText, mode: .plainText, to: board.pasteboard)
        #expect(board.pasteboard.string(forType: .string) == "Boarding pass\nGate B12")
        #expect(!types.contains(ClipType.png))

        Paster.write(withText, mode: .rich, to: board.pasteboard)
        #expect(types.contains(ClipType.png))
    }

    @Test func plainModeOnAnImageWithoutTextWritesTheImage() async throws {
        board.write([(.png, imageData(.png))])
        let (_, detail) = try await recordAndLoad()
        let id = try #require(detail.item.id)
        try store.setRecognizedText("", id: id, indexSensitive: true)
        let read = try #require(try await store.detail(id: id))

        Paster.write(read, mode: .plainText, to: board.pasteboard)
        #expect(types.contains(ClipType.png))
    }

    @Test func imagesAlsoGetTIFF() async throws {
        board.write([(.png, imageData(.png))])
        let (original, detail) = try await recordAndLoad()

        Paster.write(detail, mode: .rich, to: board.pasteboard)

        #expect(types.isSuperset(of: [ClipType.png, ClipType.tiff]))
        #expect(board.snapshot()?.contentHash == original.contentHash)
    }

    @Test func filesRoundTrip() async throws {
        let urls = [URL(filePath: "/tmp/one.txt"), URL(filePath: "/tmp/two words.txt")]
        board.pasteboard.clearContents()
        board.pasteboard.writeObjects(urls.map { $0 as NSURL })
        let (original, detail) = try await recordAndLoad()

        Paster.write(detail, mode: .rich, to: board.pasteboard)

        let pasted = board.pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        #expect(pasted == urls)
        #expect(board.snapshot()?.contentHash == original.contentHash)
    }

    @Test func filesAsPlainTextPasteTheirPaths() async throws {
        board.pasteboard.clearContents()
        board.pasteboard.writeObjects([URL(filePath: "/tmp/one.txt") as NSURL])
        let (_, detail) = try await recordAndLoad()

        Paster.write(detail, mode: .plainText, to: board.pasteboard)

        #expect(board.pasteboard.string(forType: .string) == "/tmp/one.txt")
    }

    @Test func marksOwnWrites() async throws {
        board.write([(.string, Data("x".utf8))])
        let (_, detail) = try await recordAndLoad()

        Paster.write(detail, mode: .rich, to: board.pasteboard)

        #expect(types.contains(Paster.ownMarkerType.rawValue))
        #expect(board.pasteboard.string(forType: Paster.sourceType) == Bundle.main.bundleIdentifier)
    }

    @Test func writesSnippetTextAsOwnPlainText() {
        Paster.write(text: "Best regards", to: board.pasteboard)
        #expect(board.pasteboard.string(forType: .string) == "Best regards")
        #expect(types.contains(Paster.ownMarkerType.rawValue))
        #expect(!types.contains(NSPasteboard.PasteboardType.rtf.rawValue))
    }

    @Test func restoresWhatAnExpansionReplaced() {
        let rtf = rtfData("Before")
        board.write([(.rtf, rtf), (.string, Data("Before".utf8))])
        let saved = Paster.save(board.pasteboard)

        Paster.write(text: "snippet", to: board.pasteboard)
        Paster.restore(saved, ifUnchangedSince: board.pasteboard.changeCount, to: board.pasteboard)

        #expect(board.pasteboard.string(forType: .string) == "Before")
        #expect(board.pasteboard.data(forType: .rtf) == rtf)
        #expect(types.contains(Paster.ownMarkerType.rawValue), "the restore is not recorded as a new copy")
    }

    @Test func sensitiveClipsStayConcealed() async throws {
        board.write([(.string, Data("hunter2".utf8)), (Paster.concealedType, Data())])
        let (snapshot, detail) = try await recordAndLoad()
        #expect(snapshot.isSensitive)

        Paster.write(detail, mode: .rich, to: board.pasteboard)

        #expect(types.isSuperset(of: [Paster.concealedType.rawValue, Paster.ownMarkerType.rawValue]))
        #expect(board.pasteboard.string(forType: .string) == "hunter2")
    }

    @Test func ordinaryClipsAreNotConcealed() async throws {
        board.write([(.string, Data("hello".utf8))])
        let (_, detail) = try await recordAndLoad()
        Paster.write(detail, mode: .rich, to: board.pasteboard)
        #expect(!types.contains(Paster.concealedType.rawValue))
    }

    @Test func sensitiveResultsAreConcealed() {
        Paster.write(text: "HUNTER2", recording: .record(sensitive: true), to: board.pasteboard)
        #expect(types.contains(Paster.concealedType.rawValue))
        #expect(!types.contains(Paster.ownMarkerType.rawValue), "a result is recorded")
    }

    @Test func savedContentsKnowWhetherTheyAreSensitive() {
        board.write([(.string, Data("hunter2".utf8)), (Paster.concealedType, Data())])
        #expect(Paster.save(board.pasteboard).isSensitive)
        board.write([(.string, Data("x".utf8)), (Paster.sourceType, Data("com.bitwarden.desktop".utf8))])
        #expect(Paster.save(board.pasteboard).isSensitive)
        board.write([(.string, Data("hello".utf8))])
        #expect(!Paster.save(board.pasteboard).isSensitive)
    }

    @Test func restoringSensitiveContentsKeepsThemConcealed() {
        board.write([(.string, Data("hunter2".utf8)), (Paster.concealedType, Data())])
        let saved = Paster.save(board.pasteboard)
        Paster.write(text: "snippet", to: board.pasteboard)
        Paster.restore(saved, ifUnchangedSince: board.pasteboard.changeCount, to: board.pasteboard)
        #expect(board.pasteboard.string(forType: .string) == "hunter2")
        #expect(types.contains(Paster.concealedType.rawValue))
    }

    @Test func aLoanCountsOnlyReadsAfterItIsArmed() {
        let loan = Paster.lend([.string: Data("snippet".utf8)], to: board.pasteboard)
        #expect(types.isSuperset(of: [
            Paster.ownMarkerType.rawValue, Paster.transientType.rawValue, NSPasteboard.PasteboardType.string.rawValue,
        ]))
        #expect(!types.contains(Paster.concealedType.rawValue))

        // A clipboard manager reading before ⌘V is posted doesn't count.
        #expect(board.pasteboard.string(forType: .string) == "snippet")
        #expect(!loan.wasRead)

        let second = Paster.lend([.string: Data("again".utf8)], to: board.pasteboard)
        second.arm()
        #expect(board.pasteboard.string(forType: .string) == "again")
        #expect(second.wasRead)
    }

    @Test func aSensitiveLoanIsConcealed() {
        _ = Paster.lend([.string: Data("HUNTER2".utf8)], concealed: true, to: board.pasteboard)
        #expect(types.contains(Paster.concealedType.rawValue))
    }

    @Test func sensitiveContentExpiresUnlessReplaced() async throws {
        Paster.write(text: "hunter2", to: board.pasteboard)
        Paster.expire(board.pasteboard, after: .milliseconds(50))
        try await Task.sleep(for: .milliseconds(300))
        #expect(board.pasteboard.string(forType: .string) == nil)

        Paster.write(text: "hunter2", to: board.pasteboard)
        Paster.expire(board.pasteboard, after: .milliseconds(50))
        board.write([(.string, Data("copied meanwhile".utf8))])
        try await Task.sleep(for: .milliseconds(300))
        #expect(board.pasteboard.string(forType: .string) == "copied meanwhile")
    }

    @Test func doesNotRestoreOverANewerCopy() {
        board.write([(.string, Data("Before".utf8))])
        let saved = Paster.save(board.pasteboard)
        Paster.write(text: "snippet", to: board.pasteboard)
        let written = board.pasteboard.changeCount

        board.write([(.string, Data("copied meanwhile".utf8))])
        Paster.restore(saved, ifUnchangedSince: written, to: board.pasteboard)

        #expect(board.pasteboard.string(forType: .string) == "copied meanwhile")
    }
}
