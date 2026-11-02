import CoreSpotlight
import SwiftUI
import CortexCore

/// Notes and to-dos in Spotlight (plans/IOS.md, M5), on this iPhone only.
/// Each update compares the index's modification dates with the ones
/// indexed last time (`Spotlight.json` in the data directory), so a launch,
/// whose first refresh reads every file, doesn't index everything again.
/// A result opens the item through its deep link (`CortexMobileApp`).
@MainActor
@Observable
final class SpotlightIndexer {
    /// Settings → Show in Spotlight; off removes everything from the index.
    var isEnabled: Bool {
        didSet {
            defaults.set(isEnabled, forKey: Self.enabledKey)
            if isEnabled {
                requestUpdate()
            } else {
                Task { await removeAll() }
            }
        }
    }

    @ObservationIgnored private let knowledge: KnowledgeStore
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let stateURL: URL
    @ObservationIgnored private let index = CSSearchableIndex(
        name: "knowledge", protectionClass: .completeUntilFirstUserAuthentication)
    @ObservationIgnored private var updateTask: Task<Void, Never>?
    @ObservationIgnored private var needsUpdate = false
    @ObservationIgnored private let log = Log.logger("spotlight")

    private static let enabledKey = "spotlight.enabled"
    private static let batchSize = 200

    init(knowledge: KnowledgeStore, defaults: UserDefaults, dataDirectory: URL) {
        self.knowledge = knowledge
        self.defaults = defaults
        stateURL = dataDirectory.appending(path: "Spotlight.json")
        isEnabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
    }

    /// After a refresh changed the folder; one update at a time.
    func requestUpdate() {
        guard isEnabled else { return }
        guard updateTask == nil else {
            needsUpdate = true
            return
        }
        updateTask = Task { [weak self] in
            guard let self else { return }
            repeat {
                needsUpdate = false
                await update()
            } while needsUpdate && isEnabled
            updateTask = nil
        }
    }

    private func update() async {
        let indexed = readState()
        let current = await knowledge.modificationDates(of: KnowledgeSpotlight.kinds)
        let changes = KnowledgeSpotlight.changes(indexed: indexed, current: current)
        guard !changes.update.isEmpty || !changes.remove.isEmpty else { return }
        var state = indexed
        do {
            for batch in changes.update.chunks(of: Self.batchSize) {
                let items = await knowledge.items(at: Array(batch)).map {
                    KnowledgeSpotlight.searchableItem(for: $0, projectName: knowledge.project($0.project).name)
                }
                try await index.indexSearchableItems(items)
                for path in batch { state[path] = current[path] }
            }
            if !changes.remove.isEmpty {
                try await index.deleteSearchableItems(withIdentifiers: changes.remove)
                for path in changes.remove { state[path] = nil }
            }
            log.info("Indexed \(changes.update.count) items, removed \(changes.remove.count)")
        } catch {
            log.error("Spotlight indexing failed: \(error, privacy: .public)")
        }
        // What made it in, so a failure retries only the rest.
        writeState(state)
    }

    private func removeAll() async {
        updateTask?.cancel()
        do {
            try await index.deleteAllSearchableItems()
            try? FileManager.default.removeItem(at: stateURL)
            log.info("Removed everything from Spotlight")
        } catch {
            log.error("Cannot clear Spotlight: \(error, privacy: .public)")
        }
    }

    // MARK: - What was indexed

    private func readState() -> [String: Date] {
        guard let data = try? Data(contentsOf: stateURL) else { return [:] }
        return (try? JSONDecoder().decode([String: Date].self, from: data)) ?? [:]
    }

    private func writeState(_ state: [String: Date]) {
        do {
            try JSONEncoder().encode(state).write(to: stateURL, options: .atomic)
        } catch {
            log.error("Cannot save the Spotlight state: \(error, privacy: .public)")
        }
    }
}

private extension Array {
    func chunks(of size: Int) -> [ArraySlice<Element>] {
        stride(from: 0, to: count, by: size).map { self[$0..<Swift.min($0 + size, count)] }
    }
}
