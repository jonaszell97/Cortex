import Foundation

/// A Trello board as its JSON export has it (the board's menu → Print and
/// Export → Export as JSON). Only what the import uses is read.
public struct TrelloBoard: Sendable, Decodable {
    public struct List: Sendable, Decodable {
        public var id: String
        public var name: String
        public var closed: Bool?
    }

    public struct Label: Sendable, Decodable {
        public var id: String?
        public var name: String?
        public var color: String?
    }

    public struct Attachment: Sendable, Decodable {
        public var name: String?
        public var url: String?
    }

    public struct Card: Sendable, Decodable {
        public var id: String
        public var name: String
        public var desc: String?
        public var closed: Bool?
        public var idList: String?
        public var labels: [Label]?
        public var due: String?
        public var dueComplete: Bool?
        public var dateLastActivity: String?
        public var pos: Double?
        public var attachments: [Attachment]?
    }

    public struct Checklist: Sendable, Decodable {
        public struct Item: Sendable, Decodable {
            public var name: String
            public var state: String?
            public var pos: Double?
        }

        public var idCard: String
        public var name: String?
        public var pos: Double?
        public var checkItems: [Item]?
    }

    public var name: String
    public var desc: String?
    public var lists: [List]
    public var cards: [Card]
    public var checklists: [Checklist]?

    public static func decode(_ data: Data) throws -> TrelloBoard {
        do {
            return try JSONDecoder().decode(TrelloBoard.self, from: data)
        } catch {
            throw QuickActionError("This is not a Trello board export (Export as JSON)")
        }
    }
}

public struct TrelloImportReport: Sendable, Equatable {
    /// The project the board went to.
    public var project: String = ""
    /// The project was made for this import (else one with the board's name
    /// was there already).
    public var createdProject = false
    /// To-dos written, `done` of them done.
    public var imported = 0
    public var done = 0
    /// To-dos that existed already and were left as they were.
    public var skipped: [String] = []
}

/// Turns a Trello board into a project of to-dos (docs/modules/KNOWLEDGE.md, "The
/// importers"): a card is a to-do; lists whose name says done ("done",
/// "erledigt", "fertig"), archived cards and lists, and cards whose due date was
/// ticked make it done; every other list name becomes a tag, as do the labels (a
/// label without a name by its colour). Checklists become the task list, the
/// description the body, attachments links below it.
public struct TrelloImporter: Sendable {
    public let folder: KnowledgeFolder

    public init(folder: KnowledgeFolder) {
        self.folder = folder
    }

    static let doneWords = ["done", "erledigt", "fertig"]

    public func run(_ board: TrelloBoard, timeZone: TimeZone = .current, now: Date = .now) throws -> TrelloImportReport {
        var report = TrelloImportReport()
        let name = board.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let slug = KnowledgeSlug.make(name)
        // Importing a board again goes to the project made the first time.
        let existing = folder.projectIDs().first { id in
            id == slug || (try? folder.item(at: "\(id)/README.md"))?.title.caseInsensitiveCompare(name) == .orderedSame
        }
        if let existing {
            report.project = existing
        } else {
            report.project = folder.newProjectID(for: name.isEmpty ? "Trello" : name)
            try folder.createProject(id: report.project, name: name.isEmpty ? "Trello" : name, summary: board.desc)
            report.createdProject = true
        }

        let lists = Dictionary(board.lists.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let checklists = Dictionary(grouping: board.checklists ?? [], by: \.idCard)
        var taken: Set<String> = []
        // In board order: list by list, each list's cards by position.
        let order = Dictionary(board.lists.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        let cards = board.cards.sorted { lhs, rhs in
            let left = lhs.idList.flatMap { order[$0] } ?? .max, right = rhs.idList.flatMap { order[$0] } ?? .max
            return left != right ? left < right : (lhs.pos ?? 0) < (rhs.pos ?? 0)
        }

        for card in cards {
            let list = card.idList.flatMap { lists[$0] }
            let listIsDone = list.map { list in Self.doneWords.contains { list.name.lowercased().contains($0) } } ?? false
            let isDone = listIsDone || card.closed == true || list?.closed == true || card.dueComplete == true
            let created = Self.creationDate(ofID: card.id)
            let activity = card.dateLastActivity.flatMap(FrontMatter.parseDate)

            var path = KnowledgeFolder.todoPath(project: report.project, title: card.name, date: created ?? now, timeZone: timeZone)
            // Written by this import (two cards of the same name), or there
            // before it (the board imported again).
            if taken.contains(path) {
                let stem = String(path.dropLast(3))
                var number = 2
                while taken.contains("\(stem)-\(number).md") || folder.exists("\(stem)-\(number).md") { number += 1 }
                path = "\(stem)-\(number).md"
            } else if folder.exists(path) {
                report.skipped.append(path)
                continue
            }
            taken.insert(path)

            var tags = (card.labels ?? []).compactMap { label -> String? in
                let tag = KnowledgeTag.normalize(label.name ?? "")
                return tag.isEmpty ? label.color.map(KnowledgeTag.normalize) : tag
            }
            if let list, !listIsDone { tags.insert(KnowledgeTag.normalize(list.name), at: 0) }
            var seen: Set<String> = []
            tags = tags.filter { !$0.isEmpty && seen.insert($0).inserted }

            var meta = FrontMatter()
            meta.set("title", text: card.name.trimmingCharacters(in: .whitespacesAndNewlines))
            meta.set("status", text: (isDone ? TodoStatus.done : .open).rawValue)
            if !tags.isEmpty { meta.set("tags", .list(tags)) }
            meta.set("due", text: card.due.flatMap(FrontMatter.parseDate).map { FrontMatter.formatDay($0, timeZone: timeZone) })
            meta.set("created", date: created ?? activity ?? now)
            meta.set("updated", date: activity ?? now)
            if isDone { meta.set("done", date: activity ?? now) }
            meta.set("trello", text: card.id)

            let body = Self.body(of: card, checklists: checklists[card.id] ?? [])
            try folder.write(FrontMatter.compose(meta, body: KnowledgeFolder.bodyText(body)), to: path)
            report.imported += 1
            if isDone { report.done += 1 }
        }
        return report
    }

    /// The description, the checklists as task lists (each named when there
    /// are several), then the attachments as links.
    static func body(of card: TrelloBoard.Card, checklists: [TrelloBoard.Checklist]) -> String {
        var parts: [String] = []
        if let desc = card.desc?.trimmingCharacters(in: .whitespacesAndNewlines), !desc.isEmpty {
            parts.append(desc)
        }
        let sorted = checklists.sorted { ($0.pos ?? 0) < ($1.pos ?? 0) }
        for checklist in sorted {
            let items = (checklist.checkItems ?? []).sorted { ($0.pos ?? 0) < ($1.pos ?? 0) }
            guard !items.isEmpty else { continue }
            var lines = items.map { "- [\($0.state == "complete" ? "x" : " ")] \($0.name.trimmingCharacters(in: .whitespaces))" }
            if sorted.count > 1, let name = checklist.name?.trimmingCharacters(in: .whitespaces), !name.isEmpty {
                lines.insert("**\(name)**\n", at: 0)
            }
            parts.append(lines.joined(separator: "\n"))
        }
        let links = (card.attachments ?? []).compactMap { attachment -> String? in
            guard let url = attachment.url, !url.isEmpty else { return nil }
            let name = attachment.name.flatMap { $0.isEmpty ? nil : $0 } ?? url
            return "- [\(name)](\(url))"
        }
        if !links.isEmpty { parts.append(links.joined(separator: "\n")) }
        return parts.joined(separator: "\n\n")
    }

    /// A Trello ID starts with the creation time in seconds, as eight hex digits.
    static func creationDate(ofID id: String) -> Date? {
        guard id.count >= 8, let seconds = UInt32(id.prefix(8), radix: 16) else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(seconds))
    }
}
