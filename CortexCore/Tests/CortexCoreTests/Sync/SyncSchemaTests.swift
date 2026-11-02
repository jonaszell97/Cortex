import Foundation
import GRDB
import Synchronization
import Testing
@testable import CortexCore

/// The `syncRecord` bookkeeping that the `v4_sync` triggers leave behind for
/// every store method (docs/SYNC.md, "Client schema").
@Suite struct SyncSchemaTests {
    struct SyncRow: Decodable, FetchableRecord, Equatable {
        var entity: String
        var localKey: String
        var modifiedAt: Int64
        var pending: Bool
        var deleted: Bool
        var device: String?
    }

    let database: AppDatabase
    let clips: ClipStore
    let snippets: SnippetStore

    init() throws {
        database = try makeTestDatabase()
        clips = ClipStore(database: database)
        snippets = SnippetStore(database: database)
    }

    func rows(_ entity: String? = nil) throws -> [SyncRow] {
        try database.reader.read { db in
            try SyncRow.fetchAll(db, sql: """
                SELECT entity, localKey, modifiedAt, pending, deleted, device FROM syncRecord
                WHERE ?1 IS NULL OR entity = ?1 ORDER BY entity, localKey
                """, arguments: [entity])
        }
    }

    func row(_ entity: String, _ localKey: String) throws -> SyncRow? {
        try rows(entity).first { $0.localKey == localKey }
    }

    /// What a successful push does.
    func acknowledgeAll() throws {
        try database.writer.write { db in try db.execute(sql: "UPDATE syncRecord SET pending = 0") }
    }

    func syncID(of snippet: Snippet) throws -> String {
        try database.reader.read { db in
            try #require(try String.fetchOne(db, sql: "SELECT syncID FROM snippet WHERE id = ?", arguments: [snippet.id]))
        }
    }

    var nowMs: Int64 { Int64(Date.now.timeIntervalSince1970 * 1000) }

    @discardableResult
    func recordClip(_ text: String, at date: Date = .now, pin: Bool = false) throws -> Int64 {
        switch try clips.record(textSnapshot(text, at: date), indexSensitive: true, pin: pin) {
        case .inserted(let id), .bumped(let id): return id
        case .skipped: throw CancellationError()
        }
    }

    func hash(_ text: String) -> String { textSnapshot(text).contentHash }

    // MARK: Schema

    @Test func migrationSetsUpSync() throws {
        #expect(try database.appliedMigrations().contains("v4_sync"))
        #expect(try rows().isEmpty)
        let state = try database.syncState()
        #expect(state.deviceID.count == 32)
        #expect(state.deviceID.allSatisfy { "0123456789ABCDEF".contains($0) })
        #expect(try makeTestDatabase().syncState().deviceID != state.deviceID)
    }

    @Test func migrationBackfillsExistingData() throws {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue, upTo: "v3_snippets")
        let copied = Date(timeIntervalSince1970: 1_788_000_000.123)
        let updated = Date(timeIntervalSince1970: 1_788_100_000.456)
        try queue.write { db in
            // The columns of `v2_clips`: `ClipItem` has more now.
            let item = ClipStore.makeItem(
                from: textSnapshot("old clip", at: copied), hash: hash("old clip"), indexSensitive: true, pin: false)
            try db.execute(sql: """
                INSERT INTO clipItem (contentHash, kind, preview, plainText, searchText, isSensitive, isPinned, byteSize, createdAt, lastCopiedAt)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [item.contentHash, item.kind, item.preview, item.plainText, item.searchText,
                                 item.isSensitive, item.isPinned, item.byteSize, item.createdAt, item.lastCopiedAt])
            var snippet = Snippet(name: "Old", body: "body", createdAt: updated, updatedAt: updated)
            try snippet.insert(db)
        }
        try AppDatabase.migrator.migrate(queue)

        let (rows, syncID) = try queue.read { db in
            (try SyncRow.fetchAll(db, sql: "SELECT * FROM syncRecord ORDER BY entity"),
             try String.fetchOne(db, sql: "SELECT syncID FROM snippet"))
        }
        let snippetKey = try #require(syncID)
        #expect(snippetKey.count == 32)
        #expect(rows == [
            SyncRow(entity: "clip", localKey: hash("old clip"), modifiedAt: 1_788_000_000_123,
                    pending: true, deleted: false, device: nil),
            SyncRow(entity: "snippet", localKey: snippetKey, modifiedAt: 1_788_100_000_456,
                    pending: true, deleted: false, device: nil),
        ])
    }

    @Test func migrationRepairsModifiedAtOutOfRange() throws {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue, upTo: "v5_sync_synced")
        // What an unchecked remote Int64.max left behind, before and after a local write.
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO syncRecord (entity, localKey, modifiedAt, pending, deleted) VALUES
                  ('clip', 'max', 9223372036854775807, 0, 0),
                  ('clip', 'overflowed', 9223372036854775807 + 1, 1, 0),
                  ('clip', 'negative', -5, 0, 0),
                  ('clip', 'fine', 1788000000123, 0, 0)
                """)
        }
        try AppDatabase.migrator.migrate(queue)

        let rows = try queue.read { db in
            try SyncRow.fetchAll(db, sql: "SELECT * FROM syncRecord ORDER BY localKey")
        }
        #expect(rows.map { [$0.localKey: $0.modifiedAt] } == [
            ["fine": 1_788_000_000_123], ["max": SyncSchema.maxModifiedAt],
            ["negative": 0], ["overflowed": SyncSchema.maxModifiedAt],
        ])
    }

    @Test func localWritesStopAtTheLargestModifiedAt() throws {
        let snippet = try snippets.save(Snippet(name: "Greeting", body: "hello"))
        let key = try syncID(of: snippet)
        try database.writer.write { db in
            try db.execute(sql: "UPDATE syncRecord SET modifiedAt = ? WHERE localKey = ?", arguments: [SyncSchema.maxModifiedAt, key])
        }
        var edited = snippet
        edited.body = "hi"
        _ = try snippets.save(edited)
        #expect(try row("snippet", key)?.modifiedAt == SyncSchema.maxModifiedAt)
        try snippets.delete(id: try #require(snippet.id))
        #expect(try row("snippet", key)?.modifiedAt == SyncSchema.maxModifiedAt)
        let type = try database.reader.read { db in try String.fetchOne(db, sql: "SELECT typeof(modifiedAt) FROM syncRecord") }
        #expect(type == "integer")
    }

    // MARK: Clips

    @Test func recordingAddsAPendingRow() throws {
        let before = nowMs
        try recordClip("hello")
        let row = try #require(try row("clip", hash("hello")))
        #expect(row.pending && !row.deleted && row.device == nil)
        #expect((before - 1000)...(nowMs + 1000) ~= row.modifiedAt)
    }

    @Test func recopyMarksPendingAgain() throws {
        try recordClip("hello", at: .now.addingTimeInterval(-60))
        try acknowledgeAll()
        let first = try #require(try row("clip", hash("hello")))
        try recordClip("hello")
        let second = try #require(try row("clip", hash("hello")))
        #expect(second.pending)
        #expect(second.modifiedAt > first.modifiedAt)
    }

    @Test func importOfAnExistingClipChangesNothing() throws {
        try recordClip("hello")
        try acknowledgeAll()
        let before = try row("clip", hash("hello"))
        try clips.record(textSnapshot("hello", at: .now.addingTimeInterval(-3600)), indexSensitive: true, bumpExisting: false)
        #expect(try row("clip", hash("hello")) == before)
    }

    @Test func markUsedFires() throws {
        let id = try recordClip("hello", at: .now.addingTimeInterval(-60))
        try acknowledgeAll()
        try clips.markUsed(id: id)
        #expect(try row("clip", hash("hello"))?.pending == true)
    }

    @Test func setPinnedFiresOnlyOnChange() throws {
        let id = try recordClip("hello")
        try acknowledgeAll()
        try clips.setPinned(false, id: id)
        #expect(try row("clip", hash("hello"))?.pending == false)
        try clips.setPinned(true, id: id)
        #expect(try row("clip", hash("hello"))?.pending == true)
    }

    @Test func reindexingDoesNotFire() throws {
        try clips.record(textSnapshot("secret", sensitive: true), indexSensitive: false)
        try acknowledgeAll()
        try clips.reindexSensitive(indexSensitive: true)
        #expect(try row("clip", hash("secret"))?.pending == false)
    }

    @Test func recognizedTextDoesNotFire() throws {
        let snapshot = imageSnapshot()
        guard case .inserted(let id) = try clips.record(snapshot, indexSensitive: true) else {
            Issue.record("expected insert"); return
        }
        try acknowledgeAll()
        try clips.setRecognizedText("Invoice October", id: id, indexSensitive: true)
        #expect(try row("clip", snapshot.contentHash)?.pending == false)

        // Flagging it sensitive does: the other Mac should know.
        try clips.setRecognizedText("Invoice October", id: id, markSensitive: true, indexSensitive: true)
        #expect(try row("clip", snapshot.contentHash)?.pending == true)
    }

    @Test func explicitDeleteLeavesATombstone() throws {
        let id = try recordClip("gone")
        try recordClip("stays")
        try acknowledgeAll()
        let before = try #require(try row("clip", hash("gone")))
        #expect(try clips.delete(ids: [id]) == 1)

        let tombstone = try #require(try row("clip", hash("gone")))
        #expect(tombstone.deleted && tombstone.pending && tombstone.device == nil)
        #expect(tombstone.modifiedAt > before.modifiedAt)
        #expect(try row("clip", hash("stays"))?.pending == false)
    }

    @Test func purgeAndClearHistoryStayLocal() throws {
        let deletedID = try recordClip("deleted")
        try clips.delete(ids: [deletedID])
        try recordClip("old", at: .now.addingTimeInterval(-7200))
        try recordClip("new")
        try recordClip("pinned", at: .now.addingTimeInterval(-7200), pin: true)

        try clips.purge(policy: RetentionPolicy(maxAge: 3600, maxCount: nil))
        #expect(try rows().map(\.localKey).sorted() == [hash("deleted"), hash("new"), hash("pinned")].sorted())

        try clips.deleteAll()
        #expect(try rows().map(\.localKey).sorted() == [hash("deleted"), hash("pinned")].sorted())

        try clips.deleteAll(includingPinned: true)
        // Only the explicit delete's tombstone is left.
        #expect(try rows().map(\.localKey) == [hash("deleted")])
        #expect(try rows().allSatisfy(\.deleted))
    }

    @Test func recopyAfterDeleteResurrects() throws {
        try clips.delete(ids: [try recordClip("back")])
        try acknowledgeAll()
        let tombstone = try #require(try row("clip", hash("back")))
        try recordClip("back")
        let row = try #require(try row("clip", hash("back")))
        #expect(!row.deleted && row.pending)
        #expect(row.modifiedAt > tombstone.modifiedAt)
    }

    @Test func localWriteBeatsAnAppliedRemoteVersionFromAFastClock() throws {
        let id = try recordClip("hello")
        let ahead = nowMs + 3_600_000
        // What applying a remote write does: its timestamp and device, not pending.
        try database.writer.write { db in
            try db.execute(sql: "UPDATE syncRecord SET modifiedAt = ?, device = 'OTHER', pending = 0", arguments: [ahead])
        }
        try clips.markUsed(id: id)
        #expect(try row("clip", hash("hello")) == SyncRow(
            entity: "clip", localKey: hash("hello"), modifiedAt: ahead + 1, pending: true, deleted: false, device: nil))
    }

    // MARK: Snippets

    @Test func savingANewSnippetAssignsASyncID() throws {
        let snippet = try snippets.save(Snippet(name: "Greeting", keyword: "hi", body: "Hello"))
        let syncID = try syncID(of: snippet)
        #expect(syncID.count == 32)
        #expect(syncID.allSatisfy { "0123456789abcdef".contains($0) })
        let row = try #require(try row("snippet", syncID))
        #expect(row.pending && !row.deleted && row.device == nil)
        #expect(try syncID != self.syncID(of: snippets.save(Snippet(name: "Other", body: "x"))))
    }

    @Test func editsFireButSavingUnchangedAndUsingDoNot() throws {
        var snippet = try snippets.save(Snippet(name: "Greeting", keyword: "hi", body: "Hello"))
        let key = try syncID(of: snippet)
        try acknowledgeAll()

        // `save` always stamps updatedAt; with nothing else changed there's nothing to sync.
        snippet = try snippets.save(snippet, now: .now.addingTimeInterval(5))
        try snippets.markUsed(id: snippet.id!)
        #expect(try row("snippet", key)?.pending == false)

        for edit in [{ (s: inout Snippet) in s.body = "Hi there" },
                     { $0.name = "Hello" },
                     { $0.keyword = "hey" },
                     { $0.tags = ["greeting"] }] {
            edit(&snippet)
            let before = try #require(try row("snippet", key))
            snippet = try snippets.save(snippet)
            let after = try #require(try row("snippet", key))
            #expect(after.pending)
            #expect(after.modifiedAt > before.modifiedAt)
            try acknowledgeAll()
        }
        // The syncID survives the edits.
        #expect(try syncID(of: snippet) == key)
    }

    @Test func deletingASnippetLeavesATombstone() throws {
        let snippet = try snippets.save(Snippet(name: "Greeting", body: "Hello"))
        let key = try syncID(of: snippet)
        try acknowledgeAll()
        try snippets.delete(id: snippet.id!)
        let row = try #require(try row("snippet", key))
        #expect(row.deleted && row.pending)
    }

    @Test func raycastImport() throws {
        let incoming = [RaycastSnippet(name: "One", text: "1", keyword: "one"), RaycastSnippet(name: "Two", text: "2")]
        try snippets.apply(SnippetImportPlan(incoming: incoming, existing: []), replaceChanged: true)
        #expect(try rows("snippet").count == 2)
        #expect(try rows("snippet").allSatisfy(\.pending))
        try acknowledgeAll()

        // The same file again: nothing changes.
        let existing = try database.reader.read { db in try Snippet.fetchAll(db) }
        try snippets.apply(SnippetImportPlan(incoming: incoming, existing: existing), replaceChanged: true)
        #expect(try rows("snippet").allSatisfy { !$0.pending })

        // One changed text replaces that snippet only.
        let changed = [incoming[0], RaycastSnippet(name: "Two", text: "two")]
        try snippets.apply(SnippetImportPlan(incoming: changed, existing: existing), replaceChanged: true)
        let two = try #require(existing.first { $0.name == "Two" })
        #expect(try rows("snippet").filter(\.pending).map(\.localKey) == [try syncID(of: two)])
    }

    #if os(macOS)
    @Test func pastebotImport() throws {
        let importer = PastebotImporter(directory: FileManager.default.temporaryDirectory)
        let pasteboards = [
            PastebotImporter.Pasteboard(name: "History", isHistory: true, snapshots: [
                textSnapshot("one", at: .now.addingTimeInterval(-20)), textSnapshot("two", at: .now.addingTimeInterval(-10)),
            ]),
            PastebotImporter.Pasteboard(name: "Saved", isHistory: false, snapshots: [textSnapshot("saved")]),
        ]
        try importer.importAll(pasteboards, into: clips, indexSensitive: true)
        #expect(try rows("clip").map(\.localKey).sorted() == [hash("one"), hash("two"), hash("saved")].sorted())
        #expect(try rows("clip").allSatisfy(\.pending))
        try acknowledgeAll()

        // A second import finds everything present, pinned items included.
        try importer.importAll(pasteboards, into: clips, indexSensitive: true)
        #expect(try rows("clip").allSatisfy { !$0.pending })
    }
    #endif

    // MARK: Sync state

    @Test func syncStateRoundTrip() throws {
        let fresh = try database.syncState()
        #expect(fresh.cursor == 0 && fresh.epoch == nil && fresh.lastSuccess == nil)

        let success = Date(timeIntervalSince1970: 1_792_483_200.123)
        try database.updateSyncState { state in
            state.cursor = 42
            state.epoch = "44d732b453da41bf1e7e4e12ed4b370c"
            state.lastSuccess = success
        }
        let stored = try database.syncState()
        #expect(stored.deviceID == fresh.deviceID)
        #expect(stored.cursor == 42)
        #expect(stored.epoch == "44d732b453da41bf1e7e4e12ed4b370c")
        #expect(abs(try #require(stored.lastSuccess).timeIntervalSince(success)) < 0.001)

        try database.updateSyncState { $0.epoch = nil }
        #expect(try database.syncState().epoch == nil)
        #expect(try database.metadata("syncEpoch") == nil)
    }

    @Test func failedSyncStateUpdateChangesNothing() throws {
        try database.updateSyncState { $0.cursor = 7 }
        #expect(throws: CancellationError.self) {
            try database.updateSyncState { state in
                state.cursor = 99
                throw CancellationError()
            }
        }
        #expect(try database.syncState().cursor == 7)
    }

    @Test func cursorMovesWithTheTransaction() throws {
        // The engine advances the cursor in the same transaction as the page it applied.
        #expect(throws: CancellationError.self) {
            try database.writer.write { db in
                var state = try SyncState.read(db)
                state.cursor = 200
                try state.write(db)
                throw CancellationError()
            }
        }
        #expect(try database.syncState().cursor == 0)
    }

    @Test func restartingSyncForOneEntityRequeuesItAndRewindsTheCursor() throws {
        let database = try makeTestDatabase()
        let store = ClipStore(database: database)
        try store.record(textSnapshot("clip"), indexSensitive: false)
        _ = try SnippetStore(database: database).save(Snippet(name: "Snippet", body: "body"))
        try database.writer.write { db in
            try db.execute(sql: "UPDATE syncRecord SET pending = 0")
        }
        try database.updateSyncState { $0.cursor = 42; $0.epoch = "e" }

        try database.restartSync(for: .clip)

        let pending = try database.reader.read { db in
            try String.fetchAll(db, sql: "SELECT entity FROM syncRecord WHERE pending = 1")
        }
        #expect(pending == ["clip"])
        let state = try database.syncState()
        #expect(state.cursor == 0 && state.epoch == "e")

        try database.resetSyncProgress()
        let reset = try database.syncState()
        #expect(reset.cursor == 0 && reset.epoch == nil && reset.lastSuccess == nil)
    }

    @Test func theObservationReportsTheNumberOfPendingRows() async throws {
        let database = try makeTestDatabase()
        let counts = Mutex<[Int]>([])
        let observation = database.observePendingSyncRecords { count in counts.withLock { $0.append(count) } }
        defer { observation.cancel() }

        try ClipStore(database: database).record(textSnapshot("one"), indexSensitive: false)
        try ClipStore(database: database).record(textSnapshot("two"), indexSensitive: false)
        try await database.writer.write { db in try db.execute(sql: "UPDATE syncRecord SET pending = 0") }

        for _ in 0..<100 where counts.withLock({ $0.last }) != 0 {
            try await Task.sleep(for: .milliseconds(20))
        }
        let seen = counts.withLock { $0 }
        #expect(seen.last == 0)
        #expect(seen.contains(2) || seen.contains(1))
        #expect(seen == seen.enumerated().filter { $0.offset == 0 || seen[$0.offset - 1] != $0.element }.map(\.element))
    }
}
