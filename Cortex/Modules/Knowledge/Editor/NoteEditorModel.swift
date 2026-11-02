import Foundation
import CortexCore

/// State of the note editor: one item of the knowledge base at a time, its
/// fields as edited and as read. Edits stay in the window until saved; a
/// file that changed on disk meanwhile is reloaded when nothing was edited,
/// and asked about when something was.
@MainActor
@Observable
final class NoteEditorModel {
    /// What the form shows, compared with what was read to know whether
    /// there is anything to save.
    struct Fields: Equatable {
        var title = ""
        /// As typed, comma-separated.
        var tags = ""
        var body = ""
        var summary = ""
        var project = KnowledgeProject.inboxID
        var isDone = false
        var due: String?
    }

    private(set) var path: String?
    private(set) var kind: KnowledgeKind?
    var fields = Fields()
    /// The last save error, shown under the form.
    var error: String?
    /// The file changed on disk while there were edits: overwrite or reload.
    var hasConflict = false
    /// The file went away while the window was open.
    private(set) var isGone = false

    @ObservationIgnored let service: KnowledgeService
    @ObservationIgnored private var saved = Fields()
    /// The file as read, so a change made meanwhile is not overwritten.
    @ObservationIgnored private var original = ""

    init(service: KnowledgeService) {
        self.service = service
    }

    var isDirty: Bool { path != nil && fields != saved }
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

    var projects: [KnowledgeProject] { service.projects }

    /// Opens the item at `path`, after saving the one being edited. false:
    /// that save failed, and the window stays on it.
    @discardableResult
    func open(_ path: String) async -> Bool {
        if path != self.path, isDirty, await !save() { return false }
        return load(path)
    }

    /// Reads the file and fills the form; edits are dropped.
    @discardableResult
    func load(_ path: String) -> Bool {
        let folder = service.folder
        do {
            let text = try folder.text(at: path)
            guard let item = KnowledgeItem.parse(path: path, text: text, modified: .now) else {
                error = "\(path) is not a note, skill or to-do."
                return false
            }
            self.path = path
            kind = item.kind
            original = text
            let fields = Fields(
                title: item.title, tags: item.tags.joined(separator: ", "), body: item.body.trimmingCharacters(in: .newlines),
                summary: item.summary ?? "", project: item.project, isDone: item.status == .done, due: item.due)
            self.fields = fields
            saved = fields
            error = nil
            hasConflict = false
            isGone = false
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    /// Shows nothing; edits are dropped (the browser's list went empty).
    func clear() {
        path = nil
        kind = nil
        original = ""
        fields = Fields()
        saved = fields
        error = nil
        hasConflict = false
        isGone = false
    }

    /// The folder changed: the file is read again unless there are edits
    /// (then saving asks), and noticed when it went away.
    func folderChanged() {
        guard let path else { return }
        guard service.folder.exists(path) else {
            isGone = true
            return
        }
        isGone = false
        guard !isDirty, let text = try? service.folder.text(at: path), text != original else { return }
        load(path)
    }

    var edit: KnowledgeEdit {
        KnowledgeEdit(
            title: fields.title, tags: fields.tags.split(separator: ",").map(String.init), body: fields.body,
            summary: summaryLabel == nil ? nil : fields.summary, project: canMove ? fields.project : nil,
            status: isTodo ? (fields.isDone ? .done : .open) : nil, due: isTodo ? fields.due : nil, original: original)
    }

    /// Writes the file (moving it when the title or project changed). A file
    /// that changed on disk is not overwritten: `hasConflict` asks.
    @discardableResult
    func save() async -> Bool {
        guard let path else { return true }
        guard isDirty else { return true }
        do {
            let newPath = try await service.save(edit, at: path)
            load(newPath)
            return true
        } catch is KnowledgeEditConflict {
            hasConflict = true
            return false
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    /// Saves over what changed on disk.
    func overwrite() async {
        guard let path, let text = try? service.folder.text(at: path) else {
            hasConflict = false
            error = "\(path ?? "The file") is gone."
            return
        }
        original = text
        hasConflict = false
        await save()
    }

    /// Drops the edits and reads the file again.
    func revert() {
        guard let path else { return }
        if !load(path) { fields = saved }
    }

    /// Saves first, so VS Code opens what is in the window.
    func openInEditor() async {
        guard await save(), let path else { return }
        service.open(path)
    }

    /// The due day as a date, for the picker; set to nil to remove it.
    var dueDate: Date? {
        get { fields.due.flatMap { FrontMatter.parseDate(String($0.prefix(10))) } }
        set { fields.due = newValue.map { FrontMatter.formatDay($0, timeZone: TimeZone(identifier: "UTC")!) } }
    }
}
