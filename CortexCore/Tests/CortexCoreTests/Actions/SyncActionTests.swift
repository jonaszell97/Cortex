import Foundation
import GRDB
import Testing
@testable import CortexCore

/// Quick-action files through the sync engine (docs/SYNC.md, "Handling per data
/// type"): two databases and two actions folders against one fake server.
@Suite struct SyncActionTests {
    let server = InMemorySyncServer()
    let key = SyncKey.generate()

    struct ActionPeer {
        let peer: SyncPeer
        let folder: URL
        var engine: SyncEngine { peer.engine }
        var conflicts: URL { folder.appending(path: ".conflicts", directoryHint: .isDirectory) }

        func write(_ name: String, _ text: String, modified: Date = .now) throws {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appending(path: name)
            try Data(text.utf8).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        }

        func read(_ name: String) -> String? {
            (try? Data(contentsOf: folder.appending(path: name))).map { String(decoding: $0, as: UTF8.self) }
        }

        func remove(_ name: String) throws {
            try FileManager.default.removeItem(at: folder.appending(path: name))
        }

        /// File names in the folder, hidden ones included.
        var files: [String] {
            ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
        }

        /// The contents of every file in `.conflicts/`.
        var conflictTexts: [String] {
            ((try? FileManager.default.contentsOfDirectory(atPath: conflicts.path)) ?? []).sorted().compactMap {
                (try? Data(contentsOf: conflicts.appending(path: $0))).map { String(decoding: $0, as: UTF8.self) }
            }
        }

        var conflictNames: [String] {
            ((try? FileManager.default.contentsOfDirectory(atPath: conflicts.path)) ?? []).sorted()
        }
    }

    func peer() throws -> ActionPeer {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "CortexCoreTests-actions-\(UUID().uuidString)", directoryHint: .isDirectory)
        let database = try makeTestDatabase()
        return ActionPeer(
            peer: SyncPeer(
                database: database, transport: HookedTransport(DirectTransport(server: server)), key: key,
                handlers: [ActionFileSync(directory: folder)]),
            folder: folder)
    }

    func ago(_ seconds: TimeInterval) -> Date { Date(timeIntervalSinceNow: -seconds) }

    // MARK: Round trips

    @Test func aNewFileTravelsAndNothingEchoesBack() async throws {
        let a = try peer(), b = try peer()
        try a.write("shout.toml", "name = \"Shout\"\n")
        let sent = try await a.engine.runCycle()
        #expect(sent.sent == 1)

        let received = try await b.engine.runCycle()
        #expect(received.applied == 1)
        #expect(b.read("shout.toml") == "name = \"Shout\"\n")
        // Only the file, no temporary leftovers.
        #expect(b.files == ["shout.toml"])
        #expect(try b.peer.pendingCount == 0)

        let seqs = server.records.map(\.seq)
        try await b.engine.runCycle()
        try await a.engine.runCycle()
        #expect(server.records.map(\.seq) == seqs)
        let stored = try #require(server.records.first)
        #expect(!String(decoding: try #require(stored.payload), as: UTF8.self).contains("Shout"))
    }

    @Test func anEditReplacesTheFileOnTheOtherMac() async throws {
        let a = try peer(), b = try peer()
        try a.write("a.toml", "v1", modified: ago(100))
        try await a.engine.runCycle()
        try await b.engine.runCycle()

        try a.write("a.toml", "v2", modified: ago(50))
        try await a.engine.runCycle()
        try await b.engine.runCycle()
        #expect(b.read("a.toml") == "v2")
        // An unchanged file is not a new write.
        let seqs = server.records.map(\.seq)
        try await a.engine.runCycle()
        try await b.engine.runCycle()
        #expect(server.records.map(\.seq) == seqs)
        // Nothing needed saving: B's copy hadn't changed locally.
        #expect(b.conflictNames.isEmpty)
    }

    @Test func aDeleteMovesTheFileToConflictsOnTheOtherMac() async throws {
        let a = try peer(), b = try peer()
        try a.write("gone.toml", "precious", modified: ago(100))
        try await a.engine.runCycle()
        try await b.engine.runCycle()

        try a.remove("gone.toml")
        try await a.engine.runCycle()
        let report = try await b.engine.runCycle()
        #expect(report.applied == 1)
        #expect(b.read("gone.toml") == nil)
        #expect(b.conflictTexts == ["precious"])
        #expect(b.conflictNames.first?.hasPrefix("gone-") == true)
        #expect(try b.peer.pendingCount == 0)
        let tombstone = try #require(try b.peer.row("action", "gone.toml"))
        #expect(tombstone.deleted)
        // The deleted file coming back is a new action.
        try b.write("gone.toml", "precious")
        try await b.engine.runCycle()
        try await a.engine.runCycle()
        #expect(a.read("gone.toml") == "precious")
    }

    @Test func aFileInANewFolderCreatesTheFolder() async throws {
        let a = try peer(), b = try peer()
        try a.write("x.toml", "x")
        try await a.engine.runCycle()
        #expect(!FileManager.default.fileExists(atPath: b.folder.path))
        try await b.engine.runCycle()
        #expect(b.read("x.toml") == "x")
    }

    // MARK: Conflicts

    @Test func theNewerEditWinsAndTheOlderIsKept_theOlderSyncsFirst() async throws {
        let a = try peer(), b = try peer()
        try a.write("act.toml", "base", modified: ago(1000))
        try await a.engine.runCycle()
        try await b.engine.runCycle()

        try a.write("act.toml", "from A", modified: ago(500))
        try b.write("act.toml", "from B", modified: ago(100))   // later
        try await a.engine.runCycle()
        try await b.engine.runCycle()
        try await a.engine.runCycle()

        #expect(a.read("act.toml") == "from B" && b.read("act.toml") == "from B")
        // A's version lost; it is on B (which saw it arrive) in `.conflicts/`.
        #expect(b.conflictTexts == ["from A"])
        #expect(try a.peer.pendingCount == 0 && b.peer.pendingCount == 0)
    }

    @Test func theNewerEditWinsAndTheOlderIsKept_theNewerSyncsFirst() async throws {
        let a = try peer(), b = try peer()
        try a.write("act.toml", "base", modified: ago(1000))
        try await a.engine.runCycle()
        try await b.engine.runCycle()

        try a.write("act.toml", "from A", modified: ago(500))
        try b.write("act.toml", "from B", modified: ago(100))   // later
        try await b.engine.runCycle()
        try await a.engine.runCycle()   // A's unpushed edit loses against the newer write
        try await b.engine.runCycle()

        #expect(a.read("act.toml") == "from B" && b.read("act.toml") == "from B")
        #expect(a.conflictTexts == ["from A"])
        #expect(try a.peer.pendingCount == 0 && b.peer.pendingCount == 0)
    }

    @Test func theEditMadeLastWinsEvenIfItIsOnlyNoticedLater() async throws {
        let a = try peer(), b = try peer()
        try a.write("act.toml", "base", modified: ago(1000))
        try await a.engine.runCycle()
        try await b.engine.runCycle()

        // A's edit is older, but A syncs after B did.
        try a.write("act.toml", "old edit on A", modified: ago(500))
        try b.write("act.toml", "new edit on B", modified: ago(100))
        try await b.engine.runCycle()
        try await a.engine.runCycle()
        #expect(a.read("act.toml") == "new edit on B")
        #expect(a.conflictTexts == ["old edit on A"])
    }

    @Test func theSameLosingVersionIsKeptOnlyOnce() async throws {
        let a = try peer(), b = try peer()
        try a.write("act.toml", "base", modified: ago(1000))
        try await a.engine.runCycle()
        try await b.engine.runCycle()
        try a.write("act.toml", "from A", modified: ago(500))
        try b.write("act.toml", "from B", modified: ago(100))
        try await a.engine.runCycle()
        try await b.engine.runCycle()
        #expect(b.conflictNames.count == 1)

        // A new server epoch makes B pull everything again.
        try await b.engine.runCycle()
        try b.peer.database.updateSyncState { $0.cursor = 0 }
        try await b.engine.runCycle()
        #expect(b.conflictNames.count == 1)
    }

    @Test func aNewerRemoteWriteKeepsTheLocalFileThatWasNeverSynced() async throws {
        // The same name on both Macs before the first sync.
        let a = try peer(), b = try peer()
        try a.write("same.toml", "A's version", modified: ago(100))
        try b.write("same.toml", "B's version", modified: ago(500))
        try await a.engine.runCycle()
        try await b.engine.runCycle()
        try await a.engine.runCycle()
        #expect(a.read("same.toml") == "A's version" && b.read("same.toml") == "A's version")
        #expect(b.conflictTexts == ["B's version"])
    }

    // MARK: What doesn't sync

    @Test func onlyTopLevelTomlFilesSync() async throws {
        let a = try peer(), b = try peer()
        try a.write("real.toml", "real")
        try a.write("notes.txt", "text")
        try a.write(".hidden.toml", "hidden")
        try a.write("big.toml", String(repeating: "x", count: ActionFileSync.maxFileBytes + 1))
        try FileManager.default.createDirectory(at: a.folder.appending(path: "sub"), withIntermediateDirectories: true)
        try Data("nested".utf8).write(to: a.folder.appending(path: "sub/nested.toml"))
        try FileManager.default.createDirectory(at: a.conflicts, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: a.conflicts.appending(path: "x-1.toml"))
        try Data([0xFF, 0xFE, 0x00]).write(to: a.folder.appending(path: "binary.toml"))

        let report = try await a.engine.runCycle()
        #expect(report.sent == 1)
        try await b.engine.runCycle()
        #expect(b.files == ["real.toml"])

        // A file that is too large stays where it is and doesn't look deleted.
        try await a.engine.runCycle()
        #expect(a.read("big.toml") != nil)
        #expect(server.records.allSatisfy { !$0.deleted })
    }

    @Test func aRemoteFileNameCannotLeaveTheFolder() async throws {
        let a = try peer()
        for name in ["../escape.toml", "/tmp/abs.toml", ".hidden.toml", "sub/dir.toml", "noextension", ".toml", "a:b.toml"] {
            let payload = ActionFilePayload(v: 1, fileName: name, contents: "evil")
            let id = key.recordID(.action, localKey: name)
            _ = try await DirectTransport(server: server).push(device: "remote", records: [
                try .sealed(try JSONEncoder().encode(payload), key: key, collection: .action, id: id, device: "remote"),
            ])
        }
        let report = try await a.engine.runCycle()
        #expect(report.skipped == 7 && report.applied == 0)
        #expect(a.files.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: a.folder.deletingLastPathComponent().appending(path: "escape.toml").path))
    }

    @Test func theLoaderStillSeesOnlyTheRealActions() async throws {
        let a = try peer(), b = try peer()
        try a.write("one.toml", "name = 'One'\naccepts = 'text'\ncommand = 'sort'", modified: ago(100))
        try await a.engine.runCycle()
        try b.write("one.toml", "stale", modified: ago(5000))
        try await b.engine.runCycle()   // A's version replaces it; B's stale one lands in .conflicts/

        let contents = UserActionLibrary.load(from: b.folder)
        #expect(contents.problems.isEmpty)
        #expect(contents.actions.count == 1)
    }
}
