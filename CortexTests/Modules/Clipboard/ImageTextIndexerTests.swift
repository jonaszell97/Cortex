import Foundation
import Synchronization
import Testing
@testable import Cortex
import CortexCore

/// Reading the text of image clips in the background.
@MainActor
@Suite struct ImageTextIndexerTests {
    /// Answers with the text registered for an image, "" for others, and
    /// remembers what it was asked.
    final class FakeRecognizer: TextRecognizing {
        struct State {
            var texts: [Data: String] = [:]
            var failing: Set<Data> = []
            var asked: [Data] = []
            /// Runs during `recognize`, as if something happened meanwhile.
            var during: (@Sendable () throws -> Void)?
        }

        let state = Mutex(State())

        func recognize(_ image: Data) async throws -> String {
            let (text, fails, during) = state.withLock { state in
                state.asked.append(image)
                return (state.texts[image] ?? "", state.failing.contains(image), state.during)
            }
            try during?()
            if fails { throw TextRecognitionError.unreadableImage }
            return text
        }

        var asked: [Data] { state.withLock(\.asked) }
    }

    @MainActor final class Options {
        var value = ImageTextIndexer.Options(isEnabled: true, indexSensitiveText: true, detectSensitiveText: true)
        var didIndexCalls = 0
    }

    let store: ClipStore
    let recognizer = FakeRecognizer()
    let options = Options()

    init() throws {
        store = try makeTestStore()
    }

    func makeIndexer() -> ImageTextIndexer {
        let options = options
        return ImageTextIndexer(
            store: store, recognizer: recognizer,
            options: { options.value },
            didIndex: { options.didIndexCalls += 1 })
    }

    /// Records an image clip whose recognised text will be `text`.
    @discardableResult
    func recordImage(width: Int, text: String = "", at date: Date = .now) throws -> (id: Int64, png: Data) {
        let png = imageData(.png, width: width)
        recognizer.state.withLock { $0.texts[png] = text }
        let snapshot = ClipSnapshot(
            representations: [LoadedRepresentation(type: ClipType.png, data: png)],
            plainText: nil, isSensitive: false, copiedAt: date)
        guard case .inserted(let id) = try store.record(snapshot, indexSensitive: true) else {
            Issue.record("expected insert")
            throw CancellationError()
        }
        return (id, png)
    }

    func text(of id: Int64) async throws -> String? {
        try await store.detail(id: id)?.item.recognizedText
    }

    @Test func readsImageClipsNewestFirst() async throws {
        let older = try recordImage(width: 10, text: "Boarding pass", at: .now.addingTimeInterval(-60))
        try store.record(textSnapshot("plain text"), indexSensitive: true)
        let newer = try recordImage(width: 20, text: "Invoice October")
        let indexer = makeIndexer()
        await indexer.start()
        await indexer.idle()

        #expect(recognizer.asked == [newer.png, older.png])
        #expect(try await text(of: older.id) == "Boarding pass")
        #expect(try await store.summaries(matching: "invoice").map(\.id) == [newer.id])
        #expect(options.didIndexCalls == 1)
    }

    @Test func eachClipIsReadOnce() async throws {
        let empty = try recordImage(width: 10, text: "")
        let indexer = makeIndexer()
        await indexer.start()
        await indexer.idle()
        #expect(try await text(of: empty.id) == "")

        let later = try recordImage(width: 20, text: "Later")
        await indexer.wake()
        await indexer.idle()
        #expect(recognizer.asked == [empty.png, later.png])
        #expect(try await text(of: later.id) == "Later")
    }

    @Test func anUnreadableImageIsNotTriedAgain() async throws {
        let broken = try recordImage(width: 10)
        recognizer.state.withLock { _ = $0.failing.insert(broken.png) }
        let indexer = makeIndexer()
        await indexer.start()
        await indexer.idle()
        await indexer.wake()
        await indexer.idle()
        #expect(recognizer.asked == [broken.png])
        #expect(try await text(of: broken.id) == "")
    }

    @Test func turnedOffReadsNothingUntilWoken() async throws {
        options.value.isEnabled = false
        let clip = try recordImage(width: 10, text: "Later")
        let indexer = makeIndexer()
        await indexer.start()
        await indexer.idle()
        #expect(recognizer.asked.isEmpty)
        #expect(try await text(of: clip.id) == nil)

        options.value.isEnabled = true
        await indexer.wake()
        await indexer.idle()
        #expect(try await text(of: clip.id) == "Later")
    }

    @Test func nothingIsReadBeforeStartOrAfterStop() async throws {
        let clip = try recordImage(width: 10, text: "Later")
        let indexer = makeIndexer()
        await indexer.wake()
        await indexer.idle()
        #expect(recognizer.asked.isEmpty)

        await indexer.start()
        await indexer.stop()
        await indexer.idle()
        try recordImage(width: 20, text: "Copied while stopped")
        await indexer.wake()
        await indexer.idle()
        #expect(!recognizer.asked.contains(imageData(.png, width: 20)))

        await indexer.start()
        await indexer.idle()
        #expect(try await text(of: clip.id) == "Later")
        #expect(try await store.summaries(matching: "copied").count == 1)
    }

    @Test func secretTextFlagsTheClip() async throws {
        let token = "ghp_" + String(repeating: "a1B2", count: 9)
        let secret = try recordImage(width: 10, text: "Your token: \(token)")
        let indexer = makeIndexer()
        await indexer.start()
        await indexer.idle()
        #expect(try await store.detail(id: secret.id)?.item.isSensitive == true)
    }

    @Test func secretTextStaysUnflaggedWithDetectionOff() async throws {
        options.value.detectSensitiveText = false
        let token = "ghp_" + String(repeating: "a1B2", count: 9)
        let secret = try recordImage(width: 10, text: "Your token: \(token)")
        let indexer = makeIndexer()
        await indexer.start()
        await indexer.idle()
        #expect(try await store.detail(id: secret.id)?.item.isSensitive == false)
        #expect(try await text(of: secret.id) == "Your token: \(token)")
    }

    @Test func aClipDeletedWhileBeingReadStaysDeleted() async throws {
        let clip = try recordImage(width: 10, text: "Gone")
        let store = store
        let id = clip.id
        recognizer.state.withLock { $0.during = { try store.delete(ids: [id]) } }
        let indexer = makeIndexer()
        await indexer.start()
        await indexer.idle()
        #expect(try await store.count() == 0)
    }
}
