import Foundation
import Testing
@testable import CortexCore

@Suite struct KnowledgeActionsTests {
    let folder: KnowledgeFolder
    let now = Date(timeIntervalSince1970: 1_792_663_920)

    init() throws {
        folder = try makeKnowledgeFolder()
    }

    func context() throws -> ActionContext {
        try ActionContext.make(fallbackOutputDirectory: folder.root)
    }

    @Test func savesTextAsANoteInTheInbox() async throws {
        let action = KnowledgeCaptureAction(.note, folder: folder) { [now] in now }
        #expect(action.accepts(.text("x")) && !action.accepts(.text("  \n")) && !action.accepts(.none))
        let output = try await action.run(.text("\n  Potrace\nmagick in.png in.pbm\npotrace in.pbm\n"), context: try context())
        #expect(output == .done("Saved “Potrace” to the inbox"))
        let path = try #require(folder.itemFiles().keys.first)
        #expect(path.hasPrefix("inbox/notes/") && path.hasSuffix("-potrace.md"))
        let note = try #require(try folder.item(at: path))
        #expect(note.title == "Potrace" && note.body == "magick in.png in.pbm\npotrace in.pbm\n")
    }

    @Test func addsTextAsATodo() async throws {
        let action = KnowledgeCaptureAction(.todo, folder: folder) { [now] in now }
        _ = try await action.run(.text("Call Anna"), context: try context())
        let path = try #require(folder.itemFiles().keys.first)
        #expect(path.hasPrefix("inbox/todos/"))
        #expect(try folder.item(at: path)?.status == .open)
    }

    @Test func asksBeforeSavingASecret() async throws {
        let action = KnowledgeCaptureAction(.note, folder: folder)
        let output = try await action.run(.text("ghp_abcdefghijklmnopqrstuvwxyz0123456789"), context: try context())
        guard case .confirm(let confirmation) = output else {
            Issue.record("no confirmation: \(output)")
            return
        }
        #expect(folder.itemFiles().isEmpty)
        _ = try await confirmation.perform()
        #expect(folder.itemFiles().count == 1)
    }

    @Test func cutsALongFirstLine() {
        let paragraph = String(repeating: "word ", count: 30).trimmingCharacters(in: .whitespaces)
        let (title, body) = KnowledgeCaptureAction.split(paragraph)
        #expect(title.hasSuffix("…") && title.count <= 81)
        #expect(body == paragraph)
        #expect(KnowledgeCaptureAction.split("Title\n\nBody") == ("Title", "\nBody"))
    }
}
