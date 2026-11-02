import Foundation
import Synchronization
import Testing
@testable import Cortex
import CortexCore

/// Hands out the captures it is given, or waits until it is told what was
/// captured (`waits`).
@MainActor
final class FakeScreenCapture: ScreenCapturing {
    var captures: [Data?] = []
    var error: (any Error)?
    var waits = false
    private(set) var count = 0
    private var pending: CheckedContinuation<Data?, Never>?

    func capture() async throws -> Data? {
        count += 1
        if let error { throw error }
        guard waits else { return captures.isEmpty ? nil : captures.removeFirst() }
        return await withCheckedContinuation { pending = $0 }
    }

    var isWaiting: Bool { pending != nil }

    func finish(_ image: Data?) {
        pending?.resume(returning: image)
        pending = nil
    }
}

/// Reads every image as `text`, and remembers whether it was asked to join
/// lines.
final class FixedTextRecognizer: TextRecognizing {
    let text: String
    let joins = Mutex<[Bool]>([])

    init(_ text: String) {
        self.text = text
    }

    func recognize(_ image: Data) async throws -> String { text }

    func recognizeCapture(_ image: Data, joinLines: Bool) async throws -> String {
        joins.withLock { $0.append(joinLines) }
        return text
    }
}

@MainActor
@Suite struct TextRecognitionTests {
    static let token = "ghp_" + String(repeating: "a1B2", count: 9)

    let suiteName = "CortexTests-\(UUID().uuidString)"
    let palette = FakePaletteHost()
    let capturer = FakeScreenCapture()
    let image = imageData(.png)
    /// Modules hold their host unowned: it lives as long as the test.
    let host: ModuleHost

    init() throws {
        let services = ModuleServices(
            database: try makeTestDatabase(), defaults: UserDefaults(suiteName: suiteName)!, secrets: MemorySecrets())
        services.palette = palette
        host = ModuleHost(ModuleList.all, services: services, registerHotkey: { _ in }, setHotkeyEnabled: { _, _ in })
    }

    /// The module, switched on, reading every capture as `text`.
    func module(text: String = "Gate B12") async throws -> TextRecognitionModule {
        await host.setEnabled("text-recognition", true).value
        let module = try #require(host.module(TextRecognitionModule.self))
        module.capturer = capturer
        module.recognizer = FixedTextRecognizer(text)
        module.isPermitted = { true }
        module.settings.notify = false
        capturer.captures = [image]
        return module
    }

    func tearDown() {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
    }

    var copiedText: String? {
        guard case .text(let text) = palette.deliveries.last?.content else { return nil }
        return text
    }

    @Test func offByDefault() throws {
        defer { tearDown() }
        #expect(host.module(TextRecognitionModule.self) == nil)
        #expect(!host.statusMenuGroups.flatMap { $0 }.contains { $0.title == "Capture Text" })
    }

    @Test func copiesTheTextAsANewClip() async throws {
        let module = try await module()
        defer { tearDown() }

        #expect(await module.capture() == "Gate B12")
        let delivery = try #require(palette.deliveries.last)
        #expect(copiedText == "Gate B12")
        #expect(delivery.action == .copyOnly)
        #expect(delivery.recording == .record(sensitive: false))
        #expect(!delivery.restoringPasteboard)
    }

    @Test func escLeavesTheClipboardAlone() async throws {
        let module = try await module()
        defer { tearDown() }
        capturer.captures = [nil]

        #expect(await module.capture() == nil)
        #expect(palette.deliveries.isEmpty)
    }

    @Test func noTextLeavesTheClipboardAlone() async throws {
        let module = try await module(text: " \n ")
        defer { tearDown() }

        #expect(await module.capture() == nil)
        #expect(palette.deliveries.isEmpty)
    }

    @Test func aFailedCaptureCopiesNothing() async throws {
        let module = try await module()
        defer { tearDown() }
        capturer.error = QuickActionError("screencapture failed")

        #expect(await module.capture() == nil)
        #expect(palette.deliveries.isEmpty)
    }

    @Test func withoutPermissionItExplainsAndCapturesNothing() async throws {
        let module = try await module()
        defer { tearDown() }
        var explained = 0
        module.isPermitted = { false }
        module.explainPermission = { explained += 1 }

        #expect(await module.capture() == nil)
        #expect(explained == 1)
        #expect(capturer.count == 0)
        #expect(palette.deliveries.isEmpty)
    }

    @Test func closesThePaletteFirst() async throws {
        let module = try await module()
        defer { tearDown() }
        palette.isVisible = true
        capturer.captures = [nil]

        await module.capture()
        #expect(!palette.isVisible)
    }

    @Test func aSecondPressWhileSelectingDoesNothing() async throws {
        let module = try await module()
        defer { tearDown() }
        capturer.waits = true

        let first = Task { await module.capture() }
        while !capturer.isWaiting { await Task.yield() }
        #expect(module.isCapturing)
        #expect(await module.capture() == nil)
        #expect(capturer.count == 1)

        capturer.finish(image)
        #expect(await first.value == "Gate B12")
        #expect(!module.isCapturing)
        #expect(palette.deliveries.count == 1)
    }

    @Test func joiningLinesFollowsTheSetting() async throws {
        let module = try await module()
        defer { tearDown() }
        let recognizer = FixedTextRecognizer("Gate B12")
        module.recognizer = recognizer
        capturer.captures = [image, image]

        await module.capture()
        module.settings.joinLines = true
        await module.capture()
        #expect(recognizer.joins.withLock { $0 } == [false, true])
    }

    @Test func secretTextIsRecordedSensitive() async throws {
        let module = try await module(text: "Token: \(Self.token)")
        defer { tearDown() }

        await module.capture()
        #expect(palette.deliveries.last?.recording == .record(sensitive: true))
    }

    @Test func secretTextFollowsTheClipboardsDetectionSetting() async throws {
        let module = try await module(text: "Token: \(Self.token)")
        defer { tearDown() }
        try #require(host.module(ClipboardModule.self)?.service).settings.detectSensitiveText = false

        await module.capture()
        #expect(palette.deliveries.last?.recording == .record(sensitive: false))
    }

    /// `$ocr` returns at once, so no progress card shows while selecting;
    /// the capture it started copies like the hotkey.
    @Test func ocrCommandStartsACapture() async throws {
        let module = try await module()
        defer { tearDown() }
        capturer.waits = true
        let command = try #require(module.contributedCommands.first as? TextRecognitionCommand)
        #expect(command.name == "ocr")

        // Resolving captures nothing; handing over does.
        guard case .handoff(let description, let handOver) = try await command.resolve(.none) else {
            Issue.record("expected a handoff")
            return
        }
        #expect(description == "Select a region of the screen and copy the text in it.")
        #expect(!module.isCapturing && !capturer.isWaiting)
        try await handOver()
        while !capturer.isWaiting { await Task.yield() }
        #expect(module.isCapturing)

        capturer.finish(image)
        while module.isCapturing { await Task.yield() }
        #expect(copiedText == "Gate B12")
    }

    @Test func ocrCommandAndCaptureTextFollowTheSwitch() async throws {
        defer { tearDown() }
        await host.start()
        let scope = try #require(host.module(CommandsModule.self)?.palette as? CommandsScope)
        func offersOCR() -> Bool {
            scope.search("ocr")
            return scope.list.items.contains { $0.id == "command.ocr" }
        }
        #expect(!offersOCR(), "off by default")

        await host.setEnabled("text-recognition", true).value
        #expect(offersOCR())
        let item = try #require(host.statusMenuGroups.flatMap { $0 }.first { $0.title == "Capture Text" })
        #expect(item.shortcut == .captureText)

        await host.setEnabled("text-recognition", false).value
        #expect(!offersOCR())
    }

    @Test func contributesRecognizeText() async throws {
        let module = try await module()
        defer { tearDown() }
        let action = try #require(module.contributedActions.first as? RecognizeTextAction)
        #expect(action.id == "image.recognize-text")
        #expect(action.accepts(.image(image)))
    }

    @Test func settingsAreStoredUnderTheModuleID() async throws {
        let module = try await module()
        defer { tearDown() }
        #expect(!module.settings.joinLines)
        module.settings.joinLines = true
        module.settings.language = "de-Latn-DE"
        let defaults = UserDefaults(suiteName: suiteName)!
        #expect(defaults.object(forKey: "text-recognition.joinLines") as? Bool == true)
        #expect(defaults.object(forKey: "text-recognition.notify") as? Bool == false)
        #expect(defaults.string(forKey: "text-recognition.language") == "de-Latn-DE")

        let reloaded = TextRecognitionSettings(defaults: ModuleDefaults(id: "text-recognition", store: defaults))
        #expect(reloaded.joinLines && !reloaded.notify && reloaded.language == "de-Latn-DE")
    }

    @Test func aChosenLanguageIsVisionsOwn() async throws {
        let module = try await module()
        defer { tearDown() }
        #expect(module.settings.languages.isEmpty)
        let german = try #require(TextRecognizer.supportedLanguages.first { $0.languageCode == .german })
        module.settings.language = german.maximalIdentifier
        #expect(module.settings.languages == [german])
    }
}
