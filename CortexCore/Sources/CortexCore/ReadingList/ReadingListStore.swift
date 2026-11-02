import Foundation
import GRDB

public enum ReadingListError: Error, Equatable, CustomStringConvertible, LocalizedError {
    case notALink(String)

    public var description: String {
        switch self {
        case .notALink(let text): "“\(text)” is not a web link."
        }
    }

    public var errorDescription: String? { description }
}

/// Reading list storage on top of `AppDatabase`. Like `SnippetStore`, the
/// synchronous methods block on the database; call them off the main actor.
public final class ReadingListStore: Sendable {
    let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
    }

    // MARK: - Reading

    /// Every link, newest first.
    public func all() async throws -> [ReadingItem] {
        try await database.reader.read { db in
            try ReadingItem.order(Column("addedAt").desc).fetchAll(db)
        }
    }

    public func item(id: Int64) async throws -> ReadingItem? {
        try await database.reader.read { db in try ReadingItem.fetchOne(db, key: id) }
    }

    public func unreadCount() async throws -> Int {
        try await database.reader.read { db in
            try ReadingItem.filter(Column("readAt") == nil).fetchCount(db)
        }
    }

    // MARK: - Editing

    /// Saves a link, or moves one that is already there back to the top as
    /// unread. A new title replaces the old one; without one, the old one
    /// stays. Throws `ReadingListError.notALink`.
    @discardableResult
    public func add(url text: String, title: String? = nil, sourceAppName: String? = nil, now: Date = .now) throws -> ReadingItem {
        guard let url = ReadingItem.normalizedURL(text) else { throw ReadingListError.notALink(text) }
        let title = ReadingItem.normalizedText(title)
        return try database.writer.write { db in
            if var item = try ReadingItem.filter(Column("url") == url).fetchOne(db) {
                item.title = title ?? item.title
                item.sourceAppName = sourceAppName ?? item.sourceAppName
                item.addedAt = now
                item.readAt = nil
                try item.update(db)
                return item
            }
            var item = ReadingItem(url: url, title: title, sourceAppName: sourceAppName, addedAt: now)
            try item.insert(db)
            return item
        }
    }

    /// Sets the title and the note; empty ones are removed.
    public func edit(id: Int64, title: String?, note: String?) throws {
        try database.writer.write { db in
            guard var item = try ReadingItem.fetchOne(db, key: id) else { return }
            item.title = ReadingItem.normalizedText(title)
            item.note = ReadingItem.normalizedText(note)
            try item.update(db)
        }
    }

    /// Marks a link read (at `date`) or unread. Marking a read link read
    /// again keeps its date.
    public func setRead(_ read: Bool, id: Int64, at date: Date = .now) throws {
        try database.writer.write { db in
            if read {
                try db.execute(
                    sql: "UPDATE readingItem SET readAt = ? WHERE id = ? AND readAt IS NULL", arguments: [date, id])
            } else {
                try db.execute(sql: "UPDATE readingItem SET readAt = NULL WHERE id = ?", arguments: [id])
            }
        }
    }

    /// Deletes a link here and, with sync on, on the other Mac.
    public func delete(id: Int64) throws {
        try database.writer.write { db in
            try SyncSchema.markReadingTombstones(where: "id = ?", arguments: [id], db: db)
            _ = try ReadingItem.deleteOne(db, key: id)
        }
    }

    /// Links read before this are purged under "Delete read links after
    /// `days` days"; nil for 0, which keeps them.
    public static func purgeCutoff(afterDays days: Int, now: Date = .now) -> Date? {
        days > 0 ? now.addingTimeInterval(-Double(days) * 86400) : nil
    }

    /// Deletes the links read before `date`. Local only: the other Mac keeps
    /// them until its own setting says otherwise (like the clip retention).
    @discardableResult
    public func purgeRead(before date: Date) throws -> Int {
        try database.writer.write { db in
            try ReadingItem.filter(Column("readAt") != nil && Column("readAt") < date).deleteAll(db)
        }
    }
}
