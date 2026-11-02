import Foundation
import GRDB
import Testing
@testable import CortexCore

/// Clips through the sync engine (docs/SYNC.md, "Handling per data type"): two
/// databases with real `ClipStore`s against one fake server.
@Suite struct SyncClipTests {
    let server = InMemorySyncServer()
    let key = SyncKey.generate()

    struct ClipPeer {
        let peer: SyncPeer
        let clips: ClipStore
        var database: AppDatabase { peer.database }
        var engine: SyncEngine { peer.engine }

        func hash(of text: String) -> String { textSnapshot(text).contentHash }

        func item(_ text: String) throws -> ClipItem? {
            let hash = hash(of: text)
            return try database.reader.read { db in
                try ClipItem.filter(ClipItem.Columns.contentHash == hash).fetchOne(db)
            }
        }

        func item(hash: String) async throws -> ClipItem? {
            try await database.reader.read { db in
                try ClipItem.filter(ClipItem.Columns.contentHash == hash).fetchOne(db)
            }
        }

        func detail(_ item: ClipItem) async throws -> ClipDetail {
            let id = try #require(item.id)
            return try #require(try await clips.detail(id: id))
        }

        func texts() throws -> [String] {
            try database.reader.read { db in
                try String.fetchAll(db, sql: "SELECT plainText FROM clipItem ORDER BY plainText")
            }
        }

        func delete(_ text: String) throws {
            let id = try #require(try item(text)?.id)
            try clips.delete(ids: [id])
        }

        func blobFiles() throws -> Int { try database.blobs.storedIDs().count }
    }

    func peer(_ options: ClipSyncOptions = ClipSyncOptions()) throws -> ClipPeer {
        let database = try makeTestDatabase()
        let clips = ClipStore(database: database)
        let transport = HookedTransport(DirectTransport(server: server))
        return ClipPeer(
            peer: SyncPeer(
                database: database, transport: transport, key: key,
                handlers: [ClipSyncHandler(store: clips, options: options)]),
            clips: clips)
    }

    func tick() async throws { try await Task.sleep(for: .milliseconds(5)) }

    func imageSnapshot(at date: Date = .now) -> ClipSnapshot {
        ClipSnapshot(
            representations: [LoadedRepresentation(type: ClipType.png, data: makePNG())],
            plainText: nil, isSensitive: false, sourceBundleID: "test.Preview", sourceAppName: "Preview", copiedAt: date)
    }

    // MARK: Round trips

    @Test func aTextClipArrivesWithEverythingButTheDerivedColumnsRebuilt() async throws {
        let a = try peer(), b = try peer()
        let copied = Date(timeIntervalSinceNow: -3600)
        try a.clips.record(textSnapshot("hello world", app: "Notes", at: copied), indexSensitive: false, pin: true)
        let report = try await a.engine.runCycle()
        #expect(report.sent == 1)
        #expect(server.records.first?.keep == true)

        let received = try await b.engine.runCycle()
        #expect(received.applied == 1)
        let item = try #require(try b.item("hello world"))
        let original = try #require(try a.item("hello world"))
        #expect(item.isPinned && !item.isSensitive)
        #expect(item.sourceAppName == "Notes" && item.sourceBundleID == "test.Notes")
        #expect(item.createdAt.syncMilliseconds == original.createdAt.syncMilliseconds)
        #expect(item.lastCopiedAt.syncMilliseconds == copied.syncMilliseconds)
        #expect(item.preview == "hello world" && item.searchText.contains("hello world"))
        let detail = try await b.detail(item)
        #expect(detail.data(for: ClipType.plainText) == Data("hello world".utf8))
        #expect(try await b.clips.summaries(matching: "hello").count == 1)

        // Nothing echoes back.
        #expect(try b.peer.pendingCount == 0)
        let seqs = server.records.map(\.seq)
        try await b.engine.runCycle()
        try await a.engine.runCycle()
        #expect(server.records.map(\.seq) == seqs)
    }

    @Test func imagesAndLargeTextTravelAsBlobs() async throws {
        let a = try peer(), b = try peer()
        let image = imageSnapshot()
        try a.clips.record(image, indexSensitive: false)
        let large = String(repeating: "lorem ipsum ", count: 40_000)   // 480 KB, above the inline limit
        try a.clips.record(textSnapshot(large), indexSensitive: false)
        try await a.engine.runCycle()

        // Only ciphertext on the server, and the clips refer to blobs.
        #expect(server.blobIDs.count == 2)   // the PNG and the large text
        _ = try await b.engine.runCycle()

        let imageItem = try #require(try await b.item(hash: image.contentHash))
        #expect(imageItem.kind == .image && imageItem.thumbnail != nil)
        let detail = try await b.detail(imageItem)
        #expect(detail.imageData == image.representations[0].data)

        let largeItem = try #require(try b.item(large))
        let largeDetail = try await b.detail(largeItem)
        #expect(largeDetail.data(for: ClipType.plainText) == Data(large.utf8))
        // Stored locally with this Mac's own key, as blobs.
        #expect(try b.blobFiles() == 2)
        #expect(try b.clips.removeOrphanBlobs() == 0)
    }

    @Test func theSameClipCopiedOnBothMacsMergesIntoOne() async throws {
        let a = try peer(), b = try peer()
        let early = Date(timeIntervalSinceNow: -600), late = Date.now
        try a.clips.record(textSnapshot("shared", at: early), indexSensitive: false)
        try await tick()
        try b.clips.record(textSnapshot("shared", at: late), indexSensitive: false)

        try await a.engine.runCycle()
        try await b.engine.runCycle()
        try await a.engine.runCycle()
        try await b.engine.runCycle()

        #expect(try a.texts() == ["shared"] && b.texts() == ["shared"])
        #expect(server.records.count == 1)
        // Both end with the later copy date.
        #expect(try a.item("shared")?.lastCopiedAt.syncMilliseconds == late.syncMilliseconds)
        #expect(try b.item("shared")?.lastCopiedAt.syncMilliseconds == late.syncMilliseconds)
        #expect(try a.peer.pendingCount == 0 && b.peer.pendingCount == 0)
    }

    @Test func aWriteThatLosesStillBringsTheLaterCopyDateToTheOtherMac() async throws {
        // A copied "x" early and then pinned it (its write is the newest). B copied it later.
        let a = try peer(), b = try peer()
        let early = Date(timeIntervalSinceNow: -600), late = Date.now
        try a.clips.record(textSnapshot("x", at: early), indexSensitive: false)
        try await tick()
        try b.clips.record(textSnapshot("x", at: late), indexSensitive: false)
        try await tick()
        let xID = try #require(try a.item("x")?.id)
        try a.clips.setPinned(true, id: xID)

        try await a.engine.runCycle()
        let received = try await b.engine.runCycle()   // A's write wins, but B's copy date is later
        #expect(received.applied == 1 && received.sent == 1)
        try await a.engine.runCycle()

        for side in [a, b] {
            let item = try #require(try side.item("x"))
            #expect(item.isPinned)
            #expect(item.lastCopiedAt.syncMilliseconds == late.syncMilliseconds)
            #expect(try side.peer.pendingCount == 0)
        }
        // The merge settled: another round changes nothing.
        let seqs = server.records.map(\.seq)
        try await b.engine.runCycle()
        try await a.engine.runCycle()
        #expect(server.records.map(\.seq) == seqs)
    }

    @Test func sensitiveIsOredAndPinFollowsTheNewerWrite() async throws {
        let a = try peer(ClipSyncOptions(syncSensitive: true)), b = try peer(ClipSyncOptions(syncSensitive: true))
        try a.clips.record(textSnapshot("secret", sensitive: false), indexSensitive: false, pin: true)
        try await a.engine.runCycle()
        try await b.engine.runCycle()
        #expect(try b.item("secret")?.isPinned == true)

        try await tick()
        try b.clips.record(textSnapshot("secret", sensitive: true), indexSensitive: false)   // now sensitive on B
        try await tick()
        let secretID = try #require(try b.item("secret")?.id)
        try b.clips.setPinned(false, id: secretID)
        try await b.engine.runCycle()
        try await a.engine.runCycle()

        let item = try #require(try a.item("secret"))
        #expect(item.isSensitive && !item.isPinned)
    }

    @Test func pinningAndUnpinningTravel() async throws {
        let a = try peer(), b = try peer()
        try a.clips.record(textSnapshot("note"), indexSensitive: false)
        try await a.engine.runCycle()
        try await b.engine.runCycle()
        #expect(try b.item("note")?.isPinned == false)

        try await tick()
        let noteID = try #require(try a.item("note")?.id)
        try a.clips.setPinned(true, id: noteID)
        try await a.engine.runCycle()
        try await b.engine.runCycle()
        #expect(try b.item("note")?.isPinned == true)
        #expect(server.records.first?.keep == true)

        try await tick()
        let noteIDOnB = try #require(try b.item("note")?.id)
        try b.clips.setPinned(false, id: noteIDOnB)
        try await b.engine.runCycle()
        try await a.engine.runCycle()
        #expect(try a.item("note")?.isPinned == false)
        #expect(server.records.first?.keep == false)
    }

    @Test func dateMillisecondsSurviveTheDatabase() throws {
        let a = try peer()
        var generator = SystemRandomNumberGenerator()
        for index in 0..<200 {
            let ms = Int64.random(in: 1_500_000_000_000...1_900_000_000_000, using: &generator)
            try a.clips.record(textSnapshot("clip \(index)", at: Date(syncMilliseconds: ms)), indexSensitive: false)
            #expect(try a.item("clip \(index)")?.lastCopiedAt.syncMilliseconds == ms)
        }
    }

    // MARK: Deletes

    @Test func anExplicitDeleteTravelsAndTakesTheBlobsWithIt() async throws {
        let a = try peer(), b = try peer()
        let image = imageSnapshot()
        try a.clips.record(image, indexSensitive: false)
        try a.clips.record(textSnapshot("keep me"), indexSensitive: false)
        try await a.engine.runCycle()
        try await b.engine.runCycle()
        #expect(try b.blobFiles() == 1)

        try await tick()
        let imageItem = try #require(try await b.item(hash: image.contentHash))
        try b.clips.delete(ids: [try #require(imageItem.id)])
        try await b.engine.runCycle()
        try await a.engine.runCycle()

        #expect(try a.texts() == ["keep me"])
        #expect(try a.blobFiles() == 0)
        #expect(try a.peer.pendingCount == 0)
    }

    @Test func purgeAndClearHistoryStayLocal() async throws {
        let a = try peer(), b = try peer()
        try a.clips.record(textSnapshot("old", at: Date(timeIntervalSinceNow: -90 * 86_400)), indexSensitive: false)
        try a.clips.record(textSnapshot("recent"), indexSensitive: false)
        try await a.engine.runCycle()
        try await b.engine.runCycle()

        #expect(try a.clips.purge(policy: RetentionPolicy(maxAge: 30 * 86_400, maxCount: nil)) == 1)
        try await a.engine.runCycle()
        try await b.engine.runCycle()
        #expect(try b.texts() == ["old", "recent"])

        try a.clips.deleteAll(includingPinned: true)
        try await a.engine.runCycle()
        try await b.engine.runCycle()
        #expect(try a.texts().isEmpty)
        #expect(try b.texts() == ["old", "recent"])
        // No tombstone was written for any of it.
        #expect(server.records.allSatisfy { !$0.deleted })
    }

    @Test func aReCopyAfterARemoteDeleteResurrectsTheClip() async throws {
        let a = try peer(), b = try peer()
        try a.clips.record(textSnapshot("phoenix"), indexSensitive: false)
        try await a.engine.runCycle()
        try await b.engine.runCycle()

        try await tick()
        try a.delete("phoenix")
        try await a.engine.runCycle()
        try await b.engine.runCycle()
        #expect(try b.texts().isEmpty)

        try await tick()
        try b.clips.record(textSnapshot("phoenix"), indexSensitive: false)
        try await b.engine.runCycle()
        try await a.engine.runCycle()
        #expect(try a.texts() == ["phoenix"] && b.texts() == ["phoenix"])
        #expect(server.records.first?.deleted == false)
    }

    @Test func aClipCopiedAgainLocallyAfterTheRemoteDeleteSurvivesIt() async throws {
        let a = try peer(), b = try peer()
        try a.clips.record(textSnapshot("keeper"), indexSensitive: false)
        try await a.engine.runCycle()
        try await b.engine.runCycle()

        try await tick()
        try a.delete("keeper")
        try await tick()
        try b.clips.record(textSnapshot("keeper"), indexSensitive: false)   // later than the delete
        try await a.engine.runCycle()
        try await b.engine.runCycle()   // the older tombstone doesn't apply
        try await a.engine.runCycle()
        #expect(try b.texts() == ["keeper"] && a.texts() == ["keeper"])
    }

    // MARK: Filters

    @Test func filesClipsAndOversizedClipsStayLocal() async throws {
        let a = try peer(ClipSyncOptions(maxClipBytes: 1_000)), b = try peer()
        let files = ClipSnapshot(
            representations: [ClipSnapshot.fileURLRepresentation([URL(filePath: "/tmp/a.txt")])],
            plainText: nil, isSensitive: false)
        try a.clips.record(files, indexSensitive: false)
        try a.clips.record(textSnapshot(String(repeating: "x", count: 2_000)), indexSensitive: false)
        try a.clips.record(textSnapshot("small"), indexSensitive: false)

        let report = try await a.engine.runCycle()
        #expect(report.sent == 1)
        #expect(try a.peer.pendingCount == 0)
        try await b.engine.runCycle()
        #expect(try b.texts() == ["small"])
    }

    @Test func sensitiveClipsTravelOnlyWhenEnabled() async throws {
        let off = try peer(), on = try peer(ClipSyncOptions(syncSensitive: true)), other = try peer(ClipSyncOptions(syncSensitive: true))
        try off.clips.record(textSnapshot("password", sensitive: true), indexSensitive: false)
        try off.clips.record(textSnapshot("plain"), indexSensitive: false)
        try await off.engine.runCycle()
        #expect(server.records.count == 1)

        try on.clips.record(textSnapshot("token", sensitive: true), indexSensitive: false)
        try await on.engine.runCycle()
        #expect(server.records.count == 2)

        // A Mac that has it off doesn't take sensitive clips in either.
        let report = try await off.engine.runCycle()
        #expect(report.pulled >= 1)
        #expect(try off.texts() == ["password", "plain"])
        // One that has it on does, and keeps them sensitive.
        try await other.engine.runCycle()
        #expect(try other.texts() == ["plain", "token"])
        #expect(try other.item("token")?.isSensitive == true)
    }

    @Test func aClipLocalRetentionWouldPurgeRightAwayIsNotStored() async throws {
        let a = try peer()
        let b = try peer(ClipSyncOptions(retention: RetentionPolicy(maxAge: 30 * 86_400, maxCount: nil)))
        try a.clips.record(textSnapshot("ancient", at: Date(timeIntervalSinceNow: -60 * 86_400)), indexSensitive: false)
        try a.clips.record(textSnapshot("ancient pinned", at: Date(timeIntervalSinceNow: -60 * 86_400)), indexSensitive: false, pin: true)
        try a.clips.record(textSnapshot("fresh"), indexSensitive: false)
        try await a.engine.runCycle()

        try await b.engine.runCycle()
        #expect(try b.texts() == ["ancient pinned", "fresh"])
        #expect(try b.peer.pendingCount == 0)
        // Not stored and not echoed back as a delete.
        #expect(server.records.allSatisfy { !$0.deleted })
        #expect(try b.blobFiles() == 0)
    }

    @Test func aPayloadWhoseContentDoesNotMatchItsHashIsSkipped() async throws {
        let a = try peer(), b = try peer()
        try a.clips.record(textSnapshot("genuine"), indexSensitive: false)
        // Re-seal a tampered payload under the genuine record ID, the way a buggy peer could.
        let hash = a.hash(of: "genuine")
        let id = key.recordID(.clip, localKey: hash)
        let forged = ClipPayload(
            v: 1, contentHash: hash, kind: .text,
            representations: [.init(type: ClipType.plainText, data: Data("forged".utf8), blob: nil, size: 6)],
            plainText: "forged", isSensitive: false, isPinned: false, sourceBundleID: nil, sourceAppName: nil,
            createdAt: 1, lastCopiedAt: 1)
        let direct = DirectTransport(server: server)
        _ = try await direct.push(device: "forger", records: [
            try .sealed(try JSONEncoder().encode(forged), key: key, collection: .clip, id: id, device: "forger"),
        ])

        let report = try await b.engine.runCycle()
        #expect(report.skipped == 1 && report.applied == 0)
        #expect(try b.texts().isEmpty)
        #expect(try b.blobFiles() == 0)
    }
}
