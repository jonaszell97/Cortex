import Foundation

/// What the note editor saves: the fields it shows, and the file's text as
/// it was read, so a change made meanwhile by an editor, an agent or the
/// other Mac is not overwritten unasked.
public struct KnowledgeEdit: Sendable, Equatable {
    /// A note's or to-do's title, a skill's or project's name.
    public var title: String
    public var tags: [String]
    public var body: String
    /// A skill's description, a project's summary; ignored for the rest.
    public var summary: String?
    /// Notes and to-dos only: another project moves the file there.
    public var project: String?
    /// To-dos only.
    public var status: TodoStatus?
    /// To-dos only, a day (`2026-10-30`); nil or empty removes it.
    public var due: String?
    /// The whole file as it was read.
    public var original: String

    public init(
        title: String, tags: [String] = [], body: String, summary: String? = nil, project: String? = nil,
        status: TodoStatus? = nil, due: String? = nil, original: String
    ) {
        self.title = title
        self.tags = tags
        self.body = body
        self.summary = summary
        self.project = project
        self.status = status
        self.due = due
        self.original = original
    }

    /// The fields of an item as read from `text`.
    public init(_ item: KnowledgeItem, text: String) {
        self.init(
            title: item.title, tags: item.tags, body: item.body.trimmingCharacters(in: .newlines), summary: item.summary,
            project: item.kind == .note || item.kind == .todo ? item.project : nil,
            status: item.status, due: item.due, original: text)
    }

    /// Whether saving would write text that looks like a password or key
    /// (`SensitiveTextDetector`) that was not in the file already: the
    /// title, summary and tags as a whole, the body line by line, so a key
    /// that was in the note before does not ask again on every save. A new
    /// item has an empty `original`.
    public var addsSensitiveText: Bool {
        let before = Set(original.split(separator: "\n", omittingEmptySubsequences: true).map {
            $0.trimmingCharacters(in: .whitespaces)
        })
        let fields = [title, summary ?? ""] + tags
        if fields.contains(where: { !$0.isEmpty && SensitiveTextDetector.looksSensitive($0) && !original.contains($0) }) {
            return true
        }
        return body.split(separator: "\n", omittingEmptySubsequences: true).contains { line in
            let line = line.trimmingCharacters(in: .whitespaces)
            return !line.isEmpty && !before.contains(line) && SensitiveTextDetector.looksSensitive(line)
        }
    }
}

/// The file changed on disk (or is gone) since the editor read it.
public struct KnowledgeEditConflict: Error, Equatable, LocalizedError {
    public var path: String

    public var errorDescription: String? {
        "\(path) changed on disk since it was opened."
    }
}
