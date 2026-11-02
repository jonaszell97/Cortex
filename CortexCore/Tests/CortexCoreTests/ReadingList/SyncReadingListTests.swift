import Foundation
import GRDB
import Testing
@testable import CortexCore

/// Reading list links through the sync engine: two databases with real
/// `ReadingListStore`s against one fake server.
@Suite struct SyncReadingListTests {
    let server = InMemorySyncServer()
    let key = SyncKey.generate()

    struct Mac {
        let peer: SyncPeer
        let store: ReadingListStore
        var engine: SyncEngine { peer.engine }
    }

    func mac(deleteReadBefore: Date? = nil) throws -> Mac {
        let database = try makeTestDatabase()
        let store = ReadingListStore(database: database)
        let peer = SyncPeer(
            database: database, transport: HookedTransport(DirectTransport(server: server)), key: key,
            handlers: [ReadingListSyncHandler(store: store, deleteReadBefore: deleteReadBefore)])
        return Mac(peer: peer, store: store)
    }

    func tick() async throws { try await Task.sleep(for: .milliseconds(5)) }

    func link(_ mac: Mac, _ url: String) async throws -> ReadingItem? {
        try await mac.store.all().first { $0.url == url }
    }

    @Test func aLinkArrivesWithAllItsFields() async throws {
        let a = try mac(), b = try mac()
        let saved = try a.store.add(url: "https://example.com/a", title: "A", sourceAppName: "Safari")
        try a.store.edit(id: try #require(saved.id), title: "A", note: "later")
        try await a.engine.runCycle()
        try await b.engine.runCycle()

        let received = try #require(try await link(b, "https://example.com/a"))
        #expect(received.title == "A" && received.note == "later" && received.sourceAppName == "Safari")
        #expect(received.addedAt.syncMilliseconds == saved.addedAt.syncMilliseconds)
        #expect(received.readAt == nil)
        #expect(try b.peer.pendingCount == 0, "an applied link does not echo back")
    }

    @Test func readingOnOneMacMarksItReadOnTheOther() async throws {
        let a = try mac(), b = try mac()
        try a.store.add(url: "https://example.com/a")
        try await a.engine.runCycle()
        try await b.engine.runCycle()

        try await tick()
        let onB = try #require(try await link(b, "https://example.com/a")?.id)
        try b.store.setRead(true, id: onB, at: Date(timeIntervalSince1970: 1_800_000_000))
        try await b.engine.runCycle()
        try await a.engine.runCycle()

        let onA = try #require(try await link(a, "https://example.com/a"))
        #expect(onA.readAt == Date(timeIntervalSince1970: 1_800_000_000))
    }

    @Test func theSameLinkSavedOnBothMacsIsOneLink() async throws {
        let a = try mac(), b = try mac()
        try a.store.add(url: "https://example.com/a", title: "From A")
        try await tick()
        try b.store.add(url: "example.com/a?utm_source=x", title: "From B")
        try await a.engine.runCycle()
        try await b.engine.runCycle()
        try await a.engine.runCycle()

        #expect(try await a.store.all().map(\.title) == ["From B"], "the newer write wins")
        #expect(try await b.store.all().map(\.title) == ["From B"])
    }

    @Test func aDeleteTravelsAndAPurgeDoesNot() async throws {
        let a = try mac(deleteReadBefore: Date(timeIntervalSince1970: 200)), b = try mac()
        let deleted = try #require(try a.store.add(url: "https://example.com/deleted").id)
        let purged = try #require(try a.store.add(url: "https://example.com/purged").id)
        try a.store.setRead(true, id: purged, at: Date(timeIntervalSince1970: 100))
        try await a.engine.runCycle()
        try await b.engine.runCycle()
        #expect(try await b.store.all().count == 2)

        try await tick()
        try a.store.delete(id: deleted)
        try a.store.purgeRead(before: Date(timeIntervalSince1970: 200))
        try await a.engine.runCycle()
        try await b.engine.runCycle()

        #expect(try await a.store.all().isEmpty, "the purged link does not come back from the server")
        #expect(try await b.store.all().map(\.url) == ["https://example.com/purged"])
        #expect(try b.peer.pendingCount == 0)
    }

    @Test func aLinkReadBeforeThePurgeDateIsNotStored() async throws {
        let a = try mac(), b = try mac(deleteReadBefore: Date(timeIntervalSince1970: 200))
        let old = try #require(try a.store.add(url: "https://example.com/old").id)
        let recent = try #require(try a.store.add(url: "https://example.com/recent").id)
        try a.store.setRead(true, id: old, at: Date(timeIntervalSince1970: 100))
        try a.store.setRead(true, id: recent, at: Date(timeIntervalSince1970: 300))
        try await a.engine.runCycle()
        try await b.engine.runCycle()
        #expect(try await b.store.all().map(\.url) == ["https://example.com/recent"])
    }

    @Test func aLinkDeletedAndSavedAgainComesBack() async throws {
        let a = try mac(), b = try mac()
        let id = try #require(try a.store.add(url: "https://example.com/a").id)
        try await a.engine.runCycle()
        try await b.engine.runCycle()

        try await tick()
        try a.store.delete(id: id)
        try await a.engine.runCycle()
        try await b.engine.runCycle()
        #expect(try await b.store.all().isEmpty)

        try await tick()
        try a.store.add(url: "https://example.com/a", title: "Again")
        try await a.engine.runCycle()
        try await b.engine.runCycle()
        #expect(try await b.store.all().map(\.title) == ["Again"])
    }

    @Test func aRemoteRecordThatIsNotALinkIsSkipped() async throws {
        let b = try mac()
        let payload = ReadingItemPayload(v: 1, url: "not a link", title: "x", addedAt: 1_700_000_000_000)
        let id = key.recordID(.reading, localKey: payload.url)
        _ = try await DirectTransport(server: server).push(device: "remote-mac", records: [
            try .sealed(try JSONEncoder().encode(payload), key: key, collection: .reading, id: id,
                        modifiedAt: Int64(Date.now.timeIntervalSince1970 * 1000), device: "remote-mac"),
        ])
        try await b.engine.runCycle()
        #expect(try await b.store.all().isEmpty)
    }
}
