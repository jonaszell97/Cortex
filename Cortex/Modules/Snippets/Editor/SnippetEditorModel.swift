import Foundation
import CortexCore

/// State of the snippet editor: the list, the selection and the draft being
/// edited. Edits stay in the draft until saved; switching to another snippet
/// saves first.
@MainActor
@Observable
final class SnippetEditorModel {
    private(set) var snippets: [Snippet] = []
    private(set) var selectedID: Int64?
    /// The snippet being edited; nil when nothing is selected.
    var draft: Snippet?
    /// Typed into the tag field but not added as a chip yet. It counts as
    /// tags (comma-separated) all the same, so saving never drops it.
    var newTag = ""
    var filter = ""
    /// The last save error, shown under the form.
    var error: String?

    @ObservationIgnored let service: SnippetsService
    @ObservationIgnored private var saved: Snippet?

    init(service: SnippetsService) {
        self.service = service
    }

    var filtered: [Snippet] {
        filter.isEmpty ? snippets : SnippetSearch.rank(snippets, query: filter)
    }

    var isNew: Bool { draft != nil && draft?.id == nil }

    /// The draft differs from what is stored.
    var isDirty: Bool {
        guard var draft else { return false }
        draft.tags += Self.tags(from: newTag)
        guard let saved else { return !draft.name.isEmpty || !draft.body.isEmpty }
        return draft.name != saved.name || Snippet.normalizedKeyword(draft.keyword) != saved.keyword
            || draft.body != saved.body || Snippet.normalizedTags(draft.tags) != saved.tags
    }

    func load() async {
        snippets = await service.all()
        if let selectedID, let current = snippets.first(where: { $0.id == selectedID }), !isDirty {
            // Usage counts change while the editor is open.
            setDraft(current)
        }
    }

    func open(_ request: SnippetEditRequest) async {
        if isDirty, await !save() { return }
        await load()
        switch request {
        case .snippet(let id):
            select(snippets.first { $0.id == id })
        case .new(let body):
            newSnippet(body: body)
        }
    }

    /// Selecting another snippet saves the current draft first; if that
    /// fails, the selection stays.
    func select(id: Int64?) async {
        guard id != selectedID || isNew else { return }
        if isDirty, await !save() { return }
        select(snippets.first { $0.id == id })
    }

    private func select(_ snippet: Snippet?) {
        selectedID = snippet?.id
        error = nil
        if let snippet { setDraft(snippet) } else { draft = nil; saved = nil; newTag = "" }
    }

    func newSnippet(name: String = "", body: String? = nil, tags: [String] = []) {
        selectedID = nil
        saved = nil
        error = nil
        draft = Snippet(name: name, body: body ?? "", tags: tags)
        newTag = ""
    }

    /// A new, unsaved snippet with the text and tags of `id`. The keyword is
    /// left out: keywords are unique.
    func duplicate(id: Int64) async {
        if isDirty, await !save() { return }
        guard let original = snippets.first(where: { $0.id == id }) else { return }
        newSnippet(name: "\(original.name) copy", body: original.body, tags: original.tags)
    }

    private func setDraft(_ snippet: Snippet) {
        draft = snippet
        saved = snippet
        newTag = ""
    }

    /// Turns what is typed in the tag field into chips.
    func addNewTag() {
        guard let tags = draft?.tags else { return }
        draft?.tags = Snippet.normalizedTags(tags + Self.tags(from: newTag))
        newTag = ""
    }

    func removeTag(_ tag: String) {
        draft?.tags.removeAll { $0 == tag }
    }

    @discardableResult
    func save() async -> Bool {
        guard var draft else { return true }
        draft.tags = Snippet.normalizedTags(draft.tags + Self.tags(from: newTag))
        do {
            let stored = try await service.save(draft)
            error = nil
            await load()
            select(snippets.first { $0.id == stored.id } ?? stored)
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    func revert() {
        if let saved { setDraft(saved) } else { select(nil) }
        error = nil
    }

    /// Deletes `id`; the selection moves on only when it was the selected one.
    func delete(id: Int64) async {
        guard id == draft?.id else {
            await service.delete(id: id)
            await load()
            return
        }
        await deleteSelected()
    }

    func deleteSelected() async {
        guard let id = draft?.id else {
            select(nil)
            return
        }
        let index = filtered.firstIndex { $0.id == id }
        await service.delete(id: id)
        draft = nil
        saved = nil
        await load()
        let remaining = filtered
        select(index.flatMap { remaining.isEmpty ? nil : remaining[min($0, remaining.count - 1)] })
    }

    static func tags(from text: String) -> [String] {
        Snippet.normalizedTags(text.split(separator: ",").map(String.init))
    }

    // MARK: - Preview

    /// The draft's body rendered with real dates and UUIDs, and markers for
    /// the clipboard, fill-ins and the cursor (the clipboard may hold a
    /// password, so its content is not shown).
    func preview(now: Date = .now) -> String {
        guard let body = draft?.body else { return "" }
        let template = SnippetTemplate(body)
        var clipboard: [Int: String] = [:]
        for offset in template.clipboardOffsets {
            clipboard[offset] = offset == 0 ? "‹clipboard›" : "‹clipboard \(offset) back›"
        }
        let fillIns = Dictionary(
            template.fillIns.map { ($0.name, $0.defaultValue.map { "‹\($0)›" } ?? "‹\($0.name)›") },
            uniquingKeysWith: { first, _ in first })
        let rendered = template.render(in: SnippetContext(now: now, clipboard: clipboard, fillIns: fillIns))
        guard let position = rendered.cursorPosition else { return rendered.text }
        var text = rendered.text
        text.insert("▏", at: text.index(text.startIndex, offsetBy: position))
        return text
    }
}
