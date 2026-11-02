import AppKit
import Foundation
import Testing
@testable import Cortex
import CortexCore

/// The palette's `+` scope: the list, adding a typed or copied link, opening,
/// copying, marking read, editing and deleting.
@MainActor
@Suite struct ReadingListScopeTests {
    final class Opened {
        var urls: [URL] = []
    }

    let suiteName = "CortexTests-\(UUID().uuidString)"
    let palette = FakePaletteHost()
    let opened = Opened()
    let settings: ReadingListSettings
    let service: ReadingListService
    let scope: ReadingListScope

    init() throws {
        settings = ReadingListSettings(defaults: ModuleDefaults(id: "reading-list", store: UserDefaults(suiteName: suiteName)!))
        let opened = opened
        service = ReadingListService(database: try makeTestDatabase(), settings: settings) { opened.urls.append($0) }
        let palette = palette
        scope = ReadingListScope(service: service, moduleID: "reading-list", palette: { palette })
    }

    func type(_ query: String) async {
        scope.search(query)
        await scope.loaded()
    }

    /// Adds links in this order, so the last one is the newest.
    func add(_ urls: String...) throws {
        for (offset, url) in urls.enumerated() {
            try service.store.add(url: url, now: Date(timeIntervalSince1970: 1000 + Double(offset)))
        }
    }

    func id(of url: String) async throws -> Int64 {
        try #require(try await service.store.all().first { $0.url == url }?.id)
    }

    var urls: [String] {
        scope.list.items.map { entry in
            switch entry {
            case .add(let url): "add \(url)"
            case .item(let item): item.url
            }
        }
    }

    func press(_ combo: KeyCombo) async {
        _ = scope.keys.first { $0.combo == combo }?.perform?()
        await scope.loaded()
    }

    // MARK: The list

    @Test func listsUnreadNewestFirstThenRead() async throws {
        try add("https://a.com", "https://b.com", "https://c.com")
        try service.store.setRead(true, id: try await id(of: "https://c.com"))
        await type("")
        #expect(urls == ["https://b.com", "https://a.com", "https://c.com"])
        #expect(scope.list.selected?.item?.url == "https://b.com")
    }

    @Test func hidesReadLinksWhenAskedButSearchFindsThem() async throws {
        try add("https://a.com", "https://read.com")
        try service.store.setRead(true, id: try await id(of: "https://read.com"))
        settings.listRead = false
        await type("")
        #expect(urls == ["https://a.com"])
        await type("read")
        #expect(urls == ["https://read.com"])
    }

    // MARK: Adding

    @Test func offersATypedLinkAndAddsIt() async throws {
        try add("https://old.com")
        await type("example.com/new?utm_source=x")
        #expect(urls == ["add https://example.com/new"])
        #expect(scope.activationHints.map(\.label) == ["Add"])

        #expect(scope.activate(.primary, target: .selected))
        await scope.loaded()
        #expect(palette.opened == ["reading-list"], "back to the list, which shows the new link on top")
        #expect(palette.closes == 0)
        await type("")
        #expect(urls == ["https://example.com/new", "https://old.com"])
    }

    @Test func aTypedLinkThatIsSavedShowsTheSavedOne() async throws {
        try add("https://example.com/a", "https://example.com/b")
        await type("https://example.com/a#intro")
        #expect(urls == ["https://example.com/a"], "the saved link instead of an Add row")
    }

    @Test func addsTheLinkOnTheClipboardWithItsTitle() async throws {
        let test = TestPasteboard()
        test.pasteboard.declareTypes([.URL, NSPasteboard.PasteboardType("public.url-name")], owner: nil)
        test.pasteboard.setString("https://example.com/article", forType: .URL)
        test.pasteboard.setString("An Article", forType: NSPasteboard.PasteboardType("public.url-name"))

        scope.addFromClipboard(test.pasteboard)
        await scope.loaded()
        let item = try #require(try await service.store.all().first)
        #expect(item.url == "https://example.com/article" && item.title == "An Article")
    }

    @Test func readsLinksFromThePasteboard() {
        let test = TestPasteboard()
        let pasteboard = test.pasteboard

        pasteboard.clearContents()
        pasteboard.setPropertyList(
            [["https://example.com/a"], ["Title A"]], forType: NSPasteboard.PasteboardType("WebURLsWithTitlesPboardType"))
        #expect(ReadingListService.link(on: pasteboard)?.url == "https://example.com/a")
        #expect(ReadingListService.link(on: pasteboard)?.title == "Title A")

        pasteboard.clearContents()
        pasteboard.setString(" https://example.com/b\n", forType: .string)
        #expect(ReadingListService.link(on: pasteboard)?.url == " https://example.com/b\n")
        #expect(ReadingListService.link(on: pasteboard)?.title == nil)

        pasteboard.clearContents()
        pasteboard.setString("see example.com", forType: .string)
        #expect(ReadingListService.link(on: pasteboard) == nil)
        pasteboard.clearContents()
        pasteboard.setString("file.txt", forType: .string)
        #expect(ReadingListService.link(on: pasteboard) == nil, "plain text needs a scheme or www.")
    }

    // MARK: Opening and copying

    @Test func enterOpensTheLinkAndMarksItRead() async throws {
        try add("https://example.com/a")
        await type("")
        #expect(scope.activate(.primary, target: .selected))
        await scope.loaded()
        #expect(palette.closes == 1)
        #expect(opened.urls == [URL(string: "https://example.com/a")!])
        #expect(try await service.store.all().first?.isRead == true)
    }

    @Test func optionEnterCopiesTheLink() async throws {
        try add("https://example.com/a")
        await type("")
        #expect(scope.activate(.option, target: .selected))
        let delivery = try #require(palette.deliveries.first)
        guard case .text(let text) = delivery.content else {
            Issue.record("expected text")
            return
        }
        #expect(text == "https://example.com/a")
        #expect(delivery.action == .copyOnly)
        #expect(opened.urls.isEmpty)
        #expect(try await service.store.all().first?.isRead == false)
    }

    // MARK: Keys

    @Test func commandRTogglesRead() async throws {
        try add("https://example.com/a")
        await type("")
        #expect(scope.keys.contains { $0.hint == "Mark read" })
        await press(.command("r"))
        #expect(try await service.store.all().first?.isRead == true)
        #expect(scope.keys.contains { $0.hint == "Mark unread" })
        await press(.command("r"))
        #expect(try await service.store.all().first?.isRead == false)
    }

    @Test func commandDeleteDeletesAndSelectsTheNext() async throws {
        try add("https://a.com", "https://b.com")
        await type("")
        await press(.command(.delete))
        #expect(urls == ["https://a.com"])
        #expect(scope.list.selected?.item?.url == "https://a.com")
    }

    @Test func commandEEditsTitleAndNote() async throws {
        try add("https://example.com/a")
        await type("")
        await press(.command("e"))
        #expect(palette.overlays.count == 1)

        let item = try #require(scope.list.selected?.item)
        let form = ReadingItemForm(item: item)
        #expect(form.title == "" && form.note == "")
        form.title = "  The Article "
        form.note = "for the train"
        scope.editOverlay(for: form).activate(.primary)
        await scope.loaded()

        let edited = try #require(try await service.store.all().first)
        #expect(edited.title == "The Article" && edited.note == "for the train")
        #expect(palette.opened == ["reading-list"], "back to the list")
    }
}
