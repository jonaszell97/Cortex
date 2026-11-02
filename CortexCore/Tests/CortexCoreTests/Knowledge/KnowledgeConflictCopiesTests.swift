import Foundation
import Testing
@testable import CortexCore

/// `.conflicts/` as the iPhone's Settings lists it: what sync kept, read
/// back by name, restored without losing the current file, deleted.
@Suite struct KnowledgeConflictCopiesTests {
    let folder: KnowledgeFolder
    let copies: KnowledgeConflictCopies
    let now = Date(timeIntervalSince1970: 1_792_663_920) // 2026-10-22T10:12:00Z

    init() throws {
        folder = try makeKnowledgeFolder()
        copies = KnowledgeConflictCopies(root: folder.root)
    }

    @Test func listsWhatSyncKeptNewestFirst() throws {
        let sync = KnowledgeFileSync(root: folder.root)
        #expect(sync.archive(Data("old".utf8), at: "p/notes/docker.md", now: now))
        #expect(sync.archive(Data("newer".utf8), at: "inbox/todos/2026-10-01-call-anna.md", now: now.addingTimeInterval(60)))
        #expect(sync.archive(Data("png".utf8), at: "p/assets/diagram.png", now: now.addingTimeInterval(-60)))
        try folder.write("stray", to: ".conflicts/not-from-sync.md")

        let list = copies.list()
        #expect(list.map(\.originalPath) == ["inbox/todos/2026-10-01-call-anna.md", "p/notes/docker.md", "p/assets/diagram.png"])
        #expect(list[1].kept == now)
        #expect(list[1].path.hasPrefix("p/notes/docker-20261022-101200-") && list[1].path.hasSuffix(".md"))
        #expect(try String(contentsOf: copies.url(for: list[1]), encoding: .utf8) == "old")
    }

    @Test func restoringKeepsTheCurrentVersion() throws {
        try folder.write("current", to: "p/notes/docker.md")
        #expect(KnowledgeFileSync(root: folder.root).archive(Data("kept".utf8), at: "p/notes/docker.md", now: now))
        let copy = try #require(copies.list().first)

        try copies.restore(copy, now: now.addingTimeInterval(5))
        #expect(try folder.text(at: "p/notes/docker.md") == "kept")
        let left = copies.list()
        #expect(left.count == 1 && left[0].originalPath == "p/notes/docker.md")
        #expect(try String(contentsOf: copies.url(for: left[0]), encoding: .utf8) == "current")

        try copies.delete(left[0])
        #expect(copies.list().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: folder.root.appending(path: ".conflicts/p").path(percentEncoded: false)),
                "emptied folders go too")
    }

    @Test func restoresAFileThatIsGone() throws {
        #expect(KnowledgeFileSync(root: folder.root).archive(Data("deleted elsewhere".utf8), at: "q/todos/x.md", now: now))
        try copies.restore(try #require(copies.list().first))
        #expect(try folder.text(at: "q/todos/x.md") == "deleted elsewhere")
        #expect(copies.list().isEmpty)
    }
}
