import Foundation
import CortexCore

/// The results of a palette list (clips, snippets, actions) and which one is
/// selected. Loading the same query again keeps the selection while the item
/// is still there, and moves it to the neighbour of an item that went away;
/// a new query selects the first result.
@MainActor
@Observable
final class ResultList<Item, ID: Hashable> {
    private(set) var items: [Item] = []
    private(set) var selectedID: ID?
    /// False until the first results are in, so the list does not flash its
    /// empty state while loading.
    private(set) var hasLoaded = false
    /// Called after the selection changed, with the newly selected item.
    @ObservationIgnored var didSelect: ((Item?) -> Void)?

    @ObservationIgnored private let id: (Item) -> ID
    @ObservationIgnored private var loadedQuery: String?
    @ObservationIgnored private var task: Task<Void, Never>?

    init(id: @escaping (Item) -> ID) {
        self.id = id
    }

    var isEmpty: Bool { items.isEmpty }

    var selectedIndex: Int? {
        items.firstIndex { id($0) == selectedID }
    }

    var selected: Item? {
        selectedIndex.map { items[$0] }
    }

    func item(at index: Int) -> Item? {
        items.indices.contains(index) ? items[index] : nil
    }

    func id(of item: Item) -> ID {
        id(item)
    }

    func select(_ id: ID?) {
        guard id != selectedID else { return }
        selectedID = id
        didSelect?(selected)
    }

    /// ↑ and ↓, stopping at either end.
    func move(by delta: Int) {
        guard !items.isEmpty else { return }
        let current = selectedIndex ?? -1
        select(id(items[min(max(current + delta, 0), items.count - 1)]))
    }

    /// Shows the results for `query`.
    func replace(with results: [Item], query: String) {
        let previousIndex = selectedIndex
        let queryChanged = query != loadedQuery
        items = results
        loadedQuery = query
        hasLoaded = true
        if queryChanged || selectedID == nil {
            select(results.first.map(id))
        } else if !results.contains(where: { id($0) == selectedID }) {
            // The selected item went away: select its neighbour.
            select(item(at: min(previousIndex ?? 0, results.count - 1)).map(id))
        }
    }

    /// Runs `search` and shows its results for `query`. A search still
    /// running is cancelled, and its results never shown.
    @discardableResult
    func load(query: String, _ search: @escaping @MainActor () async throws -> [Item]) -> Task<Void, Never> {
        task?.cancel()
        let task = Task {
            do {
                let results = try await search()
                guard !Task.isCancelled else { return }
                replace(with: results, query: query)
            } catch {
                Log.logger("palette").error("Search failed: \(error, privacy: .public)")
            }
        }
        self.task = task
        return task
    }

    /// Drops everything loaded.
    func clear() {
        task?.cancel()
        items = []
        selectedID = nil
        loadedQuery = nil
        hasLoaded = false
    }
}
