import Foundation
import GRDB
import Testing
@testable import CortexCore

/// Snippets through the sync engine (docs/SYNC.md, "Handling per data type"): two
/// databases with real `SnippetStore`s against one fake server.
@Suite struct SyncSnippetTests {
    let server = InMemorySyncServer()
    let key = SyncKey.generate()

    func peer() throws -> SyncPeer {
        let database = try makeTestDatabase()
        return SyncPeer(
            database: database, transport: HookedTransport(DirectTransport(server: server)), key: key,
            handlers: [SnippetSyncHandler(store: SnippetStore(database: database))])
    }

    func tick() async throws { try await Task.sleep(for: .milliseconds(5)) }

    func snippet(_ peer: SyncPeer, _ name: String) async throws -> Snippet? {
        try await peer.snippets.all().first { $0.name == name }
    }

    /// Pushes a snippet record the way a third Mac would.
    func pushRemote(_ payload: SnippetPayload, at modifiedAt: Int64 = Int64(Date.now.timeIntervalSince1970 * 1000), device: String = "remote-mac") async throws {
        let id = key.recordID(.snippet, localKey: payload.syncID)
        _ = try await DirectTransport(server: server).push(device: device, records: [
            try .sealed(try JSONEncoder().encode(payload), key: key, collection: .snippet, id: id, modifiedAt: modifiedAt, device: device),
        ])
    }

    func payload(_ syncID: String, _ name: String, keyword: String? = nil, body: String = "body", tags: [String] = []) -> SnippetPayload {
        SnippetPayload(
            v: 1, syncID: syncID, name: name, keyword: keyword, body: body, tags: tags,
            createdAt: 1_700_000_000_000, updatedAt: 1_700_000_100_000)
    }

    // MARK: Round trips

    @Test func aSnippetArrivesWithAllItsFields() async throws {
        let a = try peer(), b = try peer()
        let saved = try a.snippets.save(Snippet(
            name: "Signature", keyword: "sig", body: "Best,\n{date}", tags: ["mail", "work"],
            createdAt: Date(timeIntervalSinceNow: -3600), updatedAt: .now))
        try await a.engine.runCycle()
        try await b.engine.runCycle()

        let received = try #require(try await snippet(b, "Signature"))
        #expect(received.keyword == "sig" && received.body == "Best,\n{date}" && received.tags == ["mail", "work"])
        let savedID = try #require(saved.id)
        let stored = try #require(try await a.snippets.snippet(id: savedID))
        #expect(received.createdAt.syncMilliseconds == stored.createdAt.syncMilliseconds)
        #expect(received.updatedAt.syncMilliseconds == stored.updatedAt.syncMilliseconds)
        #expect(try await b.snippets.keywords()["sig"] == received.id)
        #expect(try b.pendingCount == 0)
    }

    @Test func aRenameAndAKeywordChangeTravel() async throws {
        let a = try peer(), b = try peer()
        var original = try a.snippets.save(Snippet(name: "Greeting", keyword: "hi", body: "hello"))
        try await a.engine.runCycle()
        try await b.engine.runCycle()

        try await tick()
        original.name = "Welcome"
        original.keyword = "wel"
        original.body = "welcome"
        original.tags = ["x"]
        try a.snippets.save(original)
        try await a.engine.runCycle()
        try await b.engine.runCycle()

        #expect(try await b.snippets.all().map(\.name) == ["Welcome"])
        let received = try #require(try await snippet(b, "Welcome"))
        #expect(received.keyword == "wel" && received.body == "welcome" && received.tags == ["x"])
        let receivedID = try #require(received.id)
        #expect(try await b.snippets.keywords() == ["wel": receivedID])
    }

    @Test func usageStaysLocal() async throws {
        let a = try peer(), b = try peer()
        let saved = try a.snippets.save(Snippet(name: "Greeting", body: "hello"))
        try await a.engine.runCycle()
        try await b.engine.runCycle()
        let idOnB = try #require(try await snippet(b, "Greeting")?.id)
        let idOnA = try #require(saved.id)
        try b.snippets.markUsed(id: idOnB)
        try a.snippets.markUsed(id: idOnA)
        try a.snippets.markUsed(id: idOnA)

        // Neither use counts as an edit.
        #expect(try a.pendingCount == 0 && b.pendingCount == 0)
        try await tick()
        var edited = try #require(try await a.snippets.snippet(id: idOnA))
        edited.body = "hello there"
        try a.snippets.save(edited)
        try await a.engine.runCycle()
        try await b.engine.runCycle()

        let onB = try #require(try await snippet(b, "Greeting"))
        #expect(onB.body == "hello there" && onB.usageCount == 1 && onB.lastUsedAt != nil)
        let onA = try #require(try await snippet(a, "Greeting"))
        #expect(onA.usageCount == 2)
    }

    @Test func syncedMeansTheServerHasAVersion() async throws {
        let a = try peer(), b = try peer()
        let saved = try a.snippets.save(Snippet(name: "Greeting", body: "hello"))
        let syncID = try #require(try a.syncID(ofSnippet: "Greeting"))
        #expect(try !a.isSynced("snippet", syncID))
        try await a.engine.runCycle()
        #expect(try a.isSynced("snippet", syncID))

        // An edit makes it pending again, but it stays synced.
        try await tick()
        var edited = saved
        edited.body = "changed"
        try a.snippets.save(edited)
        #expect(try a.pendingCount == 1 && a.isSynced("snippet", syncID))

        // What arrives from the server is synced too.
        try await b.engine.runCycle()
        #expect(try b.isSynced("snippet", syncID))
    }

    @Test func aDeleteTravels() async throws {
        let a = try peer(), b = try peer()
        let saved = try a.snippets.save(Snippet(name: "Short-lived", keyword: "sl", body: "x"))
        try await a.engine.runCycle()
        try await b.engine.runCycle()
        try await tick()
        try a.snippets.delete(id: try #require(saved.id))
        try await a.engine.runCycle()
        try await b.engine.runCycle()
        #expect(try await b.snippets.all().isEmpty)
        #expect(try await b.snippets.keywords().isEmpty)
        #expect(try b.pendingCount == 0)
    }

    // MARK: First sync

    @Test func theFirstSyncWithTheSameImportOnBothMacsLeavesNoDuplicates() async throws {
        let a = try peer(), b = try peer()
        let names = ["Address", "Signature", "Standup", "Zoom link"]
        for peer in [a, b] {
            for (index, name) in names.enumerated() {
                try peer.snippets.save(Snippet(
                    name: name, keyword: "k\(index)", body: "text of \(name)", tags: ["imported"],
                    createdAt: Date(timeIntervalSince1970: 1_700_000_000), updatedAt: Date(timeIntervalSince1970: 1_700_000_000)))
            }
            try await tick()
        }
        // Local use counts differ and must survive.
        let signatureOnB = try #require(try await snippet(b, "Signature")?.id)
        try b.snippets.markUsed(id: signatureOnB)

        try await a.engine.runCycle()
        let received = try await b.engine.runCycle()
        try await a.engine.runCycle()
        try await b.engine.runCycle()

        #expect(received.applied == 4 && received.sent == 0)
        for side in [a, b] {
            #expect(try await side.snippets.all().map(\.name) == names)
            #expect(try side.pendingCount == 0)
        }
        #expect(try await b.snippets.keywords().count == 4)
        for name in names {
            #expect(try a.syncID(ofSnippet: name) == b.syncID(ofSnippet: name))
        }
        #expect(server.records.count == 4)
        #expect(try await snippet(b, "Signature")?.usageCount == 1)
        // Only the adopted keys have rows: no leftovers under B's old syncIDs.
        #expect(try b.rows("snippet").count == 4)
    }

    @Test func anAdoptedSnippetKeepsTheNewerContent() async throws {
        let a = try peer(), b = try peer()
        try a.snippets.save(Snippet(name: "Greeting", body: "from A"))
        try await tick()
        try b.snippets.save(Snippet(name: "greeting", body: "from B"))   // newer, other case

        try await a.engine.runCycle()
        let received = try await b.engine.runCycle()
        #expect(received.sent == 1)   // B's content goes back, under A's syncID
        try await a.engine.runCycle()

        #expect(try await a.snippets.all().map(\.body) == ["from B"])
        #expect(try await b.snippets.all().map(\.body) == ["from B"])
        #expect(try a.syncID(ofSnippet: "Greeting") == b.syncID(ofSnippet: "greeting"))
        #expect(try a.pendingCount == 0 && b.pendingCount == 0)
        #expect(server.records.count == 1)
    }

    @Test func anAdoptedSnippetTakesTheNewerRemoteContent() async throws {
        let a = try peer(), b = try peer()
        try b.snippets.save(Snippet(name: "Greeting", body: "from B"))
        try await tick()
        try a.snippets.save(Snippet(name: "Greeting", body: "from A"))   // newer

        try await a.engine.runCycle()
        let received = try await b.engine.runCycle()
        #expect(received.sent == 0)
        #expect(try await b.snippets.all().map(\.body) == ["from A"])
    }

    @Test func aSyncedSnippetIsNotAdoptedByAnotherWithTheSameName() async throws {
        let a = try peer()
        try a.snippets.save(Snippet(name: "Foo", body: "mine"))
        try await a.engine.runCycle()   // acknowledged: it is synced now
        try await pushRemote(payload("other-sync-id", "foo", body: "theirs"))

        try await a.engine.runCycle()
        // The older write gives way: the local snippet, here.
        #expect(try await a.snippets.all().map(\.name).sorted() == ["Foo (2)", "foo"])
        #expect(try await snippet(a, "foo")?.body == "theirs")
        #expect(try await snippet(a, "Foo (2)")?.body == "mine")
        #expect(try a.pendingCount == 0)   // the renamed one went to the server in the same cycle
        #expect(server.records.count == 2)
    }

    // MARK: Clashes

    @Test func aRenameOntoATakenNameGetsANumber() async throws {
        let a = try peer(), b = try peer()
        var renamed = try a.snippets.save(Snippet(name: "Greeting", body: "hello"))
        try await a.engine.runCycle()
        try await b.engine.runCycle()
        try b.snippets.save(Snippet(name: "Welcome", body: "own"))
        try await b.engine.runCycle()   // synced, so not adopted

        try await tick()
        renamed.name = "Welcome"
        try a.snippets.save(renamed)
        try await a.engine.runCycle()    // pulls B's "Welcome" first
        try await b.engine.runCycle()

        try await a.engine.runCycle()

        // B's snippet is the older write, so it gives way, on both Macs alike.
        for side in [a, b] {
            #expect(try await side.snippets.all().map(\.name).sorted() == ["Welcome", "Welcome (2)"])
            #expect(try await snippet(side, "Welcome")?.body == "hello")
            #expect(try await snippet(side, "Welcome (2)")?.body == "own")
            #expect(try side.pendingCount == 0)
        }
        try await settled(a, b)
    }

    @Test func aRenameThatClashesWithAnotherSnippetsNameEndsTheSameOnBothMacs() async throws {
        // Both rename different snippets to the same name while offline.
        let a = try peer(), b = try peer()
        var one = try a.snippets.save(Snippet(name: "One", body: "1"))
        try a.snippets.save(Snippet(name: "Two", body: "2"))
        try await a.engine.runCycle()
        try await b.engine.runCycle()

        one.name = "Same"
        try a.snippets.save(one)
        try await tick()
        var two = try #require(try await snippet(b, "Two"))
        two.name = "Same"
        try b.snippets.save(two)

        for _ in 0..<3 {
            try await a.engine.runCycle()
            try await b.engine.runCycle()
        }
        for side in [a, b] {
            #expect(try await side.snippets.all().map(\.name).sorted() == ["Same", "Same (2)"])
            #expect(try await snippet(side, "Same")?.body == "2")   // the newer rename keeps the name
            #expect(try side.pendingCount == 0)
        }
        try await settled(a, b)
    }

    @Test func twoNewSnippetsWithTheSameKeywordSettleOnTheNewerOne() async throws {
        let a = try peer(), b = try peer()
        // Offline on both: each Mac makes a snippet with the same keyword.
        try a.snippets.save(Snippet(name: "From A", keyword: "kw", body: "a"))
        try await tick()
        try b.snippets.save(Snippet(name: "From B", keyword: "kw", body: "b"))

        for _ in 0..<2 {
            try await a.engine.runCycle()
            try await b.engine.runCycle()
        }
        for side in [a, b] {
            #expect(try await snippet(side, "From B")?.keyword == "kw")
            #expect(try await snippet(side, "From A")?.keyword == nil)
            #expect(try side.pendingCount == 0)
        }
        try await settled(a, b)
    }

    /// Another round of cycles changes nothing on the server.
    func settled(_ a: SyncPeer, _ b: SyncPeer) async throws {
        let seqs = server.records.map(\.seq)
        try await a.engine.runCycle()
        try await b.engine.runCycle()
        try await a.engine.runCycle()
        #expect(server.records.map(\.seq) == seqs)
        #expect(try await a.snippets.all().map(\.name) == b.snippets.all().map(\.name))
    }

    @Test func theOlderSnippetLosesItsKeywordWhenTheRemoteOneIsNewer() async throws {
        let a = try peer()
        try a.snippets.save(Snippet(name: "Local", keyword: "sig", body: "local"))
        try await a.engine.runCycle()
        try await tick()
        // A newer remote snippet claims the keyword.
        try await pushRemote(payload("remote-id", "Remote", keyword: "sig", body: "remote"))

        try await a.engine.runCycle()
        try await a.engine.runCycle()
        #expect(try await snippet(a, "Remote")?.keyword == "sig")
        #expect(try await snippet(a, "Local")?.keyword == nil)
        #expect(try await a.snippets.keywords().count == 1)
        #expect(try a.pendingCount == 0)
    }

    @Test func theRemoteSnippetLosesItsKeywordWhenTheLocalOneIsNewer() async throws {
        let a = try peer(), b = try peer()
        try await pushRemote(payload("remote-id", "Remote", keyword: "sig", body: "remote"), at: 1_000)
        try a.snippets.save(Snippet(name: "Local", keyword: "sig", body: "local"))
        try await a.engine.runCycle()   // already synced: not adopted by name; pulls the older remote one

        #expect(try await snippet(a, "Remote")?.keyword == nil)
        #expect(try await snippet(a, "Local")?.keyword == "sig")
        // A sends the keyword-less version back, so B sees the same.
        try await a.engine.runCycle()
        try await b.engine.runCycle()
        try await a.engine.runCycle()
        #expect(try await snippet(b, "Remote")?.keyword == nil)
        #expect(try await snippet(b, "Local")?.keyword == "sig")
        #expect(try a.pendingCount == 0 && b.pendingCount == 0)
    }

    // MARK: Validation

    @Test func remoteDataGoesThroughTheSameNormalizationAndValidation() async throws {
        let a = try peer()
        try await pushRemote(payload("id-1", "  Padded  ", keyword: " kw ", tags: [" a ", "A", ""]))
        try await pushRemote(payload("id-2", "   "))                       // no name
        try await pushRemote(payload("id-3", "Spaced keyword", keyword: "two words"))
        try await pushRemote(payload("id-4", "Fine"))

        let report = try await a.engine.runCycle()
        #expect(report.skipped == 2 && report.applied == 2)
        let all = try await a.snippets.all()
        #expect(all.map(\.name).contains("Padded") && all.map(\.name).contains("Fine"))
        let padded = try #require(try await snippet(a, "Padded"))
        #expect(padded.keyword == "kw" && padded.tags == ["a"])
        #expect(all.count == 2)
    }
}
