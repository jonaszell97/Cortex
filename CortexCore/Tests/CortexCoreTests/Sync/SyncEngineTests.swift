import Foundation
import GRDB
import Testing
@testable import CortexCore

/// The sync cycle (docs/SYNC.md, "The sync cycle" and "Applying remote records"):
/// two databases against one fake server, the way the two Macs meet.
@Suite struct SyncEngineTests {
    let server = InMemorySyncServer()
    let key = SyncKey.generate()

    func peer(
        key: SyncKey? = nil, handlers: [any SyncEntityHandler] = [SnippetTestHandler()],
        onRemoteChanges: (@Sendable (SyncCycleReport) -> Void)? = nil
    ) throws -> SyncPeer {
        try SyncPeer(server: server, key: key ?? self.key, handlers: handlers, onRemoteChanges: onRemoteChanges)
    }

    /// A later `modifiedAt` for the next write.
    func tick() async throws { try await Task.sleep(for: .milliseconds(5)) }

    func edit(_ peer: SyncPeer, _ name: String, to body: String) throws {
        let syncID = try #require(try peer.syncID(ofSnippet: name))
        try peer.database.writer.write { db in
            try db.execute(sql: "UPDATE snippet SET body = ? WHERE syncID = ?", arguments: [body, syncID])
        }
    }

    // MARK: Basics

    @Test func theFirstCycleStoresTheEpochAndPushesWhatIsPending() async throws {
        let a = try peer()
        _ = try a.snippets.save(Snippet(name: "Greeting", body: "hello"))
        #expect(try a.pendingCount == 1)
        #expect(try a.database.syncState().epoch == nil)

        let report = try await a.engine.runCycle()

        #expect(report.sent == 1 && report.pulled == 0 && !report.epochReset)
        #expect(try a.pendingCount == 0)
        let state = try a.database.syncState()
        #expect(state.epoch == server.epoch)
        #expect(state.lastSuccess != nil)
        let stored = try #require(server.records.first)
        #expect(stored.collection == "snippet" && !stored.deleted)
        #expect(stored.device == (try a.deviceID))
        // The server holds ciphertext only.
        #expect(!String(decoding: try #require(stored.payload), as: UTF8.self).contains("hello"))
    }

    @Test func twoMacsConverge() async throws {
        let a = try peer(), b = try peer()
        _ = try a.snippets.save(Snippet(name: "Greeting", body: "hello"))
        try await a.engine.runCycle()

        let report = try await b.engine.runCycle()
        #expect(report.pulled == 1 && report.applied == 1 && report.sent == 0)
        #expect(try b.snippetBodies() == ["Greeting": "hello"])
        #expect(try b.syncID(ofSnippet: "Greeting") == a.syncID(ofSnippet: "Greeting"))

        // What B applied doesn't echo back: no pending row, no new record on the server.
        #expect(try b.pendingCount == 0)
        let seq = server.records.map(\.seq)
        try await b.engine.runCycle()
        try await a.engine.runCycle()
        #expect(server.records.map(\.seq) == seq)
        #expect(try b.row("snippet", try #require(try b.syncID(ofSnippet: "Greeting")))?.device == (try a.deviceID))
    }

    @Test func editsAndDeletesTravel() async throws {
        let a = try peer(), b = try peer()
        _ = try a.snippets.save(Snippet(name: "Greeting", body: "hello"))
        try await a.engine.runCycle()
        try await b.engine.runCycle()

        try await tick()
        try edit(b, "Greeting", to: "hello again")
        try await b.engine.runCycle()
        try await a.engine.runCycle()
        #expect(try a.snippetBodies() == ["Greeting": "hello again"])

        try await tick()
        try a.snippets.delete(id: try #require(try await a.snippets.all().first?.id))
        try await a.engine.runCycle()
        try await b.engine.runCycle()
        #expect(try b.snippetBodies().isEmpty)
        #expect(try a.pendingCount == 0 && b.pendingCount == 0)
        // The tombstone is sealed like any record, so only a Mac with the key can delete.
        let tombstone = try #require(server.records.first)
        #expect(tombstone.deleted)
        let opened = try key.open(try #require(tombstone.payload), for: SyncRecordHeader(tombstone.wire, collection: .snippet))
        #expect(SyncKey.isTombstone(opened))
    }

    @Test func aTombstoneForAnUnknownRecordChangesNothing() async throws {
        let a = try peer(), b = try peer()
        _ = try a.snippets.save(Snippet(name: "Short-lived", body: "x"))
        try await a.engine.runCycle()
        try a.snippets.delete(id: try #require(try await a.snippets.all().first?.id))
        try await a.engine.runCycle()

        let report = try await b.engine.runCycle()
        #expect(report.pulled == 1 && report.applied == 0 && report.skipped == 0)
        #expect(try b.snippetBodies().isEmpty)
        #expect(try b.database.syncState().cursor == 2)
    }

    @Test func remoteModifiedAtMustBeInRangeAndNotFarAhead() {
        let now: Int64 = 1_788_000_000_000
        let day: Int64 = 24 * 60 * 60 * 1000
        #expect(SyncEngine.isAcceptable(modifiedAt: 0, now: now))
        #expect(SyncEngine.isAcceptable(modifiedAt: now + day, now: now))
        #expect(!SyncEngine.isAcceptable(modifiedAt: now + day + 1, now: now))
        #expect(!SyncEngine.isAcceptable(modifiedAt: -1, now: now))
        #expect(!SyncEngine.isAcceptable(modifiedAt: SyncSchema.maxModifiedAt + 1, now: SyncSchema.maxModifiedAt))
        #expect(!SyncEngine.isAcceptable(modifiedAt: .max, now: .max - day))
    }

    @Test func aTombstoneFromTheFarFutureIsSkippedAndSyncGoesOn() async throws {
        let a = try peer(), b = try peer()
        _ = try a.snippets.save(Snippet(name: "Greeting", body: "hello"))
        try await a.engine.runCycle()
        try await b.engine.runCycle()
        let stored = try #require(server.records.first)

        // The server refuses a tombstone that would win forever; a compromised
        // one can still store it.
        server.overwrite(SyncWireRecord(
            collection: .snippet, id: stored.id, modifiedAt: SyncSchema.maxModifiedAt, device: "mac-x",
            deleted: true, payload: nil))
        let report = try await b.engine.runCycle()
        #expect(report.skipped == 1 && report.applied == 0)
        #expect(try b.snippetBodies() == ["Greeting": "hello"])

        // Later edits still push and cycles still succeed.
        try edit(b, "Greeting", to: "hi")
        try await b.engine.runCycle()
        #expect(try b.pendingCount == 0)
    }

    // MARK: Conflicts

    @Test func theNewerOfTwoConcurrentEditsWinsOnBothMacs() async throws {
        let a = try peer(), b = try peer()
        _ = try a.snippets.save(Snippet(name: "Greeting", body: "hello"))
        try await a.engine.runCycle()
        try await b.engine.runCycle()

        try edit(a, "Greeting", to: "from A")
        try await tick()
        try edit(b, "Greeting", to: "from B")   // later

        // A syncs first, B's later edit then wins over it.
        try await a.engine.runCycle()
        try await b.engine.runCycle()
        try await a.engine.runCycle()
        #expect(try a.snippetBodies() == ["Greeting": "from B"])
        #expect(try b.snippetBodies() == ["Greeting": "from B"])
        #expect(try a.pendingCount == 0 && b.pendingCount == 0)
    }

    @Test func theOlderEditLosesEvenWhenItSyncsLast() async throws {
        let a = try peer(), b = try peer()
        _ = try a.snippets.save(Snippet(name: "Greeting", body: "hello"))
        try await a.engine.runCycle()
        try await b.engine.runCycle()

        try edit(a, "Greeting", to: "from A")   // older
        try await tick()
        try edit(b, "Greeting", to: "from B")

        try await b.engine.runCycle()
        // A pulls B's newer write before pushing, so its own edit is replaced and not sent.
        let report = try await a.engine.runCycle()
        #expect(report.applied == 1 && report.sent == 0)
        try await b.engine.runCycle()
        #expect(try a.snippetBodies() == ["Greeting": "from B"])
        #expect(try b.snippetBodies() == ["Greeting": "from B"])
    }

    @Test func aStalePushPullsTheNewerWriteInTheSameCycle() async throws {
        let a = try peer(), b = try peer()
        _ = try a.snippets.save(Snippet(name: "Greeting", body: "hello"))
        try await a.engine.runCycle()
        try await b.engine.runCycle()

        try edit(a, "Greeting", to: "from A")   // older
        try await tick()
        try edit(b, "Greeting", to: "from B")
        // B's write reaches the server between A's pull and A's push.
        a.transport.beforePush { _ = try await b.engine.runCycle() }

        let report = try await a.engine.runCycle()
        #expect(report.stale == 1 && report.sent == 0 && report.applied == 1)
        #expect(try a.snippetBodies() == ["Greeting": "from B"])
        #expect(try a.pendingCount == 0)
    }

    @Test func equalTimestampsBreakTiesByDeviceLikeTheServer() async throws {
        // Local device IDs are uppercase hex: "zzz" is greater, "0" is smaller.
        for (device, remoteWins) in [("zzz", true), ("0", false)] {
            let server = InMemorySyncServer()
            let a = try SyncPeer(server: server, key: key)
            _ = try a.snippets.save(Snippet(name: "Greeting", body: "local"))
            let syncID = try #require(try a.syncID(ofSnippet: "Greeting"))
            let local = try #require(try a.row("snippet", syncID))

            let id = key.recordID(.snippet, localKey: syncID)
            let payload = try JSONEncoder().encode(
                SnippetTestHandler.Payload(v: 1, syncID: syncID, name: "Greeting", body: "remote"))
            _ = try await InMemoryServerProtocol.api(for: server).push(device: device, records: [
                try .sealed(payload, key: key, collection: .snippet, id: id, modifiedAt: local.modifiedAt, device: device)])

            try await a.engine.runCycle()
            #expect(try a.snippetBodies() == ["Greeting": remoteWins ? "remote" : "local"], "device \(device)")
            // Both ends agree on the winner.
            #expect(server.record("snippet", id)?.device == (remoteWins ? device : try a.deviceID))
            #expect(try a.pendingCount == 0)
        }
    }

    @Test func aTombstoneOlderThanALocalEditLoses() async throws {
        let a = try peer(), b = try peer()
        _ = try a.snippets.save(Snippet(name: "Greeting", body: "hello"))
        try await a.engine.runCycle()
        try await b.engine.runCycle()

        try a.snippets.delete(id: try #require(try await a.snippets.all().first?.id))
        try await tick()
        try edit(b, "Greeting", to: "edited after the delete")

        try await a.engine.runCycle()   // the tombstone reaches the server
        try await b.engine.runCycle()   // B keeps its newer edit and sends it
        try await a.engine.runCycle()   // and A gets the snippet back
        #expect(try b.snippetBodies() == ["Greeting": "edited after the delete"])
        #expect(try a.snippetBodies() == ["Greeting": "edited after the delete"])
    }

    // MARK: Push acknowledgments

    @Test func anEditDuringThePushIsNotAcknowledgedAndGoesOutNext() async throws {
        let a = try peer()
        _ = try a.snippets.save(Snippet(name: "Greeting", body: "v1"))
        a.transport.beforePush {
            try await Task.sleep(for: .milliseconds(5))
            try edit(a, "Greeting", to: "v2")
        }

        try await a.engine.runCycle()
        // The push of v1 cleared nothing, because the row changed in the meantime: v2 followed.
        #expect(a.transport.count("push") == 2)
        #expect(try a.pendingCount == 0)
        let stored = try #require(server.records.first)
        let opened = try key.open(try #require(stored.payload), for: SyncRecordHeader(stored.wire, collection: .snippet))
        #expect(try JSONDecoder().decode(SnippetTestHandler.Payload.self, from: opened).body == "v2")
    }

    @Test func filteredRecordsAreAcknowledgedWithoutAPush() async throws {
        let handler = NoteTestHandler(filtered: ["secret"])
        let a = try peer(handlers: [handler])
        try NoteTestHandler.createTable(in: a.database)
        try NoteTestHandler.set("secret", "hunter2", in: a.database)
        try NoteTestHandler.set("public", "hello", in: a.database)

        let report = try await a.engine.runCycle()
        #expect(report.sent == 1)
        #expect(try a.pendingCount == 0)
        #expect(server.records.count == 1)
    }

    @Test func aPushThatLosesItsResponseIsRepeatedSafely() async throws {
        let a = try peer(), b = try peer()
        _ = try a.snippets.save(Snippet(name: "Greeting", body: "hello"))
        a.transport.loseNextPushResponse()

        await #expect(throws: SyncEngineError.unreachable) { try await a.engine.runCycle() }
        #expect(try a.pendingCount == 1)         // the server took it, but A doesn't know
        #expect(server.records.count == 1)

        try await a.engine.runCycle()            // pushes again
        #expect(try a.pendingCount == 0)
        try await b.engine.runCycle()
        #expect(try b.snippetBodies() == ["Greeting": "hello"])
        #expect(server.records.count == 1)
        // A's own record comes back with its own device and timestamp: not newer, not applied.
        let report = try await a.engine.runCycle()
        #expect(report.applied == 0)
    }

    @Test func pushOnlyDoesNotPull() async throws {
        let a = try peer(), b = try peer()
        _ = try b.snippets.save(Snippet(name: "From B", body: "b"))
        try await b.engine.runCycle()
        _ = try a.snippets.save(Snippet(name: "From A", body: "a"))

        let report = try await a.engine.runCycle(.pushOnly)
        #expect(report.sent == 1 && report.pulled == 0)
        #expect(try a.snippetBodies() == ["From A": "a"])
        #expect(a.transport.count("changes") == 0)
    }

    // MARK: Paging, crashes

    @Test func manyRecordsPageThroughAndANetworkErrorKeepsTheProgress() async throws {
        let a = try peer(), b = try peer()
        try await a.database.writer.write { db in
            for n in 0..<450 {
                try db.execute(
                    sql: "INSERT INTO snippet (name, body, tags, createdAt, updatedAt) VALUES (?, 'x', '[]', ?, ?)",
                    arguments: ["Snippet \(n)", Date.now, Date.now])
            }
        }
        let uploaded = try await a.engine.runCycle()
        #expect(uploaded.sent == 450)
        #expect(server.records.count == 450)

        // The connection drops on the third page: two pages (400 records) are kept.
        b.transport.fail("changes", onCall: 3, with: SyncTransportError.unreachable)
        await #expect(throws: SyncEngineError.unreachable) { try await b.engine.runCycle() }
        #expect(try b.snippetBodies().count == 400)
        #expect(try b.database.syncState().cursor == 400)
        #expect(try b.pendingCount == 0)

        let rest = try await b.engine.runCycle()
        #expect(rest.pulled == 50 && rest.applied == 50)
        #expect(try b.snippetBodies().count == 450)
        #expect(try b.pendingCount == 0)
    }

    @Test func aFailedCycleChangesNothingLocal() async throws {
        let a = try peer()
        _ = try a.snippets.save(Snippet(name: "Greeting", body: "hello"))
        let before = try a.rows("snippet")
        a.transport.failAlways("health", with: SyncTransportError.unreachable)

        await #expect(throws: SyncEngineError.unreachable) { try await a.engine.runCycle() }
        #expect(try a.rows("snippet") == before)
        #expect(try a.snippetBodies() == ["Greeting": "hello"])
        #expect(try a.database.syncState().lastSuccess == nil)
        #expect(a.transport.count("changes") == 0)
    }

    @Test func aWrongTokenStopsTheCycleAtTheFirstRequest() async throws {
        let a = try SyncPeer(server: server, key: key, token: "wrong")
        _ = try a.snippets.save(Snippet(name: "Greeting", body: "hello"))
        await #expect(throws: SyncEngineError.unauthorized) { try await a.engine.runCycle() }
        #expect(try a.pendingCount == 1)
        #expect(server.records.isEmpty)
    }

    @Test func serverErrorsAreReported() async throws {
        let a = try peer()
        a.transport.failAlways("changes", with: SyncTransportError.server(status: 503))
        await #expect(throws: SyncEngineError.server(status: 503)) { try await a.engine.runCycle() }
        a.transport.failAlways("changes", with: SyncTransportError.malformedResponse)
        await #expect(throws: SyncEngineError.badResponse) { try await a.engine.runCycle() }
    }

    // MARK: Epoch

    @Test func aNewServerDatabaseMakesBothMacsUploadEverythingAgain() async throws {
        let a = try peer(), b = try peer()
        _ = try a.snippets.save(Snippet(name: "From A", body: "a"))
        _ = try b.snippets.save(Snippet(name: "From B", body: "b"))
        try await a.engine.publishKeyCheck()
        try await a.engine.runCycle()
        try await b.engine.runCycle()
        try await a.engine.runCycle()
        let oldEpoch = server.epoch
        #expect(server.records.count == 3)   // two snippets and the key check

        server.wipe()
        #expect(server.epoch != oldEpoch)
        let report = try await a.engine.runCycle()
        #expect(report.epochReset)
        #expect(try a.database.syncState().epoch == server.epoch)
        #expect(server.records.count == 3)   // A holds both snippets, and publishes the key check

        let second = try await b.engine.runCycle()
        #expect(second.epochReset)
        #expect(server.records.count == 3)   // the same records again, not duplicates
        try await a.engine.runCycle()
        #expect(try a.snippetBodies() == ["From A": "a", "From B": "b"])
        #expect(try b.snippetBodies() == ["From A": "a", "From B": "b"])
        #expect(try a.pendingCount == 0 && b.pendingCount == 0)
        #expect(try await b.engine.verifyKey() == .matches)
    }

    @Test func tombstonesAreUploadedAgainSoDeletedDataStaysDeleted() async throws {
        let a = try peer(), b = try peer()
        _ = try a.snippets.save(Snippet(name: "Gone", body: "x"))
        try await a.engine.runCycle()
        try await b.engine.runCycle()
        try await tick()
        try a.snippets.delete(id: try #require(try await a.snippets.all().first?.id))
        try await a.engine.runCycle()   // B still holds the snippet

        server.wipe()
        try await a.engine.runCycle()   // the tombstone is uploaded again
        try await b.engine.runCycle()   // and deletes B's copy, which doesn't come back
        #expect(try b.snippetBodies().isEmpty)
        #expect(try a.snippetBodies().isEmpty)
        #expect(server.records.filter { $0.collection == "snippet" }.allSatisfy { $0.deleted })
    }

    @Test func aRestoredBackupRotatesTheEpochDuringThePull() async throws {
        let a = try peer()
        _ = try a.snippets.save(Snippet(name: "First", body: "1"))
        try await a.engine.runCycle()
        let backup = server.snapshot()
        _ = try a.snippets.save(Snippet(name: "Second", body: "2"))
        try await a.engine.runCycle()
        try await a.engine.runCycle()   // pulls its own record: the cursor is now past the backup
        #expect(try a.database.syncState().cursor == 2)

        // The server comes back from the backup: same epoch, but A's cursor is ahead of it.
        server.restore(backup)
        let report = try await a.engine.runCycle()
        #expect(report.epochReset)
        #expect(try a.database.syncState().epoch == server.epoch)
        #expect(server.records.count == 3)   // both snippets, and the key check the reset queues
        #expect(try a.pendingCount == 0)
    }

    @Test func anEpochThatKeepsChangingEndsTheCycle() async throws {
        let a = try peer()
        _ = try a.snippets.save(Snippet(name: "Greeting", body: "hello"))
        a.transport.onCall("changes") { [server] in server.rotateEpoch() }

        await #expect(throws: SyncEngineError.unstableServer) { try await a.engine.runCycle() }
        #expect(a.transport.count("changes") == SyncEngine.maxEpochRestarts + 1)
        #expect(try a.snippetBodies() == ["Greeting": "hello"])
    }

    // MARK: Keys and versions

    @Test func aWrongKeyStopsThePullWithoutTouchingAnything() async throws {
        let a = try peer(), b = try peer(key: .generate())
        _ = try a.snippets.save(Snippet(name: "Greeting", body: "hello"))
        try await a.engine.runCycle()

        // However often: no record has opened with this key, so it is the wrong key, not junk.
        for _ in 0...SyncEngine.maxUnopenedCycles {
            await #expect(throws: SyncEngineError.keyMismatch) { try await b.engine.runCycle() }
        }
        #expect(try b.snippetBodies().isEmpty)
        #expect(try b.database.syncState().cursor == 0)
        #expect(try b.database.syncState().confirmedKey == nil)
    }

    @Test func theKeyCheckTellsTheKeyApart() async throws {
        let a = try peer(), wrong = try peer(key: .generate()), right = try peer()
        #expect(try await right.engine.verifyKey() == .notFound)

        try await a.engine.publishKeyCheck()
        try await a.engine.runCycle()
        #expect(try await right.engine.verifyKey() == .matches)
        #expect(try await wrong.engine.verifyKey() == .mismatch)
        // Verifying changes nothing.
        #expect(try wrong.database.syncState().cursor == 0 && wrong.database.syncState().epoch == nil)

        await #expect(throws: SyncEngineError.keyMismatch) { try await wrong.engine.runCycle() }
        try await right.engine.runCycle()
    }

    @Test func aNewerPayloadVersionStopsThePullAndKeepsTheCursor() async throws {
        var newer = SnippetTestHandler()
        newer.supportedVersion = 2
        newer.writtenVersion = 2
        let a = try peer(handlers: [newer]), b = try peer()
        _ = try a.snippets.save(Snippet(name: "Greeting", body: "hello"))
        try await a.engine.runCycle()

        await #expect(throws: SyncEngineError.updateRequired) { try await b.engine.runCycle() }
        #expect(try b.snippetBodies().isEmpty)
        #expect(try b.database.syncState().cursor == 0)

        // Once it is updated, the same record applies.
        var updated = SnippetTestHandler()
        updated.supportedVersion = 2
        let b2 = SyncPeer(
            database: b.database, transport: b.transport, key: key, handlers: [updated])
        try await b2.engine.runCycle()
        #expect(try b2.snippetBodies() == ["Greeting": "hello"])
    }

    @Test func aRecordThatFailsToApplyIsSkippedAndTheRestApplies() async throws {
        let a = try peer()
        var poisoned = SnippetTestHandler()
        poisoned.poisonName = "Poison"
        let b = try peer(handlers: [poisoned])
        for name in ["A", "Poison", "Z"] {
            _ = try a.snippets.save(Snippet(name: name, body: name))
        }
        try await a.engine.runCycle()

        let report = try await b.engine.runCycle()
        #expect(report.pulled == 3 && report.applied == 2 && report.skipped == 1)
        #expect(try b.snippetBodies() == ["A": "A", "Z": "Z"])
        #expect(try b.database.syncState().cursor == 3)
    }

    @Test func recordsWithoutAHandlerAndOfUnknownCollectionsAreSkipped() async throws {
        let a = try peer(handlers: [SnippetTestHandler(), NoteTestHandler()])
        try NoteTestHandler.createTable(in: a.database)
        _ = try a.snippets.save(Snippet(name: "Greeting", body: "hello"))
        try NoteTestHandler.set("n", "note", in: a.database)
        try await a.engine.runCycle()
        #expect(server.records.count == 2)

        let b = try peer()   // snippets only
        let report = try await b.engine.runCycle()
        #expect(report.pulled == 2 && report.applied == 1)
        #expect(try b.database.syncState().cursor == 2)
    }

    @Test func aCollectionThatGetsAHandlerPullsWhatWasPassedOver() async throws {
        // An older build without the collection, or its module switched off.
        let a = try peer(handlers: [SnippetTestHandler(), NoteTestHandler()])
        try NoteTestHandler.createTable(in: a.database)
        _ = try a.snippets.save(Snippet(name: "Greeting", body: "hello"))
        try NoteTestHandler.set("n", "note", in: a.database)
        try await a.engine.runCycle()
        let b = try peer()
        try await b.engine.runCycle()
        #expect(try b.database.syncState().collections == [.snippet])

        try NoteTestHandler.createTable(in: b.database)
        let updated = SyncPeer(
            database: b.database, transport: b.transport, key: key, handlers: [SnippetTestHandler(), NoteTestHandler()])
        let report = try await updated.engine.runCycle()
        #expect(report.pulled == 2 && report.applied == 1)
        #expect(try NoteTestHandler.text("n", in: b.database) == "note")
        #expect(try b.snippetBodies() == ["Greeting": "hello"])
        let state = try b.database.syncState()
        #expect(state.cursor == 2 && state.collections == [.snippet, .action])

        // Covered now: the next cycle starts where this one ended.
        #expect(try await updated.engine.runCycle().pulled == 0)
    }

    @Test func aCollectionSwitchedOffAndOnAgainPullsWhatArrivedMeanwhile() async throws {
        let a = try peer(handlers: [NoteTestHandler()])
        let both: [any SyncEntityHandler] = [SnippetTestHandler(), NoteTestHandler()]
        let b = try peer(handlers: both)
        try NoteTestHandler.createTable(in: a.database)
        try NoteTestHandler.createTable(in: b.database)
        try NoteTestHandler.set("first", "1", in: a.database)
        try await a.engine.runCycle()
        try await b.engine.runCycle()

        let off = SyncPeer(database: b.database, transport: b.transport, key: key)
        try await off.engine.runCycle()
        try NoteTestHandler.set("second", "2", in: a.database)
        try await a.engine.runCycle()
        try await off.engine.runCycle()
        #expect(try NoteTestHandler.text("second", in: b.database) == nil)

        let on = SyncPeer(database: b.database, transport: b.transport, key: key, handlers: both)
        let report = try await on.engine.runCycle()
        #expect(report.applied == 1)
        #expect(try NoteTestHandler.text("second", in: b.database) == "2")
    }

    @Test func aStateWithoutRecordedCollectionsPullsOnceFromTheStart() async throws {
        // A database from before the collections were recorded.
        let a = try peer(), b = try peer()
        _ = try a.snippets.save(Snippet(name: "Greeting", body: "hello"))
        try await a.engine.runCycle()
        try await b.engine.runCycle()
        try await b.database.writer.write { db in
            try db.execute(sql: "DELETE FROM metadata WHERE key = 'syncCollections'")
        }
        #expect(try b.database.syncState().collections == nil)

        #expect(try await b.engine.runCycle().pulled == 1)
        #expect(try b.database.syncState().collections == [.snippet])
        #expect(try await b.engine.runCycle().pulled == 0)
    }

    @Test func aRecordTheHandlerIgnoresLeavesNoBookkeeping() async throws {
        let a = try peer(handlers: [NoteTestHandler()])
        let b = try peer(handlers: [NoteTestHandler(ignoredKey: "skipped")])
        try NoteTestHandler.createTable(in: a.database)
        try NoteTestHandler.createTable(in: b.database)
        try NoteTestHandler.set("skipped", "a", in: a.database)
        try NoteTestHandler.set("kept", "b", in: a.database)
        try await a.engine.runCycle()

        let report = try await b.engine.runCycle()
        #expect(report.pulled == 2 && report.applied == 1)
        #expect(try b.rows("action").map(\.localKey) == ["kept"])
        #expect(try NoteTestHandler.text("skipped", in: b.database) == nil)
    }

    @Test func aPayloadMovedToAnotherRecordIsNotApplied() async throws {
        let a = try peer(), b = try peer()
        _ = try a.snippets.save(Snippet(name: "Greeting", body: "hello"))
        try await a.engine.runCycle()
        let stored = try #require(server.records.first)

        // The server (or a bug) puts the sealed payload on another record ID.
        let otherID = String(repeating: "ab", count: 16)
        _ = try await InMemoryServerProtocol.api(for: server).push(device: "mac-x", records: [SyncWireRecord(
            collection: .snippet, id: otherID, modifiedAt: Int64(stored.modifiedAt), device: "mac-x", deleted: false,
            payload: stored.payload)])
        await #expect(throws: SyncEngineError.keyMismatch) { try await b.engine.runCycle() }
        #expect(try b.snippetBodies().isEmpty)
    }

    // MARK: Authenticity

    /// Pushes records the way someone who holds only the token can.
    func pushAsIntruder(_ records: [SyncWireRecord]) async throws {
        _ = try await InMemoryServerProtocol.api(for: server).push(device: "mac-x", records: records)
    }

    @Test func aTombstoneWithoutTheKeyDeletesNothing() async throws {
        let a = try peer(), b = try peer()
        _ = try a.snippets.save(Snippet(name: "Greeting", body: "hello"))
        try await a.engine.runCycle()
        try await b.engine.runCycle()
        let stored = try #require(server.records.first)

        // A tombstone without a payload, the way v1 sent them, and newer.
        try await pushAsIntruder([SyncWireRecord(
            collection: .snippet, id: stored.id, modifiedAt: Date.now.syncMilliseconds + 1000, device: "mac-x",
            deleted: true, payload: nil)])
        let report = try await b.engine.runCycle()
        #expect(report.skipped == 1 && report.applied == 0)
        #expect(try b.snippetBodies() == ["Greeting": "hello"])
    }

    @Test func aRecordTurnedIntoATombstoneDoesNotOpen() async throws {
        let a = try peer(), b = try peer()
        _ = try a.snippets.save(Snippet(name: "Greeting", body: "hello"))
        try await a.engine.runCycle()
        try await b.engine.runCycle()
        let stored = try #require(server.records.first)

        try await pushAsIntruder([SyncWireRecord(
            collection: .snippet, id: stored.id, modifiedAt: Int64(stored.modifiedAt) + 1, device: stored.device,
            deleted: true, payload: stored.payload)])
        await #expect(throws: SyncEngineError.keyMismatch) { try await b.engine.runCycle() }
        #expect(try b.snippetBodies() == ["Greeting": "hello"])
    }

    @Test func anOldPayloadRestampedToWinIsNotApplied() async throws {
        let a = try peer(), b = try peer()
        _ = try a.snippets.save(Snippet(name: "Action", body: "old command"))
        try await a.engine.runCycle()
        let old = try #require(server.records.first)
        try await tick()
        try edit(a, "Action", to: "new command")
        try await a.engine.runCycle()
        try await b.engine.runCycle()

        // The old ciphertext (from a backup, say), served again as the newest write.
        try await pushAsIntruder([SyncWireRecord(
            collection: .snippet, id: old.id, modifiedAt: Date.now.syncMilliseconds + 1000, device: old.device,
            deleted: false, payload: old.payload)])
        for _ in 1..<SyncEngine.maxUnopenedCycles {
            await #expect(throws: SyncEngineError.keyMismatch) { try await b.engine.runCycle() }
        }
        let report = try await b.engine.runCycle()
        #expect(report.skipped == 1 && report.applied == 0)
        #expect(try b.snippetBodies() == ["Action": "new command"])
    }

    @Test func junkStopsThePullOnlyForAFewCyclesOnceTheKeyIsConfirmed() async throws {
        let a = try peer(), b = try peer()
        _ = try a.snippets.save(Snippet(name: "First", body: "1"))
        try await a.engine.runCycle()
        try await b.engine.runCycle()
        #expect(try b.database.syncState().confirmedKey == key.keyCheckID)

        try await pushAsIntruder([SyncWireRecord(
            collection: .snippet, id: String(repeating: "ab", count: 16), modifiedAt: Date.now.syncMilliseconds,
            device: "mac-x", deleted: false, payload: Data("junk".utf8))])
        // A record behind the junk, on the same page.
        _ = try a.snippets.save(Snippet(name: "Second", body: "2"))
        try await a.engine.runCycle(.pushOnly)

        for cycle in 1..<SyncEngine.maxUnopenedCycles {
            await #expect(throws: SyncEngineError.keyMismatch) { try await b.engine.runCycle() }
            #expect(try b.database.syncState().unopened.values.sorted() == [cycle])
            #expect(try b.snippetBodies() == ["First": "1"])
        }
        let report = try await b.engine.runCycle()
        #expect(report.skipped == 1 && report.applied == 1)
        #expect(try b.snippetBodies() == ["First": "1", "Second": "2"])
        #expect(try b.database.syncState().unopened.isEmpty)
        // It is behind the cursor now.
        try await b.engine.runCycle()
    }

    @Test func junkInPlaceOfTheKeyCheckIsSkippedAndTheKeyCheckPublishedAgain() async throws {
        let a = try peer(), b = try peer()
        try await a.engine.publishKeyCheck()
        _ = try a.snippets.save(Snippet(name: "Greeting", body: "hello"))
        try await a.engine.runCycle()
        try await b.engine.runCycle()

        try await pushAsIntruder([SyncWireRecord(
            collection: .meta, id: key.keyCheckID, modifiedAt: Date.now.syncMilliseconds, device: "mac-x",
            deleted: false, payload: Data("junk".utf8))])
        #expect(try await b.engine.verifyKey() == .mismatch)
        for _ in 1..<SyncEngine.maxUnopenedCycles {
            await #expect(throws: SyncEngineError.keyMismatch) { try await b.engine.runCycle() }
        }
        try await tick()
        try await b.engine.runCycle()
        // B put its own key check back, so another Mac can still join.
        #expect(try await b.engine.verifyKey() == .matches)
        try await a.engine.runCycle()
    }

    @Test func recordsSealedByProtocolV1AreSkippedUntilTheirMacUploadsThemAgain() async throws {
        let a = try peer(), b = try peer()
        _ = try a.snippets.save(Snippet(name: "Greeting", body: "hello"))
        try await a.engine.runCycle()
        // The server as a v1 build left it: the same write, sealed without its metadata.
        let stored = try #require(server.records.first)
        let plaintext = try key.open(try #require(stored.payload), for: SyncRecordHeader(stored.wire, collection: .snippet))
        server.overwrite(try SyncKeyTestV1.record(
            plaintext, key: key, collection: .snippet, id: stored.id, modifiedAt: Int64(stored.modifiedAt),
            device: stored.device))

        // Its metadata could have been changed, so it isn't applied; it doesn't stop the pull either.
        let report = try await b.engine.runCycle()
        #expect(report.skipped == 1 && report.applied == 0)
        #expect(try b.snippetBodies().isEmpty)
        #expect(try b.database.syncState().confirmedKey == key.keyCheckID)

        // A is updated: the migration sends everything again, sealed as v2,
        // under the same (modifiedAt, device), and the server replaces the v1 record.
        try await a.database.writer.write { db in try SyncSchema.migrateAuthenticated(db) }
        try await a.engine.runCycle()
        let uploaded = try #require(server.records.first)
        #expect(uploaded.modifiedAt == stored.modifiedAt && uploaded.device == stored.device)
        #expect(uploaded.seq > stored.seq)

        try await b.engine.runCycle()
        #expect(try b.snippetBodies() == ["Greeting": "hello"])
    }

    // MARK: Blobs

    @Test func largePayloadsTravelAsDeduplicatedBlobs() async throws {
        let handler = NoteTestHandler()
        let a = try peer(handlers: [handler]), b = try peer(handlers: [handler])
        try NoteTestHandler.createTable(in: a.database)
        try NoteTestHandler.createTable(in: b.database)
        let big = String(repeating: "large text ", count: 500)
        try NoteTestHandler.set("one", big, in: a.database)
        try NoteTestHandler.set("two", big, in: a.database)
        try NoteTestHandler.set("small", "small", in: a.database)

        try await a.engine.runCycle()
        #expect(server.blobIDs.count == 1)
        #expect(server.requests.filter { $0.hasPrefix("PUT") }.count == 1)

        try await b.engine.runCycle()
        #expect(try NoteTestHandler.text("one", in: b.database) == big)
        #expect(try NoteTestHandler.text("two", in: b.database) == big)
        #expect(try NoteTestHandler.text("small", in: b.database) == "small")

        // Nothing is uploaded again.
        try NoteTestHandler.set("three", big, in: a.database)
        try await a.engine.runCycle()
        #expect(server.requests.filter { $0.hasPrefix("PUT") }.count == 1)
    }

    @Test func aMissingBlobSkipsOnlyItsRecord() async throws {
        let handler = NoteTestHandler()
        let a = try peer(handlers: [handler]), b = try peer(handlers: [handler])
        try NoteTestHandler.createTable(in: a.database)
        try NoteTestHandler.createTable(in: b.database)
        try NoteTestHandler.set("big", String(repeating: "x", count: 1000), in: a.database)
        try NoteTestHandler.set("small", "small", in: a.database)
        try await a.engine.runCycle()
        server.removeAllBlobs()

        let report = try await b.engine.runCycle()
        #expect(report.skipped == 1 && report.applied == 1)
        #expect(try NoteTestHandler.text("small", in: b.database) == "small")
        #expect(try NoteTestHandler.text("big", in: b.database) == nil)
    }

    @Test func aBlobTooLargeToDownloadSkipsOnlyItsRecord() async throws {
        let handler = NoteTestHandler()
        let a = try peer(handlers: [handler]), b = try peer(handlers: [handler])
        try NoteTestHandler.createTable(in: a.database)
        try NoteTestHandler.createTable(in: b.database)
        try NoteTestHandler.set("big", String(repeating: "x", count: 1000), in: a.database)
        try NoteTestHandler.set("small", "small", in: a.database)
        try await a.engine.runCycle()
        b.transport.failAlways("blob", with: SyncTransportError.responseTooLarge)

        let report = try await b.engine.runCycle()
        #expect(report.skipped == 1 && report.applied == 1)
        #expect(try NoteTestHandler.text("small", in: b.database) == "small")
        #expect(try NoteTestHandler.text("big", in: b.database) == nil)
    }

    @Test func aBlobSealedWithAnotherKeyStopsThePull() async throws {
        let handler = NoteTestHandler()
        let a = try peer(handlers: [handler]), b = try peer(handlers: [handler])
        try NoteTestHandler.createTable(in: a.database)
        try NoteTestHandler.createTable(in: b.database)
        try NoteTestHandler.set("big", String(repeating: "x", count: 1000), in: a.database)
        try await a.engine.runCycle()
        server.corruptBlobs()

        await #expect(throws: SyncEngineError.keyMismatch) { try await b.engine.runCycle() }
        #expect(try b.database.syncState().cursor == 0)
    }

    @Test func aTooLargePushIsSplitUntilItFits() async throws {
        let small = InMemorySyncServer(maxJSONBytes: 6000)
        let handler = NoteTestHandler(inlineLimit: 100_000)
        let a = try SyncPeer(server: small, key: key, handlers: [handler])
        try NoteTestHandler.createTable(in: a.database)
        for n in 0..<12 {
            try NoteTestHandler.set("note \(n)", String(repeating: "\(n % 10)", count: 800), in: a.database)
        }
        // One note is larger than the server accepts at all.
        try NoteTestHandler.set("huge", String(repeating: "h", count: 20_000), in: a.database)

        let report = try await a.engine.runCycle()
        #expect(report.sent == 12)
        #expect(small.records.count == 12)
        #expect(try a.pendingCount == 1)   // the huge note stays pending
        #expect(a.transport.count("push") > 2)
    }

    @Test func aRecordTheServerRefusesAsInvalidIsIsolated() async throws {
        let handler = NoteTestHandler()
        let a = try peer(handlers: [handler])
        try NoteTestHandler.createTable(in: a.database)
        for n in 0..<8 { try NoteTestHandler.set("note \(n)", "\(n)", in: a.database) }
        // A row from before the cap: one past what the server takes, so it answers 422.
        try await a.database.writer.write { db in
            try db.execute(
                sql: "UPDATE syncRecord SET modifiedAt = ? WHERE localKey = 'note 3'",
                arguments: [SyncSchema.maxModifiedAt + 1])
        }

        let report = try await a.engine.runCycle()
        #expect(report.sent == 7)
        #expect(try a.pendingCount == 1)
        #expect(try a.row("action", "note 3")?.pending == true)
    }

    @Test func aBlobTheServerRefusesAsTooLargeLeavesOnlyItsRecord() async throws {
        let small = InMemorySyncServer(maxBlobBytes: 2000)
        let a = try SyncPeer(server: small, key: key, handlers: [NoteTestHandler()])
        try NoteTestHandler.createTable(in: a.database)
        try NoteTestHandler.set("huge", String(repeating: "h", count: 5000), in: a.database)
        try NoteTestHandler.set("big", String(repeating: "b", count: 1000), in: a.database)
        try NoteTestHandler.set("small", "small", in: a.database)

        let report = try await a.engine.runCycle()
        #expect(report.sent == 2)
        #expect(small.records.count == 2)
        #expect(try a.row("action", "huge")?.pending == true)
        #expect(try a.pendingCount == 1)
    }

    // MARK: Concurrency, callbacks, enabling

    @Test func cyclesDoNotOverlap() async throws {
        let a = try peer()
        for n in 0..<20 { _ = try a.snippets.save(Snippet(name: "S\(n)", body: "\(n)")) }
        async let first = a.engine.runCycle()
        async let second = a.engine.runCycle()
        let (r1, r2) = try await (first, second)
        #expect(r1.sent + r2.sent == 20)
        #expect(server.records.count == 20)
        // Each cycle ran whole: its health check came before its pushes.
        let log = server.requests
        #expect(log.filter { $0 == "GET /v1/health" }.count == 2)
        #expect(log.firstIndex(of: "GET /v1/health")! < log.firstIndex(of: "POST /v1/push")!)
        let secondHealth = log.lastIndex(of: "GET /v1/health")!
        #expect(log.lastIndex(of: "POST /v1/push")! < secondHealth)
    }

    @Test func remoteChangesAreReportedOnlyWhenSomethingWasApplied() async throws {
        let calls = LockedCounter()
        let a = try peer()
        let b = try peer(onRemoteChanges: { report in calls.add(report.applied) })
        _ = try a.snippets.save(Snippet(name: "Greeting", body: "hello"))
        try await a.engine.runCycle()

        try await b.engine.runCycle()
        #expect(calls.values == [1])
        try await b.engine.runCycle()
        #expect(calls.values == [1])

        // Also when the cycle fails after applying: the palette still has to refresh.
        _ = try a.snippets.save(Snippet(name: "Second", body: "2"))
        try await a.engine.runCycle()
        _ = try b.snippets.save(Snippet(name: "Local", body: "l"))
        b.transport.failAlways("push", with: SyncTransportError.unreachable)
        await #expect(throws: SyncEngineError.unreachable) { try await b.engine.runCycle() }
        #expect(calls.values == [1, 1])
        #expect(try b.snippetBodies().count == 3)
    }

    @Test func enablingSyncOnExistingDataUploadsAllOfIt() async throws {
        let a = try peer(), b = try peer()
        for n in 0..<5 { _ = try a.snippets.save(Snippet(name: "S\(n)", body: "\(n)")) }
        try await a.engine.runCycle()
        try await b.engine.runCycle()
        #expect(try a.pendingCount == 0)

        try a.database.markEverythingPending()
        #expect(try a.pendingCount == 5)
        let report = try await a.engine.runCycle()
        #expect(report.sent == 5)
        #expect(try a.pendingCount == 0)
    }

    @Test func pushAndPullKeepWorkingAfterSyncRecordsOfOtherEntitiesAppear() async throws {
        // Rows of an entity without a handler (actions, before Step 6) stay pending and don't spin the loop.
        let a = try peer()
        try await a.database.writer.write { db in
            try db.execute(sql: """
                INSERT INTO syncRecord (entity, localKey, modifiedAt, pending, deleted) VALUES ('action', 'a.toml', 1, 1, 0)
                """)
        }
        _ = try a.snippets.save(Snippet(name: "Greeting", body: "hello"))
        let report = try await a.engine.runCycle()
        #expect(report.sent == 1)
        #expect(try a.row("action", "a.toml")?.pending == true)
    }
}

final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [Int] = []
    func add(_ value: Int) { lock.withLock { _values.append(value) } }
    var values: [Int] { lock.withLock { _values } }
}
