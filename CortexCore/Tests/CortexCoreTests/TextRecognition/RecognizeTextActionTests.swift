import Foundation
import Synchronization
import Testing
@testable import CortexCore

@Suite struct RecognizeTextActionTests {
    /// Answers with the text registered for an image; data it does not
    /// know is not an image.
    final class FakeRecognizer: TextRecognizing {
        let texts: [Data: String]
        let joins = Mutex<[Bool]>([])

        init(_ texts: [Data: String]) {
            self.texts = texts
        }

        func recognize(_ image: Data) async throws -> String {
            try await recognizeCapture(image, joinLines: false)
        }

        func recognizeCapture(_ image: Data, joinLines: Bool) async throws -> String {
            joins.withLock { $0.append(joinLines) }
            guard let text = texts[image] else { throw TextRecognitionError.unreadableImage }
            return text
        }
    }

    let directory: URL
    let context: ActionContext

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appending(path: "CortexCoreTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        context = ActionContext(fallbackOutputDirectory: directory, temporaryDirectory: directory)
    }

    func file(_ name: String, _ data: Data) throws -> URL {
        let url = directory.appending(path: name)
        try data.write(to: url)
        return url
    }

    @Test func acceptsImagesAndImageFiles() throws {
        let action = RecognizeTextAction(recognizer: FakeRecognizer([:]))
        #expect(action.accepts(.image(makePNG())))
        #expect(action.accepts(.files([URL(filePath: "/tmp/a.png"), URL(filePath: "/tmp/b.HEIC")])))
        #expect(!action.accepts(.files([URL(filePath: "/tmp/a.png"), URL(filePath: "/tmp/notes.txt")])))
        #expect(!action.accepts(.files([])))
        #expect(!action.accepts(.text("Hello")))
        #expect(!action.accepts(.none))
    }

    @Test func readsAnImage() async throws {
        let png = makePNG()
        let recognizer = FakeRecognizer([png: "Gate B12"])
        let action = RecognizeTextAction(recognizer: recognizer, joinLines: true)
        #expect(try await action.run(.image(png), context: context) == .text("Gate B12"))
        #expect(recognizer.joins.withLock { $0 } == [true])
    }

    @Test func readsFilesOneAfterTheOther() async throws {
        let first = makePNG(width: 10), second = makePNG(width: 20), blank = makePNG(width: 30)
        let action = RecognizeTextAction(recognizer: FakeRecognizer([first: "One", second: "Two", blank: ""]))
        let urls = [try file("1.png", first), try file("blank.png", blank), try file("2.png", second)]
        #expect(try await action.run(.files(urls), context: context) == .text("One\n\nTwo"))
    }

    @Test func noTextIsAnError() async throws {
        let png = makePNG()
        let action = RecognizeTextAction(recognizer: FakeRecognizer([png: ""]))
        await #expect(throws: QuickActionError("No text found")) {
            try await action.run(.image(png), context: context)
        }
    }

    @Test func anUnreadableFileIsNamed() async throws {
        let action = RecognizeTextAction(recognizer: FakeRecognizer([:]))
        let url = try file("broken.png", Data("not an image".utf8))
        await #expect(throws: QuickActionError("broken.png is not an image Cortex can read")) {
            try await action.run(.files([url]), context: context)
        }
    }
}
