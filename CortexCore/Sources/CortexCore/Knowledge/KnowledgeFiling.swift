import Foundation

/// `$note`, `$todo` and `$tidy` (docs/modules/KNOWLEDGE.md, "AI filing"): what is
/// sent to the AI vendor, the JSON it must answer with, and what the answer turns
/// into. The rules are `KnowledgeInstructions.filingRules`, the same the MCP
/// prompts `file-this` and `tidy-inbox` give an agent; here the model only
/// proposes, and the app writes after the proposal was shown.
public enum KnowledgeFiling {
    /// What `$note` and `$todo` file.
    public enum Target: String, Sendable {
        case note, todo
    }

    /// What the model chooses from.
    public struct Context: Sendable, Equatable {
        public var projects: [KnowledgeProject]
        /// Most used first.
        public var tags: [String]
        /// For due days such as "on Friday".
        public var today: Date
        public var timeZone: TimeZone

        public init(projects: [KnowledgeProject], tags: [String], today: Date = .now, timeZone: TimeZone = .current) {
            self.projects = projects
            self.tags = tags
            self.today = today
            self.timeZone = timeZone
        }

        var todayText: String {
            let day = FrontMatter.formatDay(today, timeZone: timeZone)
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = timeZone
            formatter.dateFormat = "EEEE"
            return "\(day) (\(formatter.string(from: today)))"
        }

        /// The project with this ID, or the inbox: a model may not make one up.
        func project(_ id: String?) -> String {
            let id = id?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
            return projects.contains { $0.id == id } ? id : KnowledgeProject.inboxID
        }
    }

    /// One request: the vendor's instructions, the user's text and the shape
    /// of the answer.
    public struct Request: Sendable, Equatable {
        public var instructions: String
        public var input: String
        public var schema: AIJSONSchema

        public func ai(model: String) -> AIRequest {
            .json(model: model, instructions: instructions, input: input, schema: schema)
        }
    }

    public struct AnswerError: Error, Equatable, LocalizedError {
        public var message: String

        public var errorDescription: String? { message }
    }

    // MARK: - $note and $todo

    /// What `$note` or `$todo` will write, as the model proposed it and the
    /// user may change it (the project) before it is written.
    public struct Proposal: Sendable, Equatable {
        /// `.note`, `.skill` or `.todo`.
        public var kind: KnowledgeKind
        public var project: String
        /// A skill's name.
        public var title: String
        public var tags: [String]
        public var body: String
        /// A skill's description.
        public var description: String?
        /// A to-do's due day, `2026-10-30`.
        public var due: String?
        /// A to-do's checklist.
        public var checklist: [String]

        public init(
            kind: KnowledgeKind, project: String, title: String, tags: [String] = [], body: String = "", description: String? = nil,
            due: String? = nil, checklist: [String] = []
        ) {
            self.kind = kind
            self.project = project
            self.title = title
            self.tags = tags
            self.body = body
            self.description = description
            self.due = due
            self.checklist = checklist
        }

        /// The body as it will be written: a to-do's checklist at its end.
        public var fullBody: String {
            guard kind == .todo, !checklist.isEmpty else { return body }
            return TodoChecklist.replacing(with: checklist.map { ($0, false) }, in: body)
        }
    }

    public static func request(_ target: Target, text: String, context: Context) -> Request {
        let answer = switch target {
        case .note:
            """
            File the text as a note or a skill. Answer with JSON only:
            - kind: "note", or "skill" when the filing rules make it one;
            - project: the id of the project (from the list below);
            - title: the note's title, or the skill's name (lowercase, hyphens);
            - tags: a list, possibly empty;
            - body: the Markdown body;
            - description: a skill's one-sentence description; null for a note.
            """
        case .todo:
            """
            File the text as a to-do. Answer with JSON only:
            - project: the id of the project (from the list below);
            - title: what to do;
            - tags: a list, possibly empty;
            - due: the due day as YYYY-MM-DD when the text gives one (today is \(context.todayText)), else null;
            - checklist: the sub-steps, possibly none;
            - body: anything else the text says, as Markdown, without the checklist; often empty.
            """
        }
        let instructions = """
            You file text into a personal knowledge base.

            \(KnowledgeInstructions.filingRules)

            \(KnowledgeInstructions.context(projects: context.projects, tags: context.tags))

            \(answer)
            """
        return Request(instructions: instructions, input: text, schema: target == .note ? noteSchema : todoSchema)
    }

    private struct NoteAnswer: Decodable {
        var kind: String
        var project: String?
        var title: String
        var tags: [String]?
        var body: String
        var description: String?
    }

    private struct TodoAnswer: Decodable {
        var project: String?
        var title: String
        var tags: [String]?
        var due: String?
        var checklist: [String]?
        var body: String?
    }

    /// The model's answer as a proposal: an unknown project is the inbox,
    /// tags are normalised, a due day that is not one is dropped, and an
    /// empty title is the text's first line.
    public static func proposal(_ target: Target, from json: String, text: String, context: Context) throws -> Proposal {
        let data = Data(json.utf8)
        let fallbackTitle = text.split(separator: "\n").first.map { String($0.prefix(80)) } ?? "Untitled"
        func title(_ value: String) -> String {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? fallbackTitle : trimmed
        }
        do {
            switch target {
            case .note:
                let answer = try JSONDecoder().decode(NoteAnswer.self, from: data)
                let isSkill = answer.kind.lowercased() == "skill"
                let description = answer.description?.trimmingCharacters(in: .whitespacesAndNewlines)
                return Proposal(
                    kind: isSkill ? .skill : .note, project: context.project(answer.project),
                    title: isSkill ? KnowledgeSlug.make(title(answer.title), maxLength: 64) : title(answer.title),
                    tags: normalized(answer.tags), body: answer.body.trimmingCharacters(in: .whitespacesAndNewlines),
                    description: isSkill ? (description?.isEmpty == false ? description : fallbackTitle) : nil)
            case .todo:
                let answer = try JSONDecoder().decode(TodoAnswer.self, from: data)
                return Proposal(
                    kind: .todo, project: context.project(answer.project), title: title(answer.title),
                    tags: normalized(answer.tags), body: (answer.body ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                    due: answer.due.flatMap(day),
                    checklist: (answer.checklist ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
            }
        } catch {
            throw AnswerError(message: "The answer was not the JSON that was asked for")
        }
    }

    /// Writes a proposal and returns the new item's path.
    @discardableResult
    public static func write(_ proposal: Proposal, to folder: KnowledgeFolder, now: Date = .now) throws -> String {
        switch proposal.kind {
        case .skill:
            try folder.createSkill(
                name: proposal.title, description: proposal.description ?? "", body: proposal.body, project: proposal.project,
                tags: proposal.tags, now: now)
        case .todo:
            try folder.createTodo(
                title: proposal.title, body: proposal.fullBody, project: proposal.project, tags: proposal.tags, due: proposal.due, now: now)
        default:
            try folder.createNote(title: proposal.title, body: proposal.body, project: proposal.project, tags: proposal.tags, now: now)
        }
    }

    // MARK: - $tidy

    /// An inbox item as `$tidy` sends it, with the notes it could be merged into.
    public struct TidyEntry: Sendable, Equatable {
        public var item: KnowledgeItem
        /// Notes outside the inbox that share words with it, best first.
        public var similar: [KnowledgeItem]

        public init(item: KnowledgeItem, similar: [KnowledgeItem] = []) {
            self.item = item
            self.similar = similar
        }
    }

    /// What `$tidy` proposes for one inbox item.
    public struct TidyProposal: Sendable, Equatable, Identifiable {
        public enum Action: Sendable, Equatable {
            /// To another project and/or under a new title and tags. The
            /// title and tags are the whole new ones.
            case move(project: String, title: String, tags: [String])
            /// Appended to this note, then moved to the Trash.
            case merge(into: String, title: String)
        }

        public var item: KnowledgeItem
        public var action: Action
        /// The model's one-line reason.
        public var reason: String

        public init(item: KnowledgeItem, action: Action, reason: String) {
            self.item = item
            self.action = action
            self.reason = reason
        }

        public var id: String { item.path }
    }

    /// The inbox items `$tidy` sends: notes, skills and open to-dos, newest
    /// first, without those that look like a secret, each note with up to
    /// three notes it could be merged into.
    public static func tidyEntries(index: KnowledgeIndex, limit: Int = 200) throws -> [TidyEntry] {
        let items = try index.search(KnowledgeQuery(projectID: KnowledgeProject.inboxID, kinds: [.note, .skill, .todo]), limit: limit)
            .map(\.item)
            .filter { $0.status != .done }
            .filter { !SensitiveTextDetector.looksSensitive($0.title) && !SensitiveTextDetector.looksSensitive($0.body) }
        return try items.map { item in
            let similar = item.kind == .note
                ? try index.similar(to: item.title, kinds: [.note], excludingProject: KnowledgeProject.inboxID, limit: 3)
                : []
            return TidyEntry(item: item, similar: similar)
        }
    }

    public static func tidyRequest(_ entries: [TidyEntry], context: Context, excerptLength: Int = 400) -> Request {
        let listed = entries.map { entry in
            let item = entry.item
            var text = "### \(item.path)\n\(item.kind.rawValue): \(item.title)"
            if !item.tags.isEmpty { text += "\ntags: \(item.tags.joined(separator: ", "))" }
            if !entry.similar.isEmpty {
                text += "\ncould be merged into: " + entry.similar.map { "\($0.path) (\($0.title))" }.joined(separator: "; ")
            }
            let body = item.body.trimmingCharacters(in: .whitespacesAndNewlines)
            if !body.isEmpty {
                text += "\n\n" + (body.count > excerptLength ? String(body.prefix(excerptLength)) + " […]" : body)
            }
            return text
        }
        let instructions = """
            You tidy the inbox of a personal knowledge base.

            \(KnowledgeInstructions.filingRules)

            \(KnowledgeInstructions.context(projects: context.projects, tags: context.tags))

            For every inbox item you get, propose one action. Answer with JSON only: {"proposals": [...]}, one entry per item, each with:
            - path: the item's path, exactly as given;
            - action: "move" to file it into a project (with a better title and tags if needed), "merge" to add a note to one of the notes it "could be merged into" (only those, and only when it is clearly about the same thing), or "keep" to leave it in the inbox (when no project clearly fits);
            - project: for "move", the project's id; else null;
            - title: for "move", the title it should have (the current one if it is fine); else null;
            - tags: for "move", all the tags it should have; else null;
            - merge_into: for "merge", the path of the note to add it to; else null;
            - reason: why, in a few words.
            """
        let input = entries.isEmpty
            ? "The inbox is empty."
            : "The inbox (\(entries.count) \(entries.count == 1 ? "item" : "items")):\n\n" + listed.joined(separator: "\n\n")
        return Request(instructions: instructions, input: input, schema: tidySchema)
    }

    private struct TidyAnswer: Decodable {
        struct Entry: Decodable {
            var path: String
            var action: String
            var project: String?
            var title: String?
            var tags: [String]?
            var mergeInto: String?
            var reason: String?

            enum CodingKeys: String, CodingKey {
                case path, action, project, title, tags, reason, mergeInto = "merge_into"
            }
        }

        var proposals: [Entry]
    }

    /// The proposals that change something, in the order of the entries.
    /// "keep", unknown paths, a move that changes nothing, a project that
    /// does not exist and a merge into a note that was not offered are left
    /// out.
    public static func tidyProposals(from json: String, entries: [TidyEntry], context: Context) throws -> [TidyProposal] {
        let answer: TidyAnswer
        do {
            answer = try JSONDecoder().decode(TidyAnswer.self, from: Data(json.utf8))
        } catch {
            throw AnswerError(message: "The answer was not the JSON that was asked for")
        }
        var byPath: [String: TidyAnswer.Entry] = [:]
        for entry in answer.proposals where byPath[entry.path] == nil {
            byPath[entry.path] = entry
        }
        return entries.compactMap { entry in
            guard let proposal = byPath[entry.item.path] else { return nil }
            let item = entry.item
            let reason = (proposal.reason ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            switch proposal.action.lowercased() {
            case "move":
                let project = context.project(proposal.project)
                let title = proposal.title?.trimmingCharacters(in: .whitespacesAndNewlines)
                let newTitle = title?.isEmpty == false ? title! : item.title
                let tags = proposal.tags.map(normalized) ?? item.tags
                guard project != item.project || newTitle != item.title || Set(tags) != Set(item.tags) else { return nil }
                // A skill's folder stays where it is; it is retagged and renamed only.
                guard item.kind != .skill || project == item.project else { return nil }
                return TidyProposal(item: item, action: .move(project: project, title: newTitle, tags: tags), reason: reason)
            case "merge":
                guard item.kind == .note, let target = entry.similar.first(where: { $0.path == proposal.mergeInto }) else { return nil }
                return TidyProposal(item: item, action: .merge(into: target.path, title: target.title), reason: reason)
            default:
                return nil
            }
        }
    }

    /// Applies one proposal and returns the item's new path (nil after a
    /// merge). Throws `KnowledgeEditConflict` when the item changed since it
    /// was sent.
    @discardableResult
    public static func apply(_ proposal: TidyProposal, in folder: KnowledgeFolder, now: Date = .now) throws -> String? {
        let item = proposal.item
        let current = try folder.text(at: item.path)
        guard KnowledgeItem.parse(path: item.path, text: current, modified: now).map({ $0.body == item.body && $0.title == item.title }) == true
        else { throw KnowledgeEditConflict(path: item.path) }
        switch proposal.action {
        case .move(let project, let title, let tags):
            var edit = KnowledgeEdit(item, text: current)
            edit.title = title
            edit.tags = tags
            if item.kind == .note || item.kind == .todo { edit.project = project }
            return try folder.save(edit, at: item.path, now: now)
        case .merge(let target, _):
            let body = item.body.trimmingCharacters(in: .whitespacesAndNewlines)
            try folder.append("## \(item.title)" + (body.isEmpty ? "" : "\n\n" + body), to: target, now: now)
            try folder.delete(item.path)
            return nil
        }
    }

    // MARK: - Helpers

    private static func normalized(_ tags: [String]?) -> [String] {
        var seen: Set<String> = []
        return (tags ?? []).map(KnowledgeTag.normalize).filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// `2026-10-30`, or nil for anything else.
    static func day(_ text: String) -> String? {
        let text = text.trimmingCharacters(in: .whitespaces)
        guard text.wholeMatch(of: /\d{4}-\d{2}-\d{2}/) != nil else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: text), formatter.string(from: date) == text else { return nil }
        return text
    }

    // MARK: - Schemas (strict: every property required, optional ones nullable)

    static let noteSchema = AIJSONSchema(name: "knowledge_note", json: """
        {"type": "object", "additionalProperties": false,
         "required": ["kind", "project", "title", "tags", "body", "description"],
         "properties": {
           "kind": {"type": "string", "enum": ["note", "skill"]},
           "project": {"type": "string"},
           "title": {"type": "string"},
           "tags": {"type": "array", "items": {"type": "string"}},
           "body": {"type": "string"},
           "description": {"type": ["string", "null"]}}}
        """)

    static let todoSchema = AIJSONSchema(name: "knowledge_todo", json: """
        {"type": "object", "additionalProperties": false,
         "required": ["project", "title", "tags", "due", "checklist", "body"],
         "properties": {
           "project": {"type": "string"},
           "title": {"type": "string"},
           "tags": {"type": "array", "items": {"type": "string"}},
           "due": {"type": ["string", "null"]},
           "checklist": {"type": "array", "items": {"type": "string"}},
           "body": {"type": "string"}}}
        """)

    static let tidySchema = AIJSONSchema(name: "knowledge_tidy", json: """
        {"type": "object", "additionalProperties": false, "required": ["proposals"],
         "properties": {"proposals": {"type": "array", "items": {
           "type": "object", "additionalProperties": false,
           "required": ["path", "action", "project", "title", "tags", "merge_into", "reason"],
           "properties": {
             "path": {"type": "string"},
             "action": {"type": "string", "enum": ["move", "merge", "keep"]},
             "project": {"type": ["string", "null"]},
             "title": {"type": ["string", "null"]},
             "tags": {"type": ["array", "null"], "items": {"type": "string"}},
             "merge_into": {"type": ["string", "null"]},
             "reason": {"type": "string"}}}}}}
        """)
}
