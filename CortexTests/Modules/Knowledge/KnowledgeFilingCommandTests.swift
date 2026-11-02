import Foundation
import Testing
@testable import Cortex
import CortexCore

/// Records what a filing command sends and answers with canned JSON.
final class FilingVendor: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [AIRequest] = []
    let answer: String

    init(_ answer: String) {
        self.answer = answer
    }

    var sent: [AIRequest] { lock.withLock { requests } }

    var send: @Sendable (AIRequest) async throws -> AIResponse {
        { [self] request in
            lock.withLock { requests.append(request) }
            return AIResponse(content: .text(answer), usage: AIUsage(vendor: .openAI, model: request.model, inputTokens: 1, outputTokens: 1))
        }
    }
}

/// `$note`, `$todo` and `$tidy`: what they send, what the palette shows
/// and what ⏎ there writes.
@MainActor
@Suite struct KnowledgeFilingCommandTests {
    let suiteName = "CortexTests-\(UUID().uuidString)"
    let root: URL
    let store: UserDefaults
    let palette = FakePaletteHost()

    init() {
        let base = FileManager.default.temporaryDirectory.appending(path: "CortexFiling-\(UUID().uuidString)", directoryHint: .isDirectory)
        root = base.appending(path: "knowledge", directoryHint: .isDirectory)
        store = UserDefaults(suiteName: suiteName)!
        store.set(root.path(percentEncoded: false), forKey: "knowledge.folder")
        store.set(false, forKey: "knowledge.keepHistory")
        store.set(false, forKey: "knowledge.linkSkills")
    }

    func makeService() async throws -> KnowledgeService {
        let service = KnowledgeService(settings: KnowledgeSettings(defaults: ModuleDefaults(id: "knowledge", store: store)))
        try service.folder.createProject(id: "server-config", name: "Server config", summary: "The home server")
        await service.start()
        return service
    }

    func tearDown(_ service: KnowledgeService) {
        service.stop()
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
    }

    func command(_ kind: KnowledgeFilingCommand.Kind, _ vendor: FilingVendor, service: KnowledgeService, reviewed: Reviewed) -> KnowledgeFilingCommand {
        KnowledgeFilingCommand(kind: kind, vendor: .openAI, model: "gpt-test", index: service.index, send: vendor.send) { content in
            reviewed.contents.append(content)
        }
    }

    @MainActor final class Reviewed {
        var contents: [KnowledgeReviewContent] = []
    }

    func run(_ command: KnowledgeFilingCommand, _ input: ActionInput) async throws -> ActionOutput {
        let context = try ActionContext.make(fallbackOutputDirectory: FileManager.default.temporaryDirectory)
        defer { context.removeTemporaryDirectory() }
        return try await CommandAction(command).run(input, context: context)
    }

    func presenter(_ service: KnowledgeService, notes: Notes = Notes()) -> KnowledgeReviewPresenter {
        KnowledgeReviewPresenter(service: service, moduleID: "knowledge", palette: { [palette] in palette }) { title, body in
            notes.posted.append("\(title): \(body)")
        }
    }

    @MainActor final class Notes {
        var posted: [String] = []
    }

    // MARK: $note and $todo

    @Test func noteSendsTheTextWithTheProjectsAndShowsTheProposal() async throws {
        let service = try await makeService()
        defer { tearDown(service) }
        let vendor = FilingVendor("""
            {"kind": "note", "project": "server-config", "title": "Copy a Docker volume", "tags": ["docker"],
             "body": "Use alpine.", "description": null}
            """)
        let reviewed = Reviewed()
        let note = command(.note, vendor, service: service, reviewed: reviewed)
        #expect(note.name == "note" && note.isRemote)
        #expect(note.argument?.kind == .prompt)

        let output = try await run(note, .text("copy a docker volume with alpine"))
        #expect(output == .handled)
        guard case .json(let model, let instructions, let input, let schema) = try #require(vendor.sent.first) else {
            Issue.record("not a JSON request")
            return
        }
        #expect(model == "gpt-test")
        #expect(input == "copy a docker volume with alpine")
        #expect(instructions.contains("- server-config: Server config — The home server"))
        #expect(schema.name == "knowledge_note")
        #expect(reviewed.contents == [.proposal(KnowledgeFiling.Proposal(
            kind: .note, project: "server-config", title: "Copy a Docker volume", tags: ["docker"], body: "Use alpine."))])
        // Nothing is written before the palette's ⏎.
        #expect(!service.folder.exists("server-config/notes/copy-a-docker-volume.md"))
    }

    @Test func resolvingSendsNothing() async throws {
        let service = try await makeService()
        defer { tearDown(service) }
        let vendor = FilingVendor("{}")
        let reviewed = Reviewed()
        for (kind, input) in [(KnowledgeFilingCommand.Kind.note, ActionInput.text("a note")), (.todo, .text("a to-do")), (.tidy, .none)] {
            let outcome = try await command(kind, vendor, service: service, reviewed: reviewed).resolve(input)
            guard case .job(let plan, _) = outcome else {
                Issue.record("\(kind): expected a job, got \(outcome)")
                continue
            }
            #expect(plan.hasPrefix("Sends the ") && plan.contains("OpenAI (gpt-test)"), "\(kind)")
        }
        #expect(vendor.sent.isEmpty, "the vendor hears nothing until ⏎")
        #expect(reviewed.contents.isEmpty)
    }

    @Test func theProposalOverlayChangesTheProjectAndSavesOnReturn() async throws {
        let service = try await makeService()
        defer { tearDown(service) }
        let proposal = KnowledgeFiling.Proposal(kind: .todo, project: "server-config", title: "Rotate the key", checklist: ["log in"])
        palette.isVisible = false
        presenter(service).present(.proposal(proposal))
        #expect(palette.opened == ["knowledge"])
        let overlay = try #require(palette.overlays.last)
        #expect(overlay.escape == .closePalette)
        #expect(overlay.activationHints.map(\.label) == ["Add"])

        // ⇥ goes round the projects: the inbox first, then by name.
        let tab = try #require(overlay.keys.first { $0.combo == .tab }?.perform)
        #expect(tab())
        #expect(tab())
        overlay.activate(.primary)
        #expect(palette.closes == 1)
        for _ in 0..<50 where !service.folder.exists("server-config/todos/rotate-the-key.md") {
            try await Task.sleep(for: .milliseconds(20))
        }
        let item = try #require(try service.folder.item(at: "server-config/todos/rotate-the-key.md"))
        #expect(TodoChecklist(body: item.body).items.map(\.text) == ["log in"])
    }

    @Test func projectsGoRoundInboxFirst() {
        let review = ProposalReview(
            KnowledgeFiling.Proposal(kind: .note, project: "inbox", title: "x"),
            projects: [KnowledgeProject(id: "zeta", name: "Zeta"), KnowledgeProject(id: "inbox"), KnowledgeProject(id: "alpha", name: "Alpha")])
        #expect(review.projects.map(\.id) == ["inbox", "alpha", "zeta"])
        review.changeProject(by: 1)
        #expect(review.proposal.project == "alpha")
        #expect(review.path == "alpha/notes/x.md")
        review.changeProject(by: -2)
        #expect(review.proposal.project == "zeta")
    }

    @Test func aTextIsRequiredAndAnUnreadableAnswerFails() async throws {
        let service = try await makeService()
        defer { tearDown(service) }
        let reviewed = Reviewed()
        let todo = command(.todo, FilingVendor("Sure, here you go"), service: service, reviewed: reviewed)
        #expect(!todo.accepts(.none))
        await #expect(throws: (any Error).self) { try await run(todo, .text("fix the backup")) }
        #expect(reviewed.contents.isEmpty)
    }

    @Test func aTypedSecretIsNotSent() async throws {
        let service = try await makeService()
        defer { tearDown(service) }
        let vendor = FilingVendor("{}")
        let note = command(.note, vendor, service: service, reviewed: Reviewed())
        await #expect(throws: QuickActionError.self) {
            try await run(note, .text("my key sk-proj-AbCdEf0123456789AbCdEf0123456789AbCdEf0123456789"))
        }
        #expect(vendor.sent.isEmpty)
    }

    // MARK: $tidy

    @Test func tidySendsTheInboxAndAppliesWhatIsNotSkipped() async throws {
        let service = try await makeService()
        defer { tearDown(service) }
        let first = try service.folder.createNote(title: "Restic notes", body: "x")
        let second = try service.folder.createTodo(title: "rotate key")
        await service.refreshNow()
        let vendor = FilingVendor("""
            {"proposals": [
              {"path": "\(first)", "action": "move", "project": "server-config", "title": "Restic notes", "tags": ["backup"],
               "merge_into": null, "reason": "server"},
              {"path": "\(second)", "action": "move", "project": "server-config", "title": "Rotate the key", "tags": [],
               "merge_into": null, "reason": "server"}
            ]}
            """)
        let reviewed = Reviewed()
        let tidy = command(.tidy, vendor, service: service, reviewed: reviewed)
        #expect(tidy.argument == nil && tidy.accepts(.none))
        #expect(try await run(tidy, .none) == .handled)
        guard case .tidy(let proposals) = try #require(reviewed.contents.first) else {
            Issue.record("no tidy proposals")
            return
        }
        #expect(proposals.count == 2)

        let notes = Notes()
        presenter(service, notes: notes).present(.tidy(proposals))
        let overlay = try #require(palette.overlays.last)
        // The inbox is listed newest first; ⇥ skips the to-do.
        let position = try #require(proposals.firstIndex { $0.item.path == second })
        #expect(overlay.move?(.vertical(position)) == true)
        #expect(overlay.keys.first { $0.combo == .tab }?.perform?() == true)
        overlay.activate(.primary)
        for _ in 0..<50 where service.folder.exists(first) {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(service.folder.exists("server-config/notes/restic-notes.md"))
        #expect(service.folder.exists(second))
        #expect(notes.posted.isEmpty)
    }

    @Test func tidyOnAnEmptyInboxSendsNothing() async throws {
        let service = try await makeService()
        defer { tearDown(service) }
        let vendor = FilingVendor("{}")
        let output = try await run(command(.tidy, vendor, service: service, reviewed: Reviewed()), .none)
        #expect(output == .done("The inbox is empty."))
        #expect(vendor.sent.isEmpty)
    }

    @Test func theTidyListDescribesEachChange() {
        let item = KnowledgeItem.parse(
            path: "inbox/notes/2026-10-22-x.md", text: "---\ntitle: x\ntags: [a]\n---\nbody", modified: .now)!
        let other = KnowledgeItem.parse(path: "inbox/notes/2026-10-22-z.md", text: "z", modified: .now)!
        let review = TidyReview(
            [
                KnowledgeFiling.TidyProposal(item: item, action: .move(project: "server-config", title: "Better", tags: ["a", "b"]), reason: "r"),
                KnowledgeFiling.TidyProposal(item: other, action: .merge(into: "p/notes/y.md", title: "Y"), reason: ""),
            ],
            projects: [KnowledgeProject(id: "server-config", name: "Server config")])
        #expect(review.describe(review.proposals[0]) == "→ Server config · “Better” · #a #b")
        #expect(review.describe(review.proposals[1]) == "Merge into “Y”")
        review.move(by: 5)
        #expect(review.selection == 1)
        review.toggleSelected()
        #expect(review.included.count == 1)
        review.toggleSelected()
        #expect(review.included.count == 2)
    }
}
