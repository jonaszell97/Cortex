import Foundation
import GRDB
import Testing
@testable import CortexCore

/// The knowledge folder through the sync engine (docs/modules/KNOWLEDGE.md, "Sync
/// and backups"): two databases and two folders against one fake server.
@Suite struct KnowledgeFileSyncTests {
    let server = InMemorySyncServer()
    let key = SyncKey.generate()

    struct Peer {
        let peer: SyncPeer
        let folder: URL
        var engine: SyncEngine { peer.engine }
        var conflicts: URL { folder.appending(path: ".conflicts", directoryHint: .isDirectory) }

        func write(_ path: String, _ text: String, modified: Date = .now) throws {
            try write(path, Data(text.utf8), modified: modified)
        }

        func write(_ path: String, _ data: Data, modified: Date = .now) throws {
            let url = folder.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        }

        func read(_ path: String) -> String? {
            (try? Data(contentsOf: folder.appending(path: path))).map { String(decoding: $0, as: UTF8.self) }
        }

        func modified(_ path: String) -> Date? {
            try? folder.appending(path: path).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        }

        func remove(_ path: String) throws {
            try FileManager.default.removeItem(at: folder.appending(path: path))
        }

        func exists(_ path: String) -> Bool {
            FileManager.default.fileExists(atPath: folder.appending(path: path).path)
        }

        /// Every file below the folder, relative, hidden ones included.
        var files: [String] {
            let root = folder.standardizedFileURL.path + "/"
            let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey])
            var files: [String] = []
            while let url = enumerator?.nextObject() as? URL {
                guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
                files.append(String(url.standardizedFileURL.path.dropFirst(root.count)))
            }
            return files.sorted()
        }

        /// Paths in `.conflicts/` and their contents.
        var conflicts_: [String: String] {
            var result: [String: String] = [:]
            for path in files where path.hasPrefix(".conflicts/") {
                result[String(path.dropFirst(".conflicts/".count))] = read(path)
            }
            return result
        }

        var conflictTexts: [String] { conflicts_.values.sorted() }
    }

    func peer(folder: URL? = nil, database: AppDatabase? = nil, identity: String? = nil) throws -> Peer {
        let folder = folder ?? FileManager.default.temporaryDirectory
            .appending(path: "CortexCoreTests-knowledge-sync-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return Peer(
            peer: SyncPeer(
                database: try database ?? makeTestDatabase(), transport: HookedTransport(DirectTransport(server: server)), key: key,
                handlers: [KnowledgeFileSync(root: folder, folderIdentity: identity)]),
            folder: folder)
    }

    func ago(_ seconds: TimeInterval) -> Date { Date(timeIntervalSinceNow: -seconds) }

    // MARK: Round trips

    @Test func filesAtAnyDepthTravelWithTheirDatesAndNothingEchoesBack() async throws {
        let a = try peer(), b = try peer()
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        try a.write("inbox/notes/2026-10-22-potrace.md", "# Potrace\n", modified: date)
        try a.write("server-config/README.md", "---\nname: Server\n---\n")
        try a.write("server-config/skills/deploy/SKILL.md", "---\nname: deploy\n---\nSteps")
        try a.write("server-config/skills/deploy/compose.example.yaml", "services: {}")
        let sent = try await a.engine.runCycle()
        #expect(sent.sent == 4)

        let received = try await b.engine.runCycle()
        #expect(received.applied == 4)
        #expect(b.files == [
            "inbox/notes/2026-10-22-potrace.md", "server-config/README.md",
            "server-config/skills/deploy/SKILL.md", "server-config/skills/deploy/compose.example.yaml",
        ])
        #expect(b.read("server-config/skills/deploy/compose.example.yaml") == "services: {}")
        #expect(b.modified("inbox/notes/2026-10-22-potrace.md") == date)
        #expect(try b.peer.pendingCount == 0)

        let seqs = server.records.map(\.seq)
        try await b.engine.runCycle()
        try await a.engine.runCycle()
        #expect(server.records.map(\.seq) == seqs)
        #expect(server.records.allSatisfy { !String(decoding: $0.payload ?? Data(), as: UTF8.self).contains("Potrace") })
    }

    @Test func largeFilesTravelAsBlobs() async throws {
        let a = try peer(), b = try peer()
        let picture = Data((0..<(KnowledgeFileSync.inlineLimit + 10)).map { UInt8($0 % 251) })
        try a.write("server-config/assets/dashboard.png", picture)
        try a.write("server-config/notes/small.md", "small")
        try await a.engine.runCycle()
        #expect(server.blobIDs.count == 1)

        try await b.engine.runCycle()
        #expect(try Data(contentsOf: b.folder.appending(path: "server-config/assets/dashboard.png")) == picture)
        #expect(b.read("server-config/notes/small.md") == "small")
    }

    @Test func anEditReplacesTheFileOnTheOtherMac() async throws {
        let a = try peer(), b = try peer()
        try a.write("p/notes/a.md", "v1", modified: ago(100))
        try await a.engine.runCycle()
        try await b.engine.runCycle()

        try a.write("p/notes/a.md", "v2", modified: ago(50))
        try await a.engine.runCycle()
        try await b.engine.runCycle()
        #expect(b.read("p/notes/a.md") == "v2")
        let seqs = server.records.map(\.seq)
        try await a.engine.runCycle()
        try await b.engine.runCycle()
        #expect(server.records.map(\.seq) == seqs)
        #expect(b.conflictTexts.isEmpty)
    }

    @Test func aDeleteMovesTheFileToConflictsAndRemovesEmptiedFolders() async throws {
        let a = try peer(), b = try peer()
        try a.write("p/skills/old/SKILL.md", "precious", modified: ago(100))
        try a.write("p/notes/keep.md", "keep", modified: ago(100))
        try await a.engine.runCycle()
        try await b.engine.runCycle()

        try a.remove("p/skills/old")
        try await a.engine.runCycle()
        let report = try await b.engine.runCycle()
        #expect(report.applied == 1)
        #expect(!b.exists("p/skills/old/SKILL.md"))
        #expect(!b.exists("p/skills/old"))
        #expect(b.exists("p"))
        #expect(b.conflictTexts == ["precious"])
        #expect(b.conflicts_.keys.first?.hasPrefix("p/skills/old/SKILL-") == true)
        #expect(b.conflicts_.keys.first?.hasSuffix(".md") == true)
        #expect(try b.peer.pendingCount == 0)
        // Nothing in .conflicts/ goes back out.
        try await b.engine.runCycle()
        #expect(server.records.count == 2)
    }

    @Test func aRenameIsADeleteAndACreate() async throws {
        let a = try peer(), b = try peer()
        try a.write("inbox/notes/2026-10-22-x.md", "text", modified: ago(100))
        try await a.engine.runCycle()
        try await b.engine.runCycle()

        try FileManager.default.createDirectory(at: a.folder.appending(path: "p/notes"), withIntermediateDirectories: true)
        try FileManager.default.moveItem(
            at: a.folder.appending(path: "inbox/notes/2026-10-22-x.md"), to: a.folder.appending(path: "p/notes/x.md"))
        try await a.engine.runCycle()
        try await b.engine.runCycle()
        #expect(b.read("p/notes/x.md") == "text")
        #expect(!b.exists("inbox/notes/2026-10-22-x.md"))
        // The inbox is a project: its folder stays.
        #expect(b.exists("inbox"))
    }

    // MARK: Conflicts

    @Test func theNewerEditWinsAndTheOlderIsKept() async throws {
        let a = try peer(), b = try peer()
        try a.write("p/todos/t.md", "base", modified: ago(1000))
        try await a.engine.runCycle()
        try await b.engine.runCycle()

        try a.write("p/todos/t.md", "from A", modified: ago(500))
        try b.write("p/todos/t.md", "from B", modified: ago(100))
        try await b.engine.runCycle()
        try await a.engine.runCycle()
        try await b.engine.runCycle()

        #expect(a.read("p/todos/t.md") == "from B" && b.read("p/todos/t.md") == "from B")
        #expect(a.conflictTexts == ["from A"])
        #expect(try a.peer.pendingCount == 0 && b.peer.pendingCount == 0)
    }

    @Test func aDeleteOnACaseInsensitiveVolumeLeavesAnotherRecordsFile() async throws {
        let a = try peer()
        try a.write("p/notes/note.md", "the new one", modified: ago(100))
        try await a.engine.runCycle()
        // A tombstone for `Note.md` that this Mac had before.
        try await a.peer.database.writer.write { db in
            try db.execute(sql: """
                INSERT INTO syncRecord (entity, localKey, modifiedAt, pending, deleted, synced) VALUES ('knowledge', 'p/notes/Note.md', 1, 0, 0, 1)
                """)
        }
        let deleting = KnowledgeFileSync(root: a.folder)
        try await a.peer.database.writer.write { db in try deleting.applyDeletion(localKey: "p/notes/Note.md", in: db) }
        #expect(a.read("p/notes/note.md") == "the new one")
    }

    // MARK: What doesn't sync

    @Test func hiddenFilesAndFoldersAndOversizedFilesStayLocal() async throws {
        let a = try peer(), b = try peer()
        try a.write("p/notes/real.md", "real")
        try a.write(".gitignore", ".conflicts/")
        try a.write(".git/HEAD", "ref: refs/heads/main")
        try a.write("p/.DS_Store", "junk")
        try a.write(".conflicts/p/notes/old-1.md", "old")
        try a.write("p/.hidden/x.md", "hidden")
        let big = a.folder.appending(path: "p/assets/huge.bin")
        try FileManager.default.createDirectory(at: big.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: big.path, contents: nil)
        let handle = try FileHandle(forWritingTo: big)
        try handle.truncate(atOffset: UInt64(KnowledgeFileSync.maxFileBytes + 1))
        try handle.close()

        let report = try await a.engine.runCycle()
        #expect(report.sent == 1)
        try await b.engine.runCycle()
        #expect(b.files == ["p/notes/real.md"])

        // A file that is too large stays where it is and doesn't look deleted.
        try await a.engine.runCycle()
        #expect(a.exists("p/assets/huge.bin"))
        #expect(server.records.allSatisfy { !$0.deleted })
    }

    @Test func aMissingFolderDeletesNothing() async throws {
        let a = try peer()
        try a.write("p/notes/a.md", "a")
        try await a.engine.runCycle()
        try FileManager.default.removeItem(at: a.folder)
        try await a.engine.runCycle()
        #expect(server.records.allSatisfy { !$0.deleted })
    }

    @Test func anotherFolderIsNotTakenForDeletingEverything() async throws {
        let a = try peer(), b = try peer()
        try a.write("p/notes/a.md", "a", modified: ago(100))
        try await a.engine.runCycle()

        // The same database, pointed at a new, empty folder.
        let moved = try peer(database: a.peer.database)
        try moved.write("q/notes/b.md", "b", modified: ago(50))
        try await moved.engine.runCycle()
        #expect(server.records.allSatisfy { !$0.deleted })
        // It pulled what was synced from the old folder.
        #expect(moved.read("p/notes/a.md") == "a")
        try await b.engine.runCycle()
        #expect(b.files == ["p/notes/a.md", "q/notes/b.md"])
    }

    @Test func aFolderNamedByTheAppMayMoveWithoutStartingOver() async throws {
        let a = try peer(identity: "app-group")
        try a.write("p/notes/a.md", "a", modified: ago(100))
        try await a.engine.runCycle()
        // Its own record comes back once; after that the cursor is current.
        try await a.engine.runCycle()

        // iOS: the same container at another absolute path.
        let moved = FileManager.default.temporaryDirectory
            .appending(path: "CortexCoreTests-knowledge-sync-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.copyItem(at: a.folder, to: moved)
        let b = try peer(folder: moved, database: a.peer.database, identity: "app-group")
        let report = try await b.engine.runCycle()
        // Not reset: nothing pulled again, nothing uploaded again.
        #expect(report.sent == 0 && report.pulled == 0)
    }

    @Test func aRemotePathCannotLeaveTheFolder() async throws {
        let a = try peer()
        let bad = ["../escape.md", "/tmp/abs.md", ".hidden.md", "p/.git/config", "p//x.md", "p/../../x.md", "p/", ""]
        for path in bad {
            let payload = KnowledgeFilePayload(v: 1, path: path, modified: 0, data: Data("evil".utf8), blob: nil, size: 4)
            let id = key.recordID(.knowledge, localKey: path)
            _ = try await DirectTransport(server: server).push(device: "remote", records: [
                try .sealed(try JSONEncoder().encode(payload), key: key, collection: .knowledge, id: id, device: "remote"),
            ])
        }
        let report = try await a.engine.runCycle()
        #expect(report.skipped == bad.count && report.applied == 0)
        #expect(a.files.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: a.folder.deletingLastPathComponent().appending(path: "escape.md").path))
    }

    @Test func pathsAreChecked() {
        #expect(KnowledgeFileSync.isValidPath("inbox/notes/a.md"))
        #expect(KnowledgeFileSync.isValidPath("README.md"))
        #expect(!KnowledgeFileSync.isValidPath("a/../b.md"))
        #expect(!KnowledgeFileSync.isValidPath("a/./b.md"))
        #expect(!KnowledgeFileSync.isValidPath(".conflicts/a.md"))
        #expect(!KnowledgeFileSync.isValidPath("a\0b"))
    }
}
