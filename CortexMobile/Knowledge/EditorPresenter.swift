import SwiftUI
import CortexCore

/// What the editor holds: a new item or an existing one, its fields as
/// edited, the fields and the file as they were read. Kept on disk while
/// the editor is open, so the edit survives iOS ending the app.
struct EditorDraft: Codable, Equatable {
    struct Fields: Codable, Equatable {
        var title = ""
        /// As typed, comma-separated.
        var tags = ""
        var body = ""
        var summary = ""
        var project = KnowledgeProject.inboxID
        var isDone = false
        /// A day, `2026-10-30`.
        var due: String?
    }

    /// nil for a new item.
    var path: String?
    var kind: KnowledgeKind
    var fields: Fields
    /// What was read, or the new item's defaults: unchanged means nothing
    /// to save.
    var initial: Fields
    /// The file as it was read; empty for a new item.
    var original: String

    var isNew: Bool { path == nil }
    var isDirty: Bool { fields != initial }
    var isTodo: Bool { kind == .todo }
    /// Notes and to-dos can move to another project; skills and READMEs are
    /// where their folder is.
    var canMove: Bool { kind == .note || kind == .todo }
    var summaryLabel: String? {
        switch kind {
        case .skill: "Description"
        case .project: "Summary"
        default: nil
        }
    }

    var edit: KnowledgeEdit {
        KnowledgeEdit(
            title: fields.title, tags: fields.tags.split(separator: ",").map(String.init), body: fields.body,
            summary: summaryLabel == nil ? nil : fields.summary, project: canMove ? fields.project : nil,
            status: isTodo ? (fields.isDone ? .done : .open) : nil, due: isTodo ? fields.due : nil, original: original)
    }
}

/// The note editor for the whole app: presented once, from `RootView`, so
/// any screen can open it and a relaunch can reopen it with its draft.
/// Saving goes through `KnowledgeFolder.save`, which refuses to overwrite a
/// file that changed since it was read (usually a sync): then the user
/// keeps theirs, takes the other, or keeps both.
@MainActor
@Observable
final class EditorPresenter {
    enum Conflict: Equatable {
        /// The file changed on disk since it was read.
        case changed
        /// The file is gone (deleted or moved on another device).
        case gone
    }

    /// The sheet is up while there is a draft.
    var draft: EditorDraft?
    var conflict: Conflict?
    /// The text looks like a password or key: "Save anyway?".
    var confirmingSensitive = false
    var error: String?
    private(set) var isSaving = false
    /// The last save that moved an item (a new title or project), for the
    /// item view showing it.
    private(set) var lastMove: Move?

    struct Move: Equatable {
        var from: String
        var to: String
    }

    @ObservationIgnored private let knowledge: KnowledgeStore
    @ObservationIgnored private let draftURL: URL
    @ObservationIgnored private var draftWrite: Task<Void, Never>?
    @ObservationIgnored private let log = Log.logger("editor")

    init(knowledge: KnowledgeStore, draftURL: URL) {
        self.knowledge = knowledge
        self.draftURL = draftURL
    }

    // MARK: - Opening

    /// A new note or to-do, in `project` (the inbox by default).
    func new(_ kind: KnowledgeKind, project: String? = nil) {
        guard draft == nil else { return }
        var fields = EditorDraft.Fields()
        fields.project = project ?? KnowledgeProject.inboxID
        open(EditorDraft(path: nil, kind: kind, fields: fields, initial: fields, original: ""))
    }

    /// The item at `path`, as it is on disk now.
    func edit(_ path: String) {
        guard draft == nil else { return }
        do {
            open(try Self.read(path, folder: knowledge.folder))
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func open(_ draft: EditorDraft) {
        conflict = nil
        error = nil
        self.draft = draft
    }

    private static func read(_ path: String, folder: KnowledgeFolder) throws -> EditorDraft {
        let text = try folder.text(at: path)
        guard let item = KnowledgeItem.parse(path: path, text: text, modified: .now) else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "\(path) is not a note, skill or to-do."])
        }
        let fields = EditorDraft.Fields(
            title: item.title, tags: item.tags.joined(separator: ", "), body: item.body.trimmingCharacters(in: .newlines),
            summary: item.summary ?? "", project: item.project, isDone: item.status == .done, due: item.due)
        return EditorDraft(path: path, kind: item.kind, fields: fields, initial: fields, original: text)
    }

    /// The folder changed (a sync): an untouched draft shows the new text.
    /// One with edits keeps them; saving notices the change.
    func folderChanged() {
        guard let draft, let path = draft.path, !draft.isDirty, conflict == nil, !isSaving else { return }
        guard let text = try? knowledge.folder.text(at: path), text != draft.original,
              let fresh = try? Self.read(path, folder: knowledge.folder)
        else { return }
        self.draft = fresh
    }

    // MARK: - Closing

    /// Drops the draft and closes.
    func close() {
        draft = nil
        conflict = nil
        confirmingSensitive = false
        error = nil
        removeDraftFile()
    }

    /// Saves, after asking about text that looks like a secret. Closes when
    /// the item is written.
    func save(confirmedSensitive: Bool = false) async {
        guard let draft, !isSaving else { return }
        guard draft.isDirty || draft.isNew else { return close() }
        if !confirmedSensitive, draft.edit.addsSensitiveText {
            confirmingSensitive = true
            return
        }
        isSaving = true
        defer { isSaving = false }
        do {
            if let path = draft.path {
                let saved = try await knowledge.save(draft.edit, at: path)
                if saved != path { lastMove = Move(from: path, to: saved) }
            } else {
                try await create(draft)
            }
            close()
        } catch is KnowledgeEditConflict {
            conflict = .changed
        } catch CocoaError.fileReadNoSuchFile, CocoaError.fileNoSuchFile {
            conflict = .gone
        } catch {
            log.error("Saving failed: \(error, privacy: .public)")
            self.error = error.localizedDescription
        }
    }

    private func create(_ draft: EditorDraft) async throws {
        let fields = draft.fields
        let tags = fields.tags.split(separator: ",").map(String.init)
        if draft.isTodo {
            let path = try await knowledge.createTodo(
                title: fields.title, body: fields.body, project: fields.project, tags: tags, due: fields.due)
            if fields.isDone { try await knowledge.setStatus(.done, of: path) }
        } else {
            _ = try await knowledge.createNote(title: fields.title, body: fields.body, project: fields.project, tags: tags)
        }
    }

    // MARK: - After a conflict

    /// Writes the edit over what changed on disk.
    func keepMine() async {
        guard let path = draft?.path else { return }
        guard let text = try? knowledge.folder.text(at: path) else {
            conflict = .gone
            return
        }
        draft?.original = text
        conflict = nil
        // Asked already, if it needed asking.
        await save(confirmedSensitive: true)
    }

    /// Drops the edit; the item shows what is on disk.
    func takeTheirs() {
        close()
    }

    /// Keeps both: the edit becomes a new item next to the other.
    func copyMine() async {
        guard let draft, let path = draft.path else { return }
        do {
            _ = try await knowledge.saveCopy(draft.edit, of: path)
            close()
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - The draft on disk

    /// While typing: written a second after the last change.
    func draftChanged() {
        draftWrite?.cancel()
        draftWrite = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.saveDraft()
        }
    }

    /// Writes the draft if it has edits, else removes the file. The file is
    /// in the data directory, which is excluded from backups.
    func saveDraft() {
        draftWrite?.cancel()
        guard let draft, draft.isDirty else { return removeDraftFile() }
        do {
            try JSONEncoder().encode(draft).write(to: draftURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            log.error("Cannot keep the draft: \(error, privacy: .public)")
        }
    }

    /// At launch: the editor was open with edits when the app went away.
    func restoreDraft() {
        guard draft == nil, let data = try? Data(contentsOf: draftURL) else { return }
        guard let restored = try? JSONDecoder().decode(EditorDraft.self, from: data) else { return removeDraftFile() }
        open(restored)
    }

    private func removeDraftFile() {
        draftWrite?.cancel()
        try? FileManager.default.removeItem(at: draftURL)
    }
}
