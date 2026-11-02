import Foundation
import GRDB
import Testing
@testable import CortexCore

/// Links, their normal form, the store and the palette's order.
@Suite struct ReadingListStoreTests {
    let database: AppDatabase
    let store: ReadingListStore

    init() throws {
        database = try makeTestDatabase()
        store = ReadingListStore(database: database)
    }

    // MARK: URLs

    @Test(arguments: [
        ("https://Example.com/Path?a=1", "https://example.com/Path?a=1"),
        ("HTTP://example.com/", "http://example.com"),
        ("  https://example.com/article  ", "https://example.com/article"),
        ("example.com/article", "https://example.com/article"),
        ("www.example.com", "https://www.example.com"),
        ("https://example.com/a?utm_source=x&id=7&UTM_Medium=y&fbclid=z", "https://example.com/a?id=7"),
        ("https://example.com/a?utm_source=x", "https://example.com/a"),
        ("https://example.com/a#section-2", "https://example.com/a"),
        ("https://mail.example.com/#/inbox", "https://mail.example.com/#/inbox"),
        ("https://example.com/a%20b?q=a%26b", "https://example.com/a%20b?q=a%26b"),
        ("http://localhost:8080/x", "http://localhost:8080/x"),
    ])
    func normalizesLinks(input: String, expected: String) {
        #expect(ReadingItem.normalizedURL(input) == expected)
    }

    @Test(arguments: ["", "hello", "two words.com", "ftp://example.com/file", "mailto:a@example.com",
                      "https://user:secret@example.com", "localhost", "https://"])
    func rejectsWhatIsNotAWebLink(input: String) {
        #expect(ReadingItem.normalizedURL(input) == nil)
    }

    @Test(arguments: [
        ("https://example.com/a", true),
        (" https://example.com/b\n", true),
        ("www.example.com/c", true),
        ("  www.example.com", true),
        ("example.com/a", false),
        ("file.txt", false),
        ("see example.com", false),
        ("ftp://example.com/file", false),
    ])
    func recognisesPastedLinks(text: String, expected: Bool) {
        #expect(ReadingItem.isPastedLink(text) == expected)
    }

    @Test func showsTheHostWithoutWWW() {
        let item = ReadingItem(url: "https://www.example.com/a")
        #expect(item.host == "example.com")
        #expect(ReadingItem(url: "https://www.example.com").displayTitle == "example.com")
        #expect(ReadingItem(url: "https://example.com", title: "Title").displayTitle == "Title")
    }

    @Test(arguments: [
        ("https://code.claude.com/docs/en/context-window", "Context Window (claude.com)"),
        ("https://www.example.com/a", "A (example.com)"),
        ("https://example.com/blog/my_first_post.html", "My First Post (example.com)"),
        ("https://en.wikipedia.org/wiki/Swift_(programming_language)", "Swift (programming language) (wikipedia.org)"),
        ("https://news.bbc.co.uk/sport/football-results", "Football Results (bbc.co.uk)"),
        ("https://example.com/posts/hello-world/12345", "Hello World (example.com)"),
        ("https://example.com/docs/index.html", "Docs (example.com)"),
        ("https://example.com/a%20b", "A B (example.com)"),
        ("https://example.com/d/3f2a9c1e-7b4d-4e8a-9c21-5d6e7f8a9b0c", "D (example.com)"),
        ("https://code.claude.com", "code.claude.com"),
        ("https://example.com/12345", "example.com"),
        ("http://192.168.1.10/status", "Status (192.168.1.10)"),
        ("http://localhost:8080/x", "X (localhost)"),
    ])
    func namesLinksWithoutATitleFromTheirPath(url: String, expected: String) {
        #expect(ReadingItem(url: url).displayTitle == expected)
    }

    // MARK: Store

    @Test func addsALinkInItsNormalForm() throws {
        let item = try store.add(url: "Example.com/a?utm_source=feed", title: "  A  ", sourceAppName: "Safari")
        #expect(item.id != nil)
        #expect(item.url == "https://example.com/a")
        #expect(item.title == "A")
        #expect(item.sourceAppName == "Safari")
        #expect(!item.isRead)
    }

    @Test func rejectsText() {
        #expect(throws: ReadingListError.notALink("just words")) {
            try store.add(url: "just words")
        }
    }

    @Test func addingALinkAgainBringsItBackUnread() async throws {
        let first = try store.add(url: "https://example.com/a", title: "Old", now: Date(timeIntervalSince1970: 1000))
        try store.setRead(true, id: try #require(first.id))
        let again = try store.add(url: "https://example.com/a?utm_campaign=x", now: Date(timeIntervalSince1970: 2000))

        #expect(again.id == first.id)
        #expect(again.title == "Old", "without a new title the old one stays")
        #expect(again.readAt == nil)
        #expect(again.addedAt == Date(timeIntervalSince1970: 2000))
        #expect(try await store.all().count == 1)

        let renamed = try store.add(url: "https://example.com/a", title: "New")
        #expect(renamed.title == "New")
    }

    @Test func editsTitleAndNote() async throws {
        let id = try #require(try store.add(url: "https://example.com", title: "T").id)
        try store.edit(id: id, title: "Better", note: "  for the weekend ")
        var item = try #require(try await store.item(id: id))
        #expect(item.title == "Better" && item.note == "for the weekend")
        try store.edit(id: id, title: " ", note: "")
        item = try #require(try await store.item(id: id))
        #expect(item.title == nil && item.note == nil)
    }

    @Test func marksReadKeepingTheFirstDate() async throws {
        let id = try #require(try store.add(url: "https://example.com").id)
        try store.setRead(true, id: id, at: Date(timeIntervalSince1970: 100))
        try store.setRead(true, id: id, at: Date(timeIntervalSince1970: 200))
        #expect(try await store.item(id: id)?.readAt == Date(timeIntervalSince1970: 100))
        #expect(try await store.unreadCount() == 0)
        try store.setRead(false, id: id)
        #expect(try await store.item(id: id)?.readAt == nil)
        #expect(try await store.unreadCount() == 1)
    }

    @Test func purgesOnlyLinksReadBeforeTheDate() async throws {
        let old = try #require(try store.add(url: "https://example.com/old").id)
        let recent = try #require(try store.add(url: "https://example.com/recent").id)
        _ = try store.add(url: "https://example.com/unread", now: Date(timeIntervalSince1970: 0))
        try store.setRead(true, id: old, at: Date(timeIntervalSince1970: 100))
        try store.setRead(true, id: recent, at: Date(timeIntervalSince1970: 300))

        #expect(try store.purgeRead(before: Date(timeIntervalSince1970: 200)) == 1)
        #expect(try await store.all().map(\.url).sorted() == ["https://example.com/recent", "https://example.com/unread"])
    }

    @Test func theCutoffIsThatManyDaysBackAndZeroKeepsEverything() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(ReadingListStore.purgeCutoff(afterDays: 0, now: now) == nil)
        #expect(ReadingListStore.purgeCutoff(afterDays: 1, now: now) == Date(timeIntervalSince1970: 1_000_000 - 86400))
        #expect(ReadingListStore.purgeCutoff(afterDays: 30, now: now) == Date(timeIntervalSince1970: 1_000_000 - 30 * 86400))
    }

    @Test func anExplicitDeleteLeavesATombstoneAndAPurgeDoesNot() async throws {
        let deleted = try #require(try store.add(url: "https://example.com/deleted").id)
        let purged = try #require(try store.add(url: "https://example.com/purged").id)
        try store.setRead(true, id: purged, at: Date(timeIntervalSince1970: 100))

        try store.delete(id: deleted)
        try store.purgeRead(before: Date(timeIntervalSince1970: 200))

        let rows = try await database.reader.read { db in
            try Row.fetchAll(db, sql: "SELECT localKey, deleted FROM syncRecord WHERE entity = 'reading'")
                .map { ($0["localKey"] as String, $0["deleted"] as Bool) }
        }
        #expect(rows.count == 1)
        #expect(rows.first?.0 == "https://example.com/deleted" && rows.first?.1 == true)
    }

    // MARK: Search

    func item(_ path: String, title: String? = nil, added: TimeInterval, read: TimeInterval? = nil, note: String? = nil) -> ReadingItem {
        ReadingItem(
            url: "https://example.com/\(path)", title: title, note: note,
            addedAt: Date(timeIntervalSince1970: added), readAt: read.map { Date(timeIntervalSince1970: $0) })
    }

    @Test func listsUnreadNewestFirstThenReadMostRecentlyRead() {
        let items = [
            item("a", added: 1), item("b", added: 3), item("c", added: 2, read: 10), item("d", added: 5, read: 20),
        ]
        let order = ReadingListSearch.rank(items, query: "").map(\.url.last)
        #expect(order == ["b", "a", "d", "c"])
        let unread = ReadingListSearch.rank(items, query: "", includeRead: false).map(\.url.last)
        #expect(unread == ["b", "a"])
    }

    @Test func searchesTitlesBeforeTheRestAndAlwaysFindsReadLinks() {
        let items = [
            item("swift-notes", title: "Notes", added: 3),
            item("x", title: "Swift Concurrency", added: 1, read: 5),
            item("y", title: "Cooking", added: 2, note: "recommended by swift people"),
        ]
        let titles = ReadingListSearch.rank(items, query: "swift", includeRead: false).map(\.title)
        #expect(titles == ["Swift Concurrency", "Notes", "Cooking"])
        #expect(ReadingListSearch.rank(items, query: "swift conc").map(\.title) == ["Swift Concurrency"])
        #expect(ReadingListSearch.rank(items, query: "example.com").count == 3, "the host matches")
        #expect(ReadingListSearch.rank(items, query: "nothing").isEmpty)
    }
}
