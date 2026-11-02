import Foundation

/// The quick actions the Knowledge module adds to ⌘K on a clip, the
/// selection hotkey, `>` and Shortcuts: text saved as a note or a to-do in
/// the inbox, titled by its first line, the rest its body. Text that looks
/// like a password or key asks first.
public struct KnowledgeCaptureAction: QuickAction {
    public enum Target: Sendable {
        case note, todo
    }

    public let target: Target
    let folder: KnowledgeFolder
    let now: @Sendable () -> Date

    public init(_ target: Target, folder: KnowledgeFolder, now: @escaping @Sendable () -> Date = { .now }) {
        self.target = target
        self.folder = folder
        self.now = now
    }

    public var id: String { target == .note ? "knowledge.save-note" : "knowledge.add-todo" }
    public var title: String { target == .note ? "Save as Note" : "Add as To-Do" }
    public var symbol: String { target == .note ? "square.and.pencil" : "checklist" }
    public var keywords: [String] {
        target == .note ? ["knowledge", "inbox", "remember", "capture", "outline"] : ["todo", "task", "inbox", "remind", "trello"]
    }

    public func accepts(_ input: ActionInput) -> Bool {
        guard let text = input.text else { return false }
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public func run(_ input: ActionInput, context: ActionContext) async throws -> ActionOutput {
        guard let text = input.text, accepts(input) else { throw QuickActionError("\(title) needs text") }
        let (title, body) = Self.split(text)
        let save: @Sendable () async throws -> ActionOutput = { [folder, target, now] in
            try folder.prepare()
            switch target {
            case .note: try folder.createNote(title: title, body: body, now: now())
            case .todo: try folder.createTodo(title: title, body: body, now: now())
            }
            return .done(target == .note ? "Saved “\(title)” to the inbox" : "Added “\(title)” to the inbox")
        }
        guard !SensitiveTextDetector.looksSensitive(text) else {
            return .confirm(ActionConfirmation(
                title: "Save “\(title)” anyway?",
                message: "It looks like a password or key. Notes and to-dos are plain files: they are kept in the git history, synced and readable by any app.",
                confirmTitle: "Save", perform: save))
        }
        return try await save()
    }

    /// The first line with something on it is the title, the rest the body.
    /// A first line longer than `maxTitle` is cut at a word, and then the
    /// whole text is the body.
    static func split(_ text: String, maxTitle: Int = 80) -> (title: String, body: String) {
        let lines = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n", omittingEmptySubsequences: false)
        guard let first = lines.first?.trimmingCharacters(in: .whitespaces) else { return ("Untitled", "") }
        let rest = lines.dropFirst().joined(separator: "\n")
        guard first.count > maxTitle else { return (first, rest) }
        var title = String(first.prefix(maxTitle))
        if let space = title.lastIndex(of: " "), title.distance(from: title.startIndex, to: space) > maxTitle / 2 {
            title = String(title[..<space])
        }
        return (title.trimmingCharacters(in: .whitespaces.union(.punctuationCharacters)) + "…", text.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
