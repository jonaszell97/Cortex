import Foundation
import Testing
@testable import CortexCore

@Suite struct KnowledgeHistoryTests {
    @Test func readsPorcelainOutput() {
        let output = Data("A  inbox/notes/a.md\0M  p/notes/b.md\0D  p/todos/c.md\0R  p/notes/new.md\0p/notes/old.md\0?? untracked.md\0".utf8)
        #expect(KnowledgeHistory.changes(fromPorcelain: output) == [
            .init(.add, "inbox/notes/a.md"),
            .init(.edit, "p/notes/b.md"),
            .init(.delete, "p/todos/c.md"),
            .init(.rename(from: "p/notes/old.md"), "p/notes/new.md"),
        ])
    }

    @Test func namesWhatChanged() {
        #expect(KnowledgeHistory.message(for: [.init(.edit, "server-config/notes/docker.md")]) == "Edit server-config/notes/docker.md")
        #expect(KnowledgeHistory.message(for: [.init(.add, "a.md"), .init(.add, "b.md")]) == "Add 2 files\n\nAdd a.md\nAdd b.md")
        #expect(KnowledgeHistory.message(for: [.init(.add, "a.md"), .init(.delete, "b.md")]) == "Change 2 files\n\nAdd a.md\nDelete b.md")
    }

    @Test func commitsTheFolder() async throws {
        guard await KnowledgeHistory.isGitAvailable() else { return }
        let folder = try makeKnowledgeFolder()
        let history = KnowledgeHistory(folder: folder.root)
        try await history.prepare()
        #expect(history.isRepository)
        try await history.prepare()

        try folder.write("note", to: "inbox/notes/a.md")
        try folder.write("conflict", to: ".conflicts/inbox/notes/a.md")
        #expect(try await history.commitAll() == "Add 2 files\n\nAdd .gitignore\nAdd inbox/notes/a.md")
        #expect(try await history.commitAll() == nil, "nothing changed")

        try folder.write("changed", to: "inbox/notes/a.md")
        #expect(try await history.commitAll() == "Edit inbox/notes/a.md")
        try FileManager.default.removeItem(at: folder.url(for: "inbox/notes/a.md"))
        #expect(try await history.commitAll() == "Delete inbox/notes/a.md")
    }
}
