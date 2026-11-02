import Foundation
import Testing
@testable import CortexCore

@Suite struct TrelloImporterTests {
    let folder: KnowledgeFolder
    let now = Date(timeIntervalSince1970: 1_792_663_920)
    let utc = TimeZone(identifier: "UTC")!

    init() throws {
        folder = try makeKnowledgeFolder()
    }

    func board() throws -> TrelloBoard {
        let url = try #require(Bundle.module.url(forResource: "server-board", withExtension: "json", subdirectory: "Fixtures/trello"))
        return try TrelloBoard.decode(try Data(contentsOf: url))
    }

    func run() throws -> TrelloImportReport {
        try TrelloImporter(folder: folder).run(try board(), timeZone: utc, now: now)
    }

    @Test func turnsTheBoardIntoAProjectOfTodos() throws {
        let report = try run()
        #expect(report.project == "server" && report.createdProject)
        #expect(report.imported == 6 && report.done == 4)
        #expect(report.skipped.isEmpty)
        let readme = try #require(try folder.item(at: "server/README.md"))
        #expect(readme.title == "Server" && readme.summary == "The home server")

        let paths = folder.itemFiles().keys.filter { $0.contains("/todos/") }.sorted()
        #expect(paths == [
            "server/todos/fix-the-restic-backup-2.md", "server/todos/fix-the-restic-backup.md",
            "server/todos/install-tailscale.md", "server/todos/renew-the-domain.md",
            "server/todos/try-kubernetes.md", "server/todos/update-traefik.md",
        ])
    }

    @Test func writesCardsWithChecklistsLabelsAndDates() throws {
        _ = try run()
        let restic = try #require(try folder.item(at: "server/todos/fix-the-restic-backup.md"))
        #expect(restic.status == .open)
        #expect(restic.tags == ["in-progress", "urgent"])
        #expect(restic.due == "2026-10-30")
        #expect(restic.created == Date(timeIntervalSince1970: 0x6530f2a0), "from the card's ID")
        #expect(restic.updated == FrontMatter.parseDate("2026-10-20T09:30:00Z"))
        #expect(restic.frontMatter.string("trello") == "6530f2a0aaaaaaaaaaaaaaaa")
        #expect(restic.body == """
            The nightly run has been failing since the volume move.

            **Checklist**

            - [x] check the cron log
            - [ ] rotate the S3 key
            - [ ] run once by hand

            **Afterwards**

            - [ ] write it down

            - [restic log](https://trello.com/1/cards/6530f2a0/attachments/att1/download/restic.log)

            """)
        #expect(TodoChecklist(body: restic.body).items.count == 4)

        let traefik = try #require(try folder.item(at: "server/todos/update-traefik.md"))
        #expect(traefik.tags == ["to-do", "green", "docker-compose"], "a label without a name by its colour")
        #expect(traefik.body.isEmpty)
    }

    @Test func doneListsArchivedCardsAndTickedDueDatesAreDone() throws {
        _ = try run()
        let tailscale = try #require(try folder.item(at: "server/todos/install-tailscale.md"))
        #expect(tailscale.status == .done && tailscale.tags.isEmpty, "the done list is no tag")
        #expect(tailscale.frontMatter.date("done") == FrontMatter.parseDate("2026-09-15T08:00:00Z"))
        #expect(try folder.item(at: "server/todos/try-kubernetes.md")?.status == .done, "an archived card")
        #expect(try folder.item(at: "server/todos/fix-the-restic-backup-2.md")?.status == .done, "a card in an archived list")
        #expect(try folder.item(at: "server/todos/renew-the-domain.md")?.status == .done, "its due date was ticked")
    }

    @Test func importingAgainSkipsWhatIsThere() throws {
        _ = try run()
        let again = try run()
        #expect(again.project == "server" && !again.createdProject)
        #expect(again.imported == 0)
        #expect(again.skipped.count == 6, "the second card of the same name looks like the first")
    }

    @Test func refusesOtherJSON() {
        #expect(throws: QuickActionError.self) { try TrelloBoard.decode(Data("{\"cards\": 1}".utf8)) }
    }
}
