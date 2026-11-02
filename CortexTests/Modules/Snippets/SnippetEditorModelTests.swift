import Foundation
import Testing
@testable import Cortex
import CortexCore

@MainActor
@Suite struct SnippetEditorModelTests {
    let suiteName = "CortexTests-\(UUID().uuidString)"
    let service: SnippetsService
    let model: SnippetEditorModel

    init() throws {
        let defaults = UserDefaults(suiteName: suiteName)!
        let database = try makeTestDatabase()
        service = SnippetsService(database: database, settings: SnippetsSettings(defaults: defaults))
        model = SnippetEditorModel(service: service)
    }

    @Test func createsASnippet() async throws {
        await model.open(.new(body: "from a clip"))
        #expect(model.isNew)
        #expect(model.draft?.body == "from a clip")
        #expect(model.isDirty)

        model.draft?.name = "Clip"
        model.draft?.keyword = ";c"
        model.draft?.tags = ["work"]
        model.newTag = " , Work, mail"
        #expect(await model.save())

        #expect(!model.isNew)
        #expect(!model.isDirty)
        #expect(model.snippets.map(\.name) == ["Clip"])
        #expect(model.draft?.tags == ["work", "mail"])
        #expect(model.selectedID == model.draft?.id)
    }

    @Test func saveErrorsAreShownAndKeepTheDraft() async throws {
        try await service.save(Snippet(name: "Taken", keyword: ";t", body: "x"))
        await model.open(.new(body: nil))
        model.draft?.name = "taken"
        model.draft?.body = "y"
        #expect(await !model.save())
        #expect(model.error?.contains("Taken") == true)
        #expect(model.isNew)
        #expect(model.draft?.name == "taken")
    }

    @Test func switchingSavesTheDraftFirst() async throws {
        let a = try await service.save(Snippet(name: "A", body: "a"))
        let b = try await service.save(Snippet(name: "B", body: "b"))
        await model.open(.snippet(a.id!))
        model.draft?.body = "changed"
        await model.select(id: b.id)
        #expect(model.draft?.name == "B")
        #expect(await service.snippet(id: a.id!)?.body == "changed")
    }

    @Test func failedSaveKeepsTheSelection() async throws {
        let a = try await service.save(Snippet(name: "A", body: "a"))
        let b = try await service.save(Snippet(name: "B", body: "b"))
        await model.open(.snippet(a.id!))
        model.draft?.name = ""
        await model.select(id: b.id)
        #expect(model.selectedID == a.id)
        #expect(model.error != nil)
        model.revert()
        #expect(model.draft?.name == "A")
        #expect(!model.isDirty)
    }

    @Test func tagChipsAreAddedAndRemoved() async throws {
        let a = try await service.save(Snippet(name: "A", body: "a", tags: ["work"]))
        await model.open(.snippet(a.id!))
        model.newTag = "mail, Work"
        #expect(model.isDirty, "a typed tag counts before it becomes a chip")
        model.addNewTag()
        #expect(model.draft?.tags == ["work", "mail"])
        #expect(model.newTag.isEmpty)
        model.removeTag("mail")
        #expect(!model.isDirty)
        model.newTag = "work"
        #expect(!model.isDirty, "a tag that is already there changes nothing")
    }

    @Test func duplicatingMakesAnUnsavedCopyWithoutTheKeyword() async throws {
        let a = try await service.save(Snippet(name: "A", keyword: ";a", body: "a", tags: ["x"]))
        await model.open(.snippet(a.id!))
        await model.duplicate(id: a.id!)
        #expect(model.isNew)
        #expect(model.draft?.name == "A copy")
        #expect(model.draft?.body == "a")
        #expect(model.draft?.keyword == nil)
        #expect(model.draft?.tags == ["x"])
        #expect(await model.save())
        #expect(model.snippets.map(\.name) == ["A", "A copy"])
    }

    @Test func deletingAnotherSnippetKeepsTheSelection() async throws {
        let a = try await service.save(Snippet(name: "A", body: "a"))
        let b = try await service.save(Snippet(name: "B", body: "b"))
        await model.open(.snippet(a.id!))
        model.draft?.body = "edited"
        await model.delete(id: b.id!)
        #expect(model.snippets.map(\.name) == ["A"])
        #expect(model.selectedID == a.id)
        #expect(model.draft?.body == "edited")
    }

    @Test func deletingSelectsTheNeighbour() async throws {
        try await service.save(Snippet(name: "A", body: "a"))
        let b = try await service.save(Snippet(name: "B", body: "b"))
        try await service.save(Snippet(name: "C", body: "c"))
        await model.open(.snippet(b.id!))
        await model.deleteSelected()
        #expect(model.snippets.map(\.name) == ["A", "C"])
        #expect(model.draft?.name == "C")
    }

    @Test func previewMarksClipboardFillInsAndCursor() async {
        await model.open(.new(body: "Hi {name}, {argument name=\"x\" default=\"d\"} {clipboard} {date:yyyy}{cursor}!"))
        let preview = model.preview(now: Date(timeIntervalSince1970: 1_792_159_509))
        #expect(preview == "Hi ‹name›, ‹d› ‹clipboard› 2026▏!")
    }

    @Test func savingBumpsTheRevision() async throws {
        let before = service.revision
        try await service.save(Snippet(name: "A", body: "a"))
        #expect(service.revision == before + 1)
    }
}
