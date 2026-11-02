import Foundation
import Testing
@testable import CortexCore

@Suite struct ClipStoreTests {
    let database: AppDatabase
    let store: ClipStore

    init() throws {
        database = try makeTestDatabase()
        store = ClipStore(database: database)
    }

    // MARK: Recording and de-duplication

    @Test func listsNewestFirst() async throws {
        try store.record(textSnapshot("first", at: .now.addingTimeInterval(-10)), indexSensitive: true)
        try store.record(textSnapshot("second"), indexSensitive: true)
        #expect(try await store.summaries().map(\.preview) == ["second", "first"])
    }

    @Test func recentPlainTextsSkipImages() async throws {
        try store.record(textSnapshot("older", at: .now.addingTimeInterval(-20)), indexSensitive: true)
        try store.record(ClipSnapshot(
            representations: [LoadedRepresentation(type: ClipType.png, data: makePNG())],
            plainText: nil, isSensitive: false, copiedAt: .now.addingTimeInterval(-10)), indexSensitive: true)
        try store.record(textSnapshot("newest"), indexSensitive: true)
        #expect(try await store.recentPlainTexts(limit: 5) == ["newest", "older"])
        #expect(try await store.recentPlainTexts(limit: 1) == ["newest"])
    }

    @Test func recentPlainTextsKeepSensitiveClipsInPlaceWithoutText() async throws {
        try store.record(textSnapshot("older", at: .now.addingTimeInterval(-20)), indexSensitive: true)
        try store.record(textSnapshot("hunter2", sensitive: true, at: .now.addingTimeInterval(-10)), indexSensitive: true)
        try store.record(textSnapshot("newest"), indexSensitive: true)
        #expect(try await store.recentPlainTexts(limit: 5) == ["newest", nil, "older"])
    }

    @Test func recentTextsLeaveOutSensitiveClipsAndImages() async throws {
        let older = Date.now.addingTimeInterval(-30)
        try store.record(textSnapshot("older", at: older), indexSensitive: true)
        try store.record(textSnapshot("hunter2", sensitive: true, at: .now.addingTimeInterval(-20)), indexSensitive: true)
        try store.record(ClipSnapshot(
            representations: [LoadedRepresentation(type: ClipType.png, data: makePNG())],
            plainText: nil, isSensitive: false, copiedAt: .now.addingTimeInterval(-10)), indexSensitive: true)
        try store.record(textSnapshot("newest"), indexSensitive: true)
        let recent = try await store.recentTexts(limit: 5)
        #expect(recent.map(\.text) == ["newest", "older"])
        #expect(abs(recent[1].copiedAt.timeIntervalSince(older)) < 0.01)
        #expect(try await store.recentTexts(limit: 1).map(\.text) == ["newest"])
    }

    @Test func recopyMovesExistingItemToTop() async throws {
        let first = try store.record(textSnapshot("same", at: .now.addingTimeInterval(-60)), indexSensitive: true)
        try store.record(textSnapshot("other", at: .now.addingTimeInterval(-30)), indexSensitive: true)
        let again = try store.record(textSnapshot("same", app: "Safari"), indexSensitive: true)

        guard case .inserted(let id) = first else { Issue.record("expected insert"); return }
        #expect(again == .bumped(id))
        let summaries = try await store.summaries()
        #expect(summaries.map(\.preview) == ["same", "other"])
        #expect(summaries.first?.sourceAppName == "Safari")
    }

    @Test func importDoesNotBumpExistingItems() async throws {
        let recent = Date.now
        try store.record(textSnapshot("kept", at: recent), indexSensitive: true)
        try store.record(textSnapshot("kept", at: recent.addingTimeInterval(-3600)), indexSensitive: true, bumpExisting: false)
        let summary = try #require(try await store.summaries().first)
        #expect(abs(summary.lastCopiedAt.timeIntervalSince(recent)) < 0.01)
    }

    @Test func skipsEmptySnapshots() throws {
        let empty = ClipSnapshot(representations: [], plainText: nil, isSensitive: false)
        #expect(try store.record(empty, indexSensitive: true) == .skipped)
    }

    // MARK: Search

    @Test func searchMatchesWordPrefixes() async throws {
        try store.record(textSnapshot("clipboard history for the Mac"), indexSensitive: true)
        try store.record(textSnapshot("snippets and templates"), indexSensitive: true)
        try store.record(textSnapshot("Café am Markt"), indexSensitive: true)

        #expect(try await store.summaries(matching: "clip").map(\.preview) == ["clipboard history for the Mac"])
        #expect(try await store.summaries(matching: "hist cli").count == 1)
        #expect(try await store.summaries(matching: "clip snip").isEmpty)
        #expect(try await store.summaries(matching: "cafe").count == 1)
        #expect(try await store.summaries(matching: "  ").count == 3)
    }

    @Test func sensitiveTextIsOnlyIndexedWhenAllowed() async throws {
        try store.record(textSnapshot("hunter2-secret", sensitive: true, app: "1Password"), indexSensitive: false)

        #expect(try await store.summaries(matching: "hunter2").isEmpty)
        #expect(try await store.summaries(matching: "1Password").count == 1)

        try store.reindexSensitive(indexSensitive: true)
        #expect(try await store.summaries(matching: "hunter2").count == 1)

        try store.reindexSensitive(indexSensitive: false)
        #expect(try await store.summaries(matching: "hunter2").isEmpty)
    }

    @Test func searchMatchesSourceApp() async throws {
        try store.record(textSnapshot("anything", app: "Xcode"), indexSensitive: true)
        #expect(try await store.summaries(matching: "xco").count == 1)
    }

    // MARK: Recognised text

    func recordImage(_ png: Data = makePNG(), sensitive: Bool = false, at date: Date = .now, indexSensitive: Bool = true) throws -> Int64 {
        switch try store.record(imageSnapshot(png, sensitive: sensitive, at: date), indexSensitive: indexSensitive) {
        case .inserted(let id), .bumped(let id): return id
        case .skipped: throw CancellationError()
        }
    }

    @Test func recognizedTextIsSearchable() async throws {
        let id = try recordImage()
        #expect(try await store.detail(id: id)?.item.recognizedText == nil)

        try store.setRecognizedText("Invoice October\nTotal 42,17 EUR", id: id, indexSensitive: true)
        #expect(try await store.summaries(matching: "invoice tot").map(\.id) == [id])
        #expect(try await store.summaries(matching: "preview").map(\.id) == [id])
        #expect(try await store.detail(id: id)?.item.recognizedText == "Invoice October\nTotal 42,17 EUR")
    }

    @Test func unrecognizedImagesNewestFirst() async throws {
        let older = try recordImage(makePNG(width: 10), at: .now.addingTimeInterval(-20))
        try store.record(textSnapshot("text clip", at: .now.addingTimeInterval(-10)), indexSensitive: true)
        let newer = try recordImage(makePNG(width: 20))
        #expect(try await store.unrecognizedImageIDs(limit: 10) == [newer, older])
        #expect(try await store.unrecognizedImageIDs(limit: 1) == [newer])

        // "" means read, with no text in it.
        try store.setRecognizedText("", id: newer, indexSensitive: true)
        #expect(try await store.unrecognizedImageIDs(limit: 10) == [older])
        #expect(try await store.detail(id: newer)?.item.recognizedText == "")
    }

    @Test func recopyKeepsRecognizedText() async throws {
        let png = makePNG()
        let id = try recordImage(png, at: .now.addingTimeInterval(-60))
        try store.setRecognizedText("Boarding pass", id: id, indexSensitive: true)
        #expect(try recordImage(png) == id)
        #expect(try await store.summaries(matching: "boarding").map(\.id) == [id])
        #expect(try await store.unrecognizedImageIDs(limit: 10).isEmpty)
    }

    @Test func recognizedTextOfSensitiveClipsIsOnlyIndexedWhenAllowed() async throws {
        let id = try recordImage(sensitive: true, indexSensitive: false)
        try store.setRecognizedText("hunter2", id: id, indexSensitive: false)
        #expect(try await store.summaries(matching: "hunter2").isEmpty)

        try store.reindexSensitive(indexSensitive: true)
        #expect(try await store.summaries(matching: "hunter2").map(\.id) == [id])

        try store.reindexSensitive(indexSensitive: false)
        #expect(try await store.summaries(matching: "hunter2").isEmpty)
    }

    @Test func recognizedSecretFlagsTheClip() async throws {
        let id = try recordImage(indexSensitive: false)
        try store.setRecognizedText("token ghp_abc", id: id, markSensitive: true, indexSensitive: false)
        #expect(try await store.detail(id: id)?.item.isSensitive == true)
        #expect(try await store.summaries(matching: "ghp").isEmpty)
        #expect(try await store.summaries(matching: "preview").map(\.id) == [id])
    }

    @Test func recognizedTextForADeletedClipIsDropped() async throws {
        let id = try recordImage()
        try store.delete(ids: [id])
        try store.setRecognizedText("too late", id: id, indexSensitive: true)
        #expect(try await store.count() == 0)
    }

    @Test func imageDataOfAClip() async throws {
        let png = makePNG(width: 30)
        let id = try recordImage(png)
        #expect(try await store.imageData(id: id) == png)

        guard case .inserted(let textID) = try store.record(textSnapshot("no image"), indexSensitive: true) else {
            Issue.record("expected insert"); return
        }
        #expect(try await store.imageData(id: textID) == nil)
        #expect(try await store.imageData(id: 9_999) == nil)
    }

    // MARK: Payloads

    @Test func imagesAreStoredEncryptedInBlobStore() async throws {
        let png = makePNG()
        let snapshot = ClipSnapshot(
            representations: [LoadedRepresentation(type: ClipType.png, data: png)],
            plainText: nil, isSensitive: false)
        guard case .inserted(let id) = try store.record(snapshot, indexSensitive: true) else {
            Issue.record("expected insert"); return
        }

        let blobIDs = try database.blobs.storedIDs()
        #expect(blobIDs.count == 1)
        let onDisk = try Data(contentsOf: database.blobs.directory.appending(path: blobIDs.first!))
        #expect(onDisk.range(of: Data([0x89, 0x50, 0x4E, 0x47])) == nil, "PNG signature visible on disk")

        let detail = try #require(try await store.detail(id: id))
        #expect(detail.item.kind == .image)
        #expect(detail.imageData == png)
        #expect(detail.item.preview == "Image 64×48")
        #expect(detail.item.thumbnail != nil)
    }

    @Test func largeTextGoesToBlobStore() async throws {
        let text = String(repeating: "a", count: ClipStore.inlineLimit + 1)
        guard case .inserted(let id) = try store.record(textSnapshot(text), indexSensitive: true) else {
            Issue.record("expected insert"); return
        }
        #expect(try database.blobs.storedIDs().count == 1)
        #expect(try await store.detail(id: id)?.data(for: ClipType.plainText) == Data(text.utf8))
    }

    @Test func filesKeepTheirURLs() async throws {
        let urls = [URL(filePath: "/tmp/a report.pdf"), URL(filePath: "/tmp/b.png")]
        let snapshot = ClipSnapshot(representations: [ClipSnapshot.fileURLRepresentation(urls)], plainText: nil, isSensitive: false)
        guard case .inserted(let id) = try store.record(snapshot, indexSensitive: true) else {
            Issue.record("expected insert"); return
        }
        let detail = try #require(try await store.detail(id: id))
        #expect(detail.item.kind == .files)
        #expect(detail.fileURLs == urls)
        #expect(detail.item.preview == "a report.pdf, b.png")
        #expect(try await store.summaries(matching: "report").count == 1)
    }

    // MARK: Deleting and retention

    @Test func deleteRemovesBlobs() async throws {
        let snapshot = ClipSnapshot(
            representations: [LoadedRepresentation(type: ClipType.png, data: makePNG())],
            plainText: nil, isSensitive: false)
        guard case .inserted(let id) = try store.record(snapshot, indexSensitive: true) else {
            Issue.record("expected insert"); return
        }
        #expect(try store.delete(ids: [id]) == 1)
        #expect(try database.blobs.storedIDs().isEmpty)
        #expect(try await store.count() == 0)
    }

    @Test func clearKeepsPinnedItems() async throws {
        guard case .inserted(let pinned) = try store.record(textSnapshot("keep me"), indexSensitive: true) else {
            Issue.record("expected insert"); return
        }
        try store.setPinned(true, id: pinned)
        try store.record(textSnapshot("drop me"), indexSensitive: true)

        #expect(try store.deleteAll() == 1)
        #expect(try await store.summaries().map(\.preview) == ["keep me"])
        #expect(try store.deleteAll(includingPinned: true) == 1)
    }

    @Test func purgeByAgeAndCountSparesPinned() async throws {
        let now = Date.now
        let day: TimeInterval = 86_400
        try store.record(textSnapshot("old", at: now.addingTimeInterval(-40 * day)), indexSensitive: true)
        guard case .inserted(let oldPinned) = try store.record(
            textSnapshot("old pinned", at: now.addingTimeInterval(-90 * day)), indexSensitive: true)
        else { Issue.record("expected insert"); return }
        try store.setPinned(true, id: oldPinned)
        for index in 0..<5 {
            try store.record(textSnapshot("recent \(index)", at: now.addingTimeInterval(-Double(index) * 60)), indexSensitive: true)
        }

        let deleted = try store.purge(policy: RetentionPolicy(maxAge: 30 * day, maxCount: 3), now: now)

        #expect(deleted == 3) // "old" by age, "recent 3" and "recent 4" by count
        #expect(try await store.summaries().map(\.preview) == ["recent 0", "recent 1", "recent 2", "old pinned"])
    }

    @Test func purgeSensitiveSooner() async throws {
        let now = Date.now
        try store.record(textSnapshot("password", sensitive: true, at: now.addingTimeInterval(-7200)), indexSensitive: true)
        try store.record(textSnapshot("normal", at: now.addingTimeInterval(-7200)), indexSensitive: true)

        try store.purge(policy: RetentionPolicy(maxAge: 86_400, maxCount: nil, sensitiveMaxAge: 3600), now: now)

        #expect(try await store.summaries().map(\.preview) == ["normal"])
    }

    @Test func removesOrphanBlobs() throws {
        let orphan = try database.blobs.write(Data("left over".utf8))
        try store.record(ClipSnapshot(
            representations: [LoadedRepresentation(type: ClipType.png, data: makePNG())],
            plainText: nil, isSensitive: false), indexSensitive: true)

        #expect(try store.removeOrphanBlobs() == 1)
        let remaining = try database.blobs.storedIDs()
        #expect(remaining.count == 1)
        #expect(!remaining.contains(orphan))
    }
}

@Suite struct ClipSnapshotTests {
    func snapshot(_ types: [String]) -> ClipSnapshot {
        ClipSnapshot(
            representations: types.map { LoadedRepresentation(type: $0, data: Data($0.utf8)) },
            plainText: nil, isSensitive: false)
    }

    @Test func classifiesKinds() {
        #expect(snapshot([ClipType.plainText]).kind == .text)
        #expect(snapshot([ClipType.html, ClipType.plainText]).kind == .richText)
        // Word and Pages put a picture next to rich text: still text.
        #expect(snapshot([ClipType.png, ClipType.rtf, ClipType.plainText]).kind == .richText)
        // A browser image copy comes with HTML: still an image.
        #expect(snapshot([ClipType.tiff, ClipType.html]).kind == .image)
        // Safari's "Copy Image" adds an RTFD holding only the picture: still an image.
        #expect(snapshot([ClipType.tiff, ClipType.flatRTFD, ClipType.html]).kind == .image)
        // Rich text with no visible text, only an attachment: an image.
        let attachmentOnly = ClipSnapshot(
            representations: [
                LoadedRepresentation(type: ClipType.png, data: Data([1])),
                LoadedRepresentation(type: ClipType.rtf, data: Data([2])),
            ],
            plainText: " \u{FFFC}\n", isSensitive: false)
        #expect(attachmentOnly.kind == .image)
        // Rich text without an image stays rich text even without plain text.
        #expect(snapshot([ClipType.flatRTFD]).kind == .richText)
        #expect(snapshot([ClipType.fileURL, ClipType.tiff, ClipType.plainText]).kind == .files)
    }

    @Test func dropsUnstoredTypesAndSortsTheRest() {
        let snapshot = snapshot(["com.apple.webarchive", ClipType.plainText, ClipType.rtf])
        #expect(snapshot.representations.map(\.type) == [ClipType.rtf, ClipType.plainText])
    }

    @Test func hashDependsOnContentNotOrder() {
        #expect(snapshot([ClipType.plainText, ClipType.rtf]).contentHash == snapshot([ClipType.rtf, ClipType.plainText]).contentHash)
        #expect(snapshot([ClipType.plainText]).contentHash != snapshot([ClipType.html]).contentHash)
    }

    @Test func sensitivityRules() {
        #expect(SensitivityRules.isSensitive(types: ["org.nspasteboard.ConcealedType", ClipType.plainText], sourceBundleID: nil))
        #expect(SensitivityRules.isSensitive(types: [ClipType.plainText], sourceBundleID: "com.1password.1password"))
        #expect(!SensitivityRules.isSensitive(types: [ClipType.plainText], sourceBundleID: "com.apple.Safari"))
    }

    @Test func previewCollapsesWhitespace() {
        #expect(PreviewText.make("  line one\n\n\tline two  ") == "line one line two")
        #expect(PreviewText.make(String(repeating: "x", count: 1000)).count == PreviewText.maxLength)
    }
}
