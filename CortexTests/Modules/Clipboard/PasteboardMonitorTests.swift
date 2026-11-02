import AppKit
import Testing
@testable import Cortex
import CortexCore

/// The monitor's decisions about what gets recorded.
@MainActor
@Suite struct PasteboardMonitorTests {
    let board = TestPasteboard()
    let store: ClipStore
    var options = Options()
    var frontmost = Frontmost()
    let activity = PasteboardActivity()

    @MainActor final class Options {
        var value = ClipboardSettings.RecordingOptions(
            isPaused: false, ignoredBundleIDs: [], indexSensitiveText: true, detectSensitiveText: true)
        var recordCalls = 0
    }

    @MainActor final class Frontmost {
        var app: PasteboardReader.SourceApp? = .textEdit
    }

    init() throws {
        store = try makeTestStore()
    }

    func makeMonitor() -> PasteboardMonitor {
        let options = options
        let frontmost = frontmost
        return PasteboardMonitor(
            store: store,
            pasteboard: board.name,
            frontmostApp: { frontmost.app },
            options: { options.value },
            isBorrowed: { [activity] in activity.isBorrowed },
            didRecord: { options.recordCalls += 1 })
    }

    func copy(_ text: String) {
        board.write([(.string, Data(text.utf8))])
    }

    var previews: [String] {
        get async throws { try await store.summaries().map(\.preview) }
    }

    @Test func skipsContentPresentAtLaunch() async throws {
        copy("before launch")
        let monitor = makeMonitor()
        await monitor.poll()
        #expect(try await previews.isEmpty)
    }

    @Test func recordsEachChangeOnce() async throws {
        let monitor = makeMonitor()
        copy("first")
        await monitor.poll()
        await monitor.poll()
        copy("second")
        await monitor.poll()

        #expect(try await previews == ["second", "first"])
        #expect(options.recordCalls == 2)
        #expect(try await store.summaries().first?.sourceAppName == "TextEdit")
    }

    @Test func ignoresOwnPastes() async throws {
        let monitor = makeMonitor()
        copy("mine")
        await monitor.poll()
        guard let id = try await store.summaries().first?.id,
              let detail = try await store.detail(id: id) else {
            Issue.record("expected an item"); return
        }

        Paster.write(detail, mode: .plainText, to: board.pasteboard)
        await monitor.poll()

        #expect(options.recordCalls == 1)
    }

    @Test func ignoresChangesWhileBorrowed() async throws {
        let monitor = makeMonitor()
        copy("before")
        await monitor.poll()

        // An action copies the selection and puts the clipboard back.
        await activity.borrow {
            copy("selected text")
            await monitor.poll()
            let saved = Paster.save(board.pasteboard)
            Paster.restore(saved, ifUnchangedSince: board.pasteboard.changeCount, to: board.pasteboard)
            await monitor.poll()
        }
        await monitor.poll()

        #expect(try await previews == ["before"])
    }

    @Test func recordsCopiesMadeWhileBorrowedOnceItIsOver() async throws {
        let monitor = makeMonitor()
        await activity.borrow {
            copy("copied by the user meanwhile")
            await monitor.poll()
        }
        await monitor.poll()

        #expect(try await previews == ["copied by the user meanwhile"])
    }

    @Test func recordsNothingWhilePaused() async throws {
        let monitor = makeMonitor()
        options.value.isPaused = true
        copy("secret meeting notes")
        await monitor.poll()
        #expect(try await previews.isEmpty)

        // Resuming does not pick up what was copied while paused.
        options.value.isPaused = false
        await monitor.poll()
        #expect(try await previews.isEmpty)
    }

    @Test func skipsIgnoredApps() async throws {
        let monitor = makeMonitor()
        options.value.ignoredBundleIDs = ["com.apple.TextEdit"]
        copy("from TextEdit")
        await monitor.poll()

        frontmost.app = .safari
        copy("from Safari")
        await monitor.poll()

        #expect(try await previews == ["from Safari"])
    }

    @Test func skipsItemsOverTheSizeLimit() async throws {
        let monitor = makeMonitor()
        copy(String(repeating: "x", count: ClipboardSettings.maxItemBytes + 1))
        await monitor.poll()
        #expect(try await previews.isEmpty)
    }

    @Test func sensitiveTextFollowsIndexSetting() async throws {
        let monitor = makeMonitor()
        options.value.indexSensitiveText = false
        frontmost.app = .init(bundleID: "com.1password.1password", name: "1Password")
        copy("hunter2")
        await monitor.poll()

        let item = try #require(try await store.summaries().first)
        #expect(item.isSensitive)
        #expect(try await store.summaries(matching: "hunter2").isEmpty)
        #expect(try await store.summaries(matching: "1password").count == 1)
    }

    @Test func flagsTextThatLooksLikeASecret() async throws {
        let monitor = makeMonitor()
        copy("q8Zr3TfL0pW7xYv2Nc5Ka9Hd")
        await monitor.poll()
        copy("Meeting notes for Monday")
        await monitor.poll()

        let items = try await store.summaries()
        #expect(items.map(\.isSensitive) == [false, true])
    }

    @Test func detectionCanBeSwitchedOff() async throws {
        let monitor = makeMonitor()
        options.value.detectSensitiveText = false
        copy("q8Zr3TfL0pW7xYv2Nc5Ka9Hd")
        await monitor.poll()

        let item = try #require(try await store.summaries().first)
        #expect(!item.isSensitive)
    }

    /// Quick action results are new content: recorded, from Cortex.
    @Test func recordsActionResults() async throws {
        let monitor = makeMonitor()
        Paster.write(image: imageData(.png), recording: .record(sensitive: false), to: board.pasteboard)
        await monitor.poll()
        Paster.write(text: "decoded secret", recording: .record(sensitive: true), to: board.pasteboard)
        await monitor.poll()

        let items = try await store.summaries()
        #expect(items.map(\.kind) == [.text, .image])
        #expect(items.allSatisfy { $0.sourceBundleID == Bundle.main.bundleIdentifier }, "the writer beats the frontmost app")
        #expect(items.map(\.isSensitive) == [true, false], "made from something sensitive")
    }

    /// Pasting a clip or a snippet puts nothing new in the history.
    @Test func skipsPastedClipsAndSnippets() async throws {
        let monitor = makeMonitor()
        Paster.write(text: "Best regards", to: board.pasteboard)
        await monitor.poll()
        #expect(try await previews.isEmpty)
    }
}
