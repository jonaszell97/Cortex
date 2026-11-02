import Foundation
import Synchronization
import Testing
@testable import CortexCore

/// Waiting on the server for other devices' changes (docs/SYNC.md, "Waiting
/// for changes").
@Suite struct SyncChangeWaiterTests {
    /// A server whose waiting `changes` answers come from `answer`.
    final class WaitingTransport: SyncTransport, Sendable {
        let maxWait: Int?
        let answer: @Sendable (_ call: Int) async throws -> SyncChangesPage
        /// (cursor, limit, wait) of every waiting `changes`.
        let asked = Mutex<[[Int64]]>([])

        init(maxWait: Int? = 60, answer: @escaping @Sendable (_ call: Int) async throws -> SyncChangesPage) {
            self.maxWait = maxWait
            self.answer = answer
        }

        func health() async throws -> SyncHealth { SyncHealth(status: "ok", epoch: "epoch", maxWait: maxWait) }
        func changes(since cursor: Int64, limit: Int, wait: Int) async throws -> SyncChangesPage {
            let call = asked.withLock { asked in
                asked.append([cursor, Int64(limit), Int64(wait)])
                return asked.count
            }
            return try await answer(call)
        }
        func changes(since cursor: Int64, limit: Int) async throws -> SyncChangesPage {
            Issue.record("the waiter asked without waiting")
            throw SyncTransportError.malformedResponse
        }
        func push(device: String, records: [SyncWireRecord]) async throws -> SyncPushResponse { throw SyncTransportError.unreachable }
        func missingBlobs(_ ids: [String]) async throws -> SyncMissingBlobs { throw SyncTransportError.unreachable }
        func putBlob(id: String, data: Data) async throws -> SyncPutBlobResult { throw SyncTransportError.unreachable }
        func blob(id: String) async throws -> SyncBlobDownload? { throw SyncTransportError.unreachable }

        var calls: [[Int64]] { asked.withLock { $0 } }
    }

    static func page(records: Int = 0, epoch: String = "epoch") -> SyncChangesPage {
        let record = SyncWireRecord(collection: .snippet, id: String(repeating: "a", count: 32), seq: 8, modifiedAt: 1, device: "other", deleted: false, payload: Data())
        return SyncChangesPage(records: Array(repeating: record, count: records), cursor: records > 0 ? 8 : 7, more: false, epoch: epoch)
    }

    /// A database whose cursor is at 7 on the server's epoch.
    func database(epoch: String = "epoch") throws -> AppDatabase {
        let database = try makeTestDatabase()
        _ = try database.updateSyncState {
            $0.epoch = epoch
            $0.cursor = 7
        }
        return database
    }

    @Test func recordsAfterTheCursorEndTheWait() async throws {
        let transport = WaitingTransport { _ in Self.page(records: 1) }
        #expect(await SyncChangeWaiter.wait(transport: transport, database: try database()))
        #expect(transport.calls == [[7, 1, 25]])
    }

    @Test func aQuietAnswerAfterTheWaitAsksAgain() async throws {
        let transport = WaitingTransport { call in
            if call == 1 {
                try await Task.sleep(for: .milliseconds(600))
                return Self.page()
            }
            return Self.page(records: 1)
        }
        #expect(await SyncChangeWaiter.wait(transport: transport, database: try database(), seconds: 1))
        #expect(transport.calls == [[7, 1, 1], [7, 1, 1]])
    }

    @Test func theWaitIsNoLongerThanTheServerAllows() async throws {
        let transport = WaitingTransport(maxWait: 10) { _ in Self.page(records: 1) }
        #expect(await SyncChangeWaiter.wait(transport: transport, database: try database()))
        #expect(transport.calls == [[7, 1, 10]])
    }

    @Test func aServerThatCantWaitIsNotAsked() async throws {
        let transport = WaitingTransport(maxWait: nil) { _ in Self.page(records: 1) }
        #expect(!(await SyncChangeWaiter.wait(transport: transport, database: try database())))
        #expect(transport.calls.isEmpty)
    }

    @Test func aQuietAnswerAtOnceStopsTheWaiting() async throws {
        let transport = WaitingTransport { _ in Self.page() }
        #expect(!(await SyncChangeWaiter.wait(transport: transport, database: try database())))
        #expect(transport.calls.count == 1)
    }

    @Test func aNewEpochEndsTheWait() async throws {
        let transport = WaitingTransport { _ in Self.page(epoch: "new") }
        #expect(await SyncChangeWaiter.wait(transport: transport, database: try database()))
        // A cursor of another epoch needs a cycle before anything else.
        let behind = WaitingTransport { _ in Self.page() }
        #expect(await SyncChangeWaiter.wait(transport: behind, database: try database(epoch: "old")))
        #expect(behind.calls.isEmpty)
    }

    @Test func aFailureStopsTheWaiting() async throws {
        let transport = WaitingTransport { _ in throw SyncTransportError.unreachable }
        #expect(!(await SyncChangeWaiter.wait(transport: transport, database: try database())))
    }

    @Test func cancellingStopsTheWaiting() async throws {
        let transport = WaitingTransport { _ in
            try await Task.sleep(for: .seconds(30))
            return Self.page(records: 1)
        }
        let database = try database()
        let task = Task { await SyncChangeWaiter.wait(transport: transport, database: database) }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        #expect(!(await task.value))
    }
}
