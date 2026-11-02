import Foundation

/// Links saved by the iPhone's share extension and intents (plans/IOS.md,
/// M5), waiting for the app. They never open the database: a suspended
/// process holding a SQLite lock in the shared container is killed, and
/// an extension can be suspended at any moment. Each link is a small JSON
/// file in the folder; the app adds them to the reading list when it runs.
public struct ReadingListOutbox: Sendable {
    public struct Entry: Codable, Sendable, Equatable {
        public var url: String
        public var title: String?
        public var sourceAppName: String?
        public var addedAt: Date
    }

    public let directory: URL

    /// `<data directory>/Outbox/reading-list`.
    public init(dataDirectory: URL) {
        directory = dataDirectory.appending(path: "Outbox/reading-list", directoryHint: .isDirectory)
    }

    public init(directory: URL) {
        self.directory = directory
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    /// Saves a link for the app. Throws `ReadingListError.notALink` for
    /// text that is not a web link, so the share sheet can say so.
    public func add(url text: String, title: String? = nil, sourceAppName: String? = nil, now: Date = .now) throws {
        guard let url = ReadingItem.normalizedURL(text) else { throw ReadingListError.notALink(text) }
        let entry = Entry(url: url, title: ReadingItem.normalizedText(title), sourceAppName: sourceAppName, addedAt: now)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // The time first, so the names sort in the order they were saved.
        let name = "\(Int64(now.timeIntervalSince1970 * 1000))-\(UUID().uuidString).json"
        try Self.encoder.encode(entry).write(to: directory.appending(path: name), options: .atomic)
    }

    /// The waiting entries' files, oldest first.
    func files() -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return urls.filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    public var isEmpty: Bool { files().isEmpty }

    /// Adds the waiting links to the reading list, oldest first, and removes
    /// each file once its link is in the database. An entry that can't be
    /// read or is no link is removed too, so it can't hold up the others.
    /// Returns how many were added.
    @discardableResult
    public func apply(to store: ReadingListStore) throws -> Int {
        var added = 0
        for file in files() {
            do {
                let entry = try Self.decoder.decode(Entry.self, from: Data(contentsOf: file))
                try store.add(url: entry.url, title: entry.title, sourceAppName: entry.sourceAppName, now: entry.addedAt)
                added += 1
            } catch let error as DecodingError {
                Log.logger("reading-list").error("Dropped an unreadable outbox entry: \(error, privacy: .public)")
            } catch ReadingListError.notALink {
                Log.logger("reading-list").error("Dropped an outbox entry that is no link")
            }
            try FileManager.default.removeItem(at: file)
        }
        return added
    }
}
