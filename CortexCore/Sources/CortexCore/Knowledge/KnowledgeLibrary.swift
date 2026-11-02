import Foundation

/// The knowledge folder and its index, kept in step: `refresh` reads the
/// files that changed since the last time (by modification date) and
/// updates the index. Called at launch and whenever the folder watcher
/// fires, and after every write of the app's own.
public actor KnowledgeLibrary {
    public nonisolated let folder: KnowledgeFolder
    public nonisolated let index: KnowledgeIndex

    public struct Changes: Sendable, Equatable {
        public var updated: [String] = []
        public var removed: [String] = []
        public var isEmpty: Bool { updated.isEmpty && removed.isEmpty }
    }

    public init(folder: KnowledgeFolder) throws {
        self.folder = folder
        index = try KnowledgeIndex()
    }

    /// Reads new and changed files, drops deleted ones, and lists the
    /// projects again. A file that cannot be read is left out (and logged).
    @discardableResult
    public func refresh() throws -> Changes {
        let files = folder.itemFiles()
        let indexed = try index.modificationDates()
        var changes = Changes()
        var items: [KnowledgeItem] = []
        var sources: [String: (text: String, modified: Date)] = [:]

        for (path, modified) in files where indexed[path] != modified {
            do {
                let text = try folder.text(at: path)
                guard let item = KnowledgeItem.parse(path: path, text: text, modified: modified) else { continue }
                items.append(item)
                sources[path] = (text, modified)
                changes.updated.append(path)
            } catch {
                Log.knowledge.error("Cannot read \(path, privacy: .public): \(error, privacy: .public)")
            }
        }
        changes.removed = indexed.keys.filter { files[$0] == nil }
        changes.updated.sort()
        changes.removed.sort()
        try index.apply(upserting: items, sources: sources, removing: changes.removed)

        let projects = try folder.projectIDs().map { id in
            KnowledgeProject(id: id, readme: try index.item(at: "\(id)/README.md"))
        }
        try index.setProjects(Self.ordered(projects))
        return changes
    }

    /// The inbox first, then by name.
    static func ordered(_ projects: [KnowledgeProject]) -> [KnowledgeProject] {
        projects.sorted { lhs, rhs in
            if lhs.isInbox != rhs.isInbox { return lhs.isInbox }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }
}

extension Log {
    static let knowledge = logger("knowledge")
}
