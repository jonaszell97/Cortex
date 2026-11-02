import Foundation
import Testing
@testable import CortexCore

/// `$note`, `$todo` and `$tidy`: the requests, reading the answers, writing
/// and applying them.
@Suite struct KnowledgeFilingTests {
    let folder: KnowledgeFolder
    let now = Date(timeIntervalSince1970: 1_792_663_920) // 2026-10-22T10:12:00Z, a Thursday
    let utc = TimeZone(identifier: "UTC")!
    let context: KnowledgeFiling.Context

    init() throws {
        folder = try makeKnowledgeFolder()
        context = KnowledgeFiling.Context(
            projects: [
                KnowledgeProject(id: "inbox"),
                KnowledgeProject(id: "server-config", name: "Server config", summary: "The home server"),
            ],
            tags: ["docker", "backup"], today: now, timeZone: utc)
    }

    // MARK: Requests

    @Test func theRequestsCarryTheRulesTheProjectsAndAStrictSchema() throws {
        let note = KnowledgeFiling.request(.note, text: "potrace needs a bitmap", context: context)
        #expect(note.input == "potrace needs a bitmap")
        #expect(note.instructions.contains(KnowledgeInstructions.filingRules))
        #expect(note.instructions.contains("- server-config: Server config — The home server"))
        #expect(note.instructions.contains("docker, backup"))
        #expect(note.schema.name == "knowledge_note")

        let todo = KnowledgeFiling.request(.todo, text: "fix backup friday", context: context)
        #expect(todo.instructions.contains("today is 2026-10-22 (Thursday)"))
        #expect(todo.ai(model: "m") == .json(model: "m", instructions: todo.instructions, input: todo.input, schema: todo.schema))

        // Strict schemas: every property is required, nothing else allowed.
        for schema in [KnowledgeFiling.noteSchema, KnowledgeFiling.todoSchema] {
            let object = try #require(try JSONSerialization.jsonObject(with: Data(schema.json.utf8)) as? [String: Any])
            let properties = try #require(object["properties"] as? [String: Any])
            #expect(Set(object["required"] as? [String] ?? []) == Set(properties.keys))
            #expect(object["additionalProperties"] as? Bool == false)
        }
        let tidy = try #require(try JSONSerialization.jsonObject(with: Data(KnowledgeFiling.tidySchema.json.utf8)) as? [String: Any])
        let items = try #require(((tidy["properties"] as? [String: Any])?["proposals"] as? [String: Any])?["items"] as? [String: Any])
        #expect(Set(items["required"] as? [String] ?? []) == Set((items["properties"] as? [String: Any] ?? [:]).keys))
    }

    // MARK: $note and $todo

    @Test func aNoteAnswerBecomesAProposalAndAFile() throws {
        let proposal = try KnowledgeFiling.proposal(.note, from: """
            {"kind": "note", "project": "server-config", "title": " Copy a Docker volume ", "tags": ["Docker", "CLI", "docker"],
             "body": "```sh\\ndocker run --rm -v a:/a alpine\\n```\\n", "description": null}
            """, text: "copy volume", context: context)
        #expect(proposal == KnowledgeFiling.Proposal(
            kind: .note, project: "server-config", title: "Copy a Docker volume", tags: ["docker", "cli"],
            body: "```sh\ndocker run --rm -v a:/a alpine\n```"))

        let path = try KnowledgeFiling.write(proposal, to: folder, now: now)
        #expect(path == "server-config/notes/copy-a-docker-volume.md")
        let item = try #require(try folder.item(at: path))
        #expect(item.tags == ["docker", "cli"])
        #expect(item.body == "```sh\ndocker run --rm -v a:/a alpine\n```\n")
    }

    @Test func anUnknownProjectIsTheInboxAndAnEmptyTitleTheFirstLine() throws {
        let proposal = try KnowledgeFiling.proposal(.note, from: """
            {"kind": "note", "project": "made-up", "title": "", "tags": [], "body": "x", "description": null}
            """, text: "First line\nsecond", context: context)
        #expect(proposal.project == "inbox")
        #expect(proposal.title == "First line")
        let path = try KnowledgeFiling.write(proposal, to: folder, now: now)
        #expect(path.hasPrefix("inbox/notes/") && path.hasSuffix("-first-line.md"))
    }

    @Test func aSkillAnswerWritesASkill() throws {
        let proposal = try KnowledgeFiling.proposal(.note, from: """
            {"kind": "skill", "project": "server-config", "title": "Deploy With Ansible", "tags": [],
             "body": "1. Push", "description": "Deploys a service with Ansible."}
            """, text: "how to deploy", context: context)
        #expect(proposal.kind == .skill)
        #expect(proposal.title == "deploy-with-ansible")
        let path = try KnowledgeFiling.write(proposal, to: folder, now: now)
        #expect(path == "server-config/skills/deploy-with-ansible/SKILL.md")
        #expect(try folder.item(at: path)?.summary == "Deploys a service with Ansible.")
    }

    @Test func aTodoAnswerWritesItsChecklistAndDueDay() throws {
        let proposal = try KnowledgeFiling.proposal(.todo, from: """
            {"project": "server-config", "title": "Fix the restic backup", "tags": ["backup"], "due": "2026-10-30",
             "checklist": ["check the cron log", " ", "rotate the S3 key"], "body": "Failing since the move."}
            """, text: "fix backup", context: context)
        #expect(proposal.checklist == ["check the cron log", "rotate the S3 key"])
        #expect(proposal.fullBody == "Failing since the move.\n\n- [ ] check the cron log\n- [ ] rotate the S3 key\n")
        let path = try KnowledgeFiling.write(proposal, to: folder, now: now)
        let item = try #require(try folder.item(at: path))
        #expect(item.kind == .todo && item.status == .open && item.due == "2026-10-30")
        #expect(TodoChecklist(body: item.body).items.map(\.text) == ["check the cron log", "rotate the S3 key"])

        for bad in ["\"Friday\"", "\"2026-02-30\"", "null"] {
            let answer = try KnowledgeFiling.proposal(.todo, from: """
                {"project": "inbox", "title": "x", "tags": [], "due": \(bad), "checklist": [], "body": ""}
                """, text: "x", context: context)
            #expect(answer.due == nil)
        }
    }

    @Test func anAnswerThatIsNotTheJSONIsAnError() {
        #expect(throws: KnowledgeFiling.AnswerError.self) {
            try KnowledgeFiling.proposal(.note, from: "Sure! Here is your note:", text: "x", context: context)
        }
        #expect(throws: KnowledgeFiling.AnswerError.self) {
            try KnowledgeFiling.tidyProposals(from: "{}", entries: [], context: context)
        }
    }

    // MARK: $tidy

    func index() async throws -> KnowledgeIndex {
        let library = try KnowledgeLibrary(folder: folder)
        _ = try await library.refresh()
        return library.index
    }

    @Test func theInboxIsSentWithMergeCandidatesButWithoutSecretsOrDoneTodos() async throws {
        try folder.createNote(title: "Docker volume backup", body: "use tar", project: "server-config", now: now)
        try folder.createNote(title: "Unrelated", body: "nothing", project: "server-config", now: now)
        let note = try folder.createNote(title: "Docker volume copy", body: "alpine trick", now: now)
        try folder.createNote(title: "Key", body: "sk-proj-AbCdEf0123456789AbCdEf0123456789AbCdEf0123456789", now: now)
        let done = try folder.createTodo(title: "Old", now: now)
        try folder.setStatus(.done, of: done, now: now)
        try folder.createTodo(title: "Open", now: now)

        let entries = try KnowledgeFiling.tidyEntries(index: try await index())
        #expect(Set(entries.map(\.item.title)) == ["Docker volume copy", "Open"])
        let docker = try #require(entries.first { $0.item.path == note })
        #expect(docker.similar.map(\.title) == ["Docker volume backup"])

        let request = KnowledgeFiling.tidyRequest(entries, context: context)
        #expect(request.input.contains("### \(note)\nnote: Docker volume copy"))
        #expect(request.input.contains("could be merged into: server-config/notes/docker-volume-backup.md (Docker volume backup)"))
        #expect(request.input.contains("The inbox (2 items)"))
        #expect(!request.input.contains("sk-proj"))
    }

    @Test func tidyAnswersBecomeProposalsThatChangeSomething() async throws {
        let target = try folder.createNote(title: "Docker volume backup", body: "use tar", project: "server-config", now: now)
        let copy = try folder.createNote(title: "Docker volume copy", body: "alpine trick", now: now)
        let todo = try folder.createTodo(title: "rotate key", now: now)
        let same = try folder.createNote(title: "Fine", body: "", tags: ["x"], now: now)
        let entries = try KnowledgeFiling.tidyEntries(index: try await index())
        let json = """
            {"proposals": [
              {"path": "\(copy)", "action": "merge", "project": null, "title": null, "tags": null,
               "merge_into": "\(target)", "reason": "same topic"},
              {"path": "\(todo)", "action": "move", "project": "server-config", "title": "Rotate the S3 key",
               "tags": ["Backup"], "merge_into": null, "reason": "server work"},
              {"path": "\(same)", "action": "move", "project": "inbox", "title": "Fine", "tags": ["x"],
               "merge_into": null, "reason": "nothing to do"},
              {"path": "inbox/notes/unknown.md", "action": "move", "project": "server-config", "title": "x", "tags": [],
               "merge_into": null, "reason": "?"}
            ]}
            """
        let proposals = try KnowledgeFiling.tidyProposals(from: json, entries: entries, context: context)
        #expect(proposals.map(\.item.path).sorted() == [copy, todo].sorted())
        let merge = try #require(proposals.first { $0.item.path == copy })
        #expect(merge.action == .merge(into: target, title: "Docker volume backup"))
        #expect(merge.reason == "same topic")
        let move = try #require(proposals.first { $0.item.path == todo })
        #expect(move.action == .move(project: "server-config", title: "Rotate the S3 key", tags: ["backup"]))

        #expect(try KnowledgeFiling.apply(merge, in: folder, now: now) == nil)
        #expect(!folder.exists(copy))
        #expect(try folder.item(at: target)?.body == "use tar\n\n## Docker volume copy\n\nalpine trick\n")
        let moved = try #require(try KnowledgeFiling.apply(move, in: folder, now: now))
        #expect(moved == "server-config/todos/rotate-the-s3-key.md")
        #expect(try folder.item(at: moved)?.tags == ["backup"])
        #expect(!folder.exists(todo))
    }

    @Test func aMergeIntoANoteThatWasNotOfferedIsDropped() async throws {
        let other = try folder.createNote(title: "Elsewhere", body: "x", project: "server-config", now: now)
        let note = try folder.createNote(title: "Lonely", body: "y", now: now)
        let entries = try KnowledgeFiling.tidyEntries(index: try await index())
        let proposals = try KnowledgeFiling.tidyProposals(from: """
            {"proposals": [{"path": "\(note)", "action": "merge", "project": null, "title": null, "tags": null,
              "merge_into": "\(other)", "reason": "?"}]}
            """, entries: entries, context: context)
        #expect(proposals.isEmpty)
    }

    @Test func anItemChangedSinceItWasSentIsNotTouched() async throws {
        let note = try folder.createNote(title: "Draft", body: "first", now: now)
        let entries = try KnowledgeFiling.tidyEntries(index: try await index())
        let proposals = try KnowledgeFiling.tidyProposals(from: """
            {"proposals": [{"path": "\(note)", "action": "move", "project": "server-config", "title": "Draft", "tags": [],
              "merge_into": null, "reason": "server"}]}
            """, entries: entries, context: context)
        try folder.append("more", to: note, now: now)
        #expect(throws: KnowledgeEditConflict.self) { try KnowledgeFiling.apply(proposals[0], in: folder, now: now) }
        #expect(folder.exists(note))
    }
}
