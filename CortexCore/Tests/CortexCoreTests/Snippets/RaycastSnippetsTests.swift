import Foundation
import Testing
@testable import CortexCore

@Suite struct RaycastSnippetsTests {
    let store: SnippetStore

    init() throws {
        store = SnippetStore(database: try makeTestDatabase())
    }

    func fixture() throws -> [RaycastSnippet] {
        let url = try #require(Bundle.module.url(forResource: "raycast-snippets", withExtension: "json", subdirectory: "Fixtures"))
        return try RaycastSnippets.decode(Data(contentsOf: url))
    }

    @Test func decodesTheExport() throws {
        let snippets = try fixture()
        #expect(snippets.count == 8)
        #expect(snippets[0] == RaycastSnippet(name: "Signature", text: "Best regards\nAlex", keyword: ";sig"))
        #expect(snippets[2].keyword == nil)
    }

    @Test func rejectsOtherJSON() {
        #expect(throws: RaycastSnippetFormatError.self) {
            try RaycastSnippets.decode(Data(#"{"name": "not a list"}"#.utf8))
        }
        #expect(throws: RaycastSnippetFormatError.self) {
            try RaycastSnippets.decode(Data("not json".utf8))
        }
    }

    @Test func dryRunIntoAnEmptyDatabase() throws {
        let plan = SnippetImportPlan(incoming: try fixture(), existing: [])
        #expect(plan.entries.map(\.action) == [
            .add, .add, .add, .add,
            .duplicateInFile,
            .invalid("No name"),
            .add, .add,
        ])
        #expect(plan.entries[3].keyword == nil, "an empty keyword is no keyword")
        #expect(plan.entries[6].notes.contains { $0.contains("{selection}") })
        #expect(plan.addCount == 6)
        #expect(plan.skippedCount == 2)
    }

    @Test func dryRunFlagsOlderClipboardHistory() {
        let plan = SnippetImportPlan(incoming: [
            RaycastSnippet(name: "Current", text: "{clipboard}"),
            RaycastSnippet(name: "Older", text: "Was: {clipboard offset=1}"),
        ], existing: [])
        #expect(plan.entries[0].notes.isEmpty)
        #expect(plan.entries[1].notes.contains { $0.contains("older clipboard history") })
    }

    @Test func importsAndSkipsUnchangedOnTheSecondRun() async throws {
        let incoming = try fixture()
        let first = try store.apply(SnippetImportPlan(incoming: incoming, existing: []), replaceChanged: true)
        #expect(first == SnippetImportReport(added: 6, replaced: 0, unchanged: 0, skipped: 2))

        let imported = try await store.all()
        #expect(imported.map(\.name) == ["Address", "Empty keyword", "Meeting notes", "Quote selection", "Signature", "Taken keyword"])
        let meeting = try #require(imported.first { $0.name == "Meeting notes" })
        #expect(meeting.keyword == ";mtg")
        #expect(meeting.template.fillIns.map(\.name) == ["Attendees"])

        let second = try store.apply(SnippetImportPlan(incoming: incoming, existing: imported), replaceChanged: true)
        #expect(second == SnippetImportReport(added: 0, replaced: 0, unchanged: 6, skipped: 2))
        #expect(try await store.count() == 6)
    }

    @Test func changedSnippetsAreReplacedOrKept() async throws {
        let original = try store.save(Snippet(name: "SIGNATURE", keyword: ";sig", body: "Old text", tags: ["mine"]))
        try store.markUsed(id: original.id!)
        let incoming = [RaycastSnippet(name: "Signature", text: "New text", keyword: ";sig")]

        let plan = SnippetImportPlan(incoming: incoming, existing: try await store.all())
        #expect(plan.entries.map(\.action) == [.replace(existingID: original.id!)])

        let kept = try store.apply(plan, replaceChanged: false)
        #expect(kept.skipped == 1)
        #expect(try await store.snippet(id: original.id!)?.body == "Old text")

        let replaced = try store.apply(plan, replaceChanged: true)
        #expect(replaced.replaced == 1)
        let updated = try #require(try await store.snippet(id: original.id!))
        #expect(updated.body == "New text")
        #expect(updated.name == "SIGNATURE", "the existing name is kept")
        #expect(updated.tags == ["mine"], "tags and usage are not in the export and are kept")
        #expect(updated.usageCount == 1)
    }

    @Test func keywordTakenByAnotherSnippetIsLeftOut() async throws {
        try store.save(Snippet(name: "Existing", keyword: ";old", body: "x"))
        let plan = SnippetImportPlan(incoming: try fixture(), existing: try await store.all())
        let taken = try #require(plan.entries.first { $0.snippet.name == "Taken keyword" })
        #expect(taken.action == .add)
        #expect(taken.keyword == nil)
        #expect(!taken.notes.isEmpty)

        try store.apply(plan, replaceChanged: true)
        #expect(try await store.keywords()[";old"] != nil)
        #expect(try await store.all().first { $0.name == "Taken keyword" }?.keyword == nil)
    }

    @Test func keptSnippetKeepsItsKeywordWhenAnotherWantsIt() async throws {
        // A moves its keyword away and B takes it, but A is not replaced.
        try store.save(Snippet(name: "A", keyword: ";k", body: "old"))
        let incoming = [
            RaycastSnippet(name: "A", text: "new", keyword: ";k2"),
            RaycastSnippet(name: "B", text: "b", keyword: ";k"),
        ]
        let plan = SnippetImportPlan(incoming: incoming, existing: try await store.all())
        #expect(plan.entries[1].keyword == ";k")

        try store.apply(plan, replaceChanged: false)
        let all = try await store.all()
        #expect(all.first { $0.name == "A" }?.keyword == ";k")
        #expect(all.first { $0.name == "B" }?.keyword == nil)
    }

    @Test func exportRoundTrips() async throws {
        try store.save(Snippet(name: "b", keyword: ";b", body: "Two\nlines", tags: ["t"]))
        try store.save(Snippet(name: "A", body: "{date:yyyy-MM-dd} a/b"))
        let data = try RaycastSnippets.encode(try await store.all())
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains(#""text" : "{date:yyyy-MM-dd} a/b""#), "slashes are not escaped")
        #expect(!json.contains("tags"))

        let decoded = try RaycastSnippets.decode(data)
        #expect(decoded == [
            RaycastSnippet(name: "A", text: "{date:yyyy-MM-dd} a/b", keyword: nil),
            RaycastSnippet(name: "b", text: "Two\nlines", keyword: ";b"),
        ])
        let plan = SnippetImportPlan(incoming: decoded, existing: try await store.all())
        #expect(plan.unchangedCount == 2)
    }
}
