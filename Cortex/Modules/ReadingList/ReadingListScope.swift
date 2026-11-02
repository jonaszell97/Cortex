import AppKit
import SwiftUI
import CortexCore

/// A row of the `+` list: a saved link, or the link typed into the search
/// field, ready to add.
enum ReadingListEntry: Hashable, Identifiable {
    case add(url: String)
    case item(ReadingItem)

    var id: String {
        switch self {
        case .add(let url): "add:\(url)"
        case .item(let item): "item:\(item.id ?? -1)"
        }
    }

    var item: ReadingItem? {
        if case .item(let item) = self { item } else { nil }
    }
}

/// `+` in the palette: the reading list, unread first, searched by title,
/// host, URL and note. A link typed or pasted into the search field is
/// offered for adding. ⏎ opens the selected link and marks it read, ⌥⏎
/// copies it; ⌘R marks it read or unread, ⌘E edits its title and note, ⌘⌫
/// deletes it, ⌘N adds the link on the clipboard.
@MainActor
@Observable
final class ReadingListScope: PaletteScope {
    let list = ResultList<ReadingListEntry, String>(id: \.id)
    /// The query as last searched, for the empty state.
    private(set) var query = ""

    @ObservationIgnored private let service: ReadingListService
    @ObservationIgnored private let moduleID: ModuleID
    @ObservationIgnored private let palette: @MainActor () -> any PaletteHost
    /// All links, loaded once per show; search runs over these.
    @ObservationIgnored private var itemsLoad: Task<[ReadingItem], Never>?
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    /// nil while nothing is loaded (the palette is hidden).
    @ObservationIgnored private var loadedQuery: String?
    /// The last add, edit or delete started from the palette (for tests).
    @ObservationIgnored private var changeTask: Task<Void, Never>?

    init(service: ReadingListService, moduleID: ModuleID, palette: @escaping @MainActor () -> any PaletteHost) {
        self.service = service
        self.moduleID = moduleID
        self.palette = palette
    }

    /// Links changed: load them again if they are showing.
    func itemsDidChange() {
        itemsLoad = nil
        if let loadedQuery { search(loadedQuery) }
    }

    /// Waits for the last change and search to finish, including a search
    /// that a reload started meanwhile (for tests).
    func loaded() async {
        await changeTask?.value
        var task: Task<Void, Never>?
        repeat {
            task = searchTask
            await task?.value
        } while task != searchTask
    }

    /// The rows for a query: a typed link first (or the saved link it
    /// matches), then the search results.
    nonisolated static func entries(for items: [ReadingItem], query: String, includeRead: Bool) -> [ReadingListEntry] {
        let ranked = ReadingListSearch.rank(items, query: query, includeRead: includeRead)
        guard let url = ReadingItem.normalizedURL(query) else { return ranked.map(ReadingListEntry.item) }
        if let saved = items.first(where: { $0.url == url }) {
            return [.item(saved)] + ranked.filter { $0.url != url }.map(ReadingListEntry.item)
        }
        return [.add(url: url)] + ranked.map(ReadingListEntry.item)
    }

    // MARK: - PaletteScope

    func search(_ text: String) {
        query = text
        loadedQuery = text
        // Shared by the searches while typing, so a cancelled search does not
        // throw away the loaded links.
        let service = service
        let load = itemsLoad ?? Task { await service.all() }
        itemsLoad = load
        let includeRead = service.settings.listRead
        searchTask = list.load(query: text) {
            Self.entries(for: await load.value, query: text, includeRead: includeRead)
        }
    }

    func clear() {
        list.clear()
        itemsLoad?.cancel()
        itemsLoad = nil
        loadedQuery = nil
    }

    var body: AnyView { AnyView(ReadingListView(scope: self)) }

    func move(_ step: PaletteStep) {
        if case .vertical(let delta) = step { list.move(by: delta) }
    }

    func activate(_ activation: PaletteActivation, target: PaletteTarget) -> Bool {
        let entry = switch target {
        case .selected: list.selected
        case .position(let index): list.item(at: index)
        }
        if let entry { choose(entry, copyOnly: activation.isCopy) }
        return true
    }

    var activationHints: [PaletteHint] {
        if case .add = list.selected {
            return [PaletteHint(.primary, "Add")]
        }
        return [PaletteHint(.primary, "Open"), PaletteHint(.option, "Copy link")]
    }

    var keys: [PaletteKey] {
        let selected = list.selected?.item
        return [
            PaletteKey(.command("r"), hint: selected.map { $0.isRead ? "Mark unread" : "Mark read" }) { [unowned self] in
                guard let item = list.selected?.item, let id = item.id else { return true }
                change { await $0.setRead(!item.isRead, id: id) }
                return true
            },
            PaletteKey(.command("e"), hint: selected == nil ? nil : "Edit") { [unowned self] in
                guard let item = list.selected?.item else { return true }
                palette().present(editOverlay(for: ReadingItemForm(item: item)))
                return true
            },
            PaletteKey(.command(.delete), hint: selected == nil ? nil : "Delete") { [unowned self] in
                guard let id = list.selected?.item?.id else { return true }
                change { await $0.delete(id: id) }
                return true
            },
            PaletteKey(.command("n"), hint: "Add from clipboard") { [unowned self] in
                addFromClipboard()
                return true
            },
        ]
    }

    // MARK: - Actions

    /// Opens a link (marking it read) or copies it; adds a typed one.
    func choose(_ entry: ReadingListEntry, copyOnly: Bool = false) {
        switch entry {
        case .add(let url):
            add(url: url, title: nil)
        case .item(let item) where copyOnly:
            palette().closeAndDeliver(
                .text(item.url), .copyOnly, recording: .record(sensitive: false), restoringPasteboard: false, after: nil)
        case .item(let item):
            palette().close()
            change { await $0.open(item) }
        }
    }

    /// Adds the link on the clipboard; without one, nothing happens.
    func addFromClipboard(_ pasteboard: NSPasteboard = .general) {
        guard let link = ReadingListService.link(on: pasteboard) else {
            Beep.play()
            return
        }
        add(url: link.url, title: link.title)
    }

    /// Saves a link and shows the list with it on top, selected.
    private func add(url: String, title: String?) {
        let source = palette().previousApp?.localizedName
        let moduleID = moduleID
        change { [weak self] service in
            _ = try? await service.add(url: url, title: title, sourceAppName: source)
            self?.palette().open(moduleID)
        }
    }

    /// The form for a link's title and note. ⏎ saves and goes back to the
    /// list.
    func editOverlay(for form: ReadingItemForm) -> PaletteOverlay {
        let item = form.item
        let moduleID = moduleID
        return PaletteOverlay(
            body: AnyView(ReadingItemFormView(form: form)),
            activationHints: [PaletteHint(.primary, "Save")],
            keys: [PaletteKey(.tab, hint: "Next field")],
            activate: { [unowned self] _ in
                guard let id = item.id else { return }
                change { [weak self] service in
                    await service.edit(id: id, title: form.title, note: form.note)
                    self?.palette().open(moduleID)
                }
            },
            escape: .dismiss)
    }

    /// Runs a change, then reloads the list.
    private func change(_ work: @escaping @MainActor (ReadingListService) async -> Void) {
        let service = service
        changeTask = Task { [weak self] in
            await work(service)
            self?.itemsDidChange()
        }
    }
}

/// A link's title and note as typed so far.
@MainActor
@Observable
final class ReadingItemForm {
    let item: ReadingItem
    var title: String
    var note: String

    init(item: ReadingItem) {
        self.item = item
        title = item.title ?? ""
        note = item.note ?? ""
    }
}
