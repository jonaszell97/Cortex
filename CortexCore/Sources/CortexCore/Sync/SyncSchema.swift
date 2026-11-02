import Foundation
import GRDB

/// The server's collections. `clip`, `snippet`, `action`, `reading`,
/// `knowledge` and `device` are also the `entity` values of `syncRecord`;
/// `meta` holds the key check.
public enum SyncCollection: String, Sendable, CaseIterable, Codable, DatabaseValueConvertible {
    case clip, snippet, action, reading, knowledge, device, meta
}

/// Change tracking for sync (docs/SYNC.md, "Client schema"): the `syncRecord`
/// table and the triggers that keep it current on every local write.
///
/// The triggers only upsert into `syncRecord`, which has no foreign keys and
/// no constraint besides the primary key they conflict on, so they can't make
/// a local write fail. They run whether sync is on or off.
enum SyncSchema {
    /// Milliseconds since 1970, from SQLite's clock.
    static let nowMs = "CAST(round((julianday('now') - 2440587.5) * 86400000) AS INTEGER)"

    /// The largest `modifiedAt` the server takes (2^53, exact as a JSON
    /// number). One past `Int64.max` would turn into a REAL in SQLite, which
    /// can't be read back as an integer.
    static let maxModifiedAt: Int64 = 1 << 53

    /// `expression`, capped at `maxModifiedAt`. Every computed local
    /// `modifiedAt` goes through this.
    static func capped(_ expression: String) -> String {
        "min(\(expression), \(maxModifiedAt))"
    }

    /// The upsert every local write ends in. A local write always gets a later
    /// `modifiedAt` than the version it replaces, even when that version came
    /// from a Mac whose clock runs ahead, so an edit made after seeing a
    /// remote change wins over it. `device` NULL means "written on this Mac".
    static func markLocalWrite(deleted: Bool) -> String {
        """
        ON CONFLICT (entity, localKey) DO UPDATE SET
          modifiedAt = \(capped("max(excluded.modifiedAt, syncRecord.modifiedAt + 1)")),
          pending = 1,
          deleted = \(deleted ? 1 : 0),
          device = NULL
        """
    }

    static func migrate(_ db: Database) throws {
        try db.execute(sql: """
            -- One row per synced record, written by the triggers below and by the sync engine.
            CREATE TABLE syncRecord (
              entity      TEXT NOT NULL,     -- 'clip' | 'snippet' | 'action'
              localKey    TEXT NOT NULL,     -- clip: contentHash, snippet: syncID, action: file name
              modifiedAt  INTEGER NOT NULL,  -- ms; last local write, or the remote write that was applied
              pending     INTEGER NOT NULL,  -- 1 = needs pushing
              deleted     INTEGER NOT NULL DEFAULT 0,
              device      TEXT,              -- writer of this version; NULL = this Mac
              fileHash    TEXT,              -- actions only: SHA-256 of the last synced content
              PRIMARY KEY (entity, localKey)
            );
            CREATE INDEX syncRecord_pending ON syncRecord(pending) WHERE pending = 1;

            -- Stable cross-Mac identity for snippets (local IDs are autoincrement).
            ALTER TABLE snippet ADD COLUMN syncID TEXT;
            UPDATE snippet SET syncID = lower(hex(randomblob(16)));
            CREATE UNIQUE INDEX snippet_syncID ON snippet(syncID);

            -- Existing data, so turning sync on is only "mark everything pending".
            INSERT INTO syncRecord (entity, localKey, modifiedAt, pending, deleted)
              SELECT 'clip', contentHash,
                     CAST(round((julianday(lastCopiedAt) - 2440587.5) * 86400000) AS INTEGER), 1, 0
              FROM clipItem;
            INSERT INTO syncRecord (entity, localKey, modifiedAt, pending, deleted)
              SELECT 'snippet', syncID,
                     CAST(round((julianday(updatedAt) - 2440587.5) * 86400000) AS INTEGER), 1, 0
              FROM snippet;

            INSERT INTO metadata (key, value) VALUES ('syncDeviceID', upper(hex(randomblob(16))));
            """)
        try db.execute(sql: triggers)
    }

    /// The triggers that keep `syncRecord` current. `v6_sync_capped` recreates
    /// them, so a change here also needs a migration that does that again.
    static let triggers = """
            -- Clips. Recording, bumping, pinning and pasting all fire; the derived
            -- columns (preview, search text, thumbnail) don't.
            CREATE TRIGGER clipItem_sync_insert AFTER INSERT ON clipItem BEGIN
              INSERT INTO syncRecord (entity, localKey, modifiedAt, pending, deleted)
                VALUES ('clip', NEW.contentHash, \(nowMs), 1, 0)
                \(markLocalWrite(deleted: false));
            END;

            CREATE TRIGGER clipItem_sync_update AFTER UPDATE OF lastCopiedAt, isPinned, isSensitive ON clipItem
            WHEN OLD.lastCopiedAt IS NOT NEW.lastCopiedAt
              OR OLD.isPinned IS NOT NEW.isPinned
              OR OLD.isSensitive IS NOT NEW.isSensitive
            BEGIN
              INSERT INTO syncRecord (entity, localKey, modifiedAt, pending, deleted)
                VALUES ('clip', NEW.contentHash, \(nowMs), 1, 0)
                \(markLocalWrite(deleted: false));
            END;

            -- Purges and Clear History leave nothing behind. An explicit delete's
            -- tombstone (deleted = 1, written first by ClipStore.delete(ids:)) survives.
            CREATE TRIGGER clipItem_sync_delete AFTER DELETE ON clipItem BEGIN
              DELETE FROM syncRecord WHERE entity = 'clip' AND localKey = OLD.contentHash AND deleted = 0;
            END;

            -- Snippets. One insert trigger assigns the syncID and records it, so the
            -- two steps can't run in the wrong order. Snippet and SnippetStore.save
            -- don't know the column. markUsed (usageCount, lastUsedAt) doesn't fire.
            -- The syncID checks keep a NULL localKey from ever failing a write.
            CREATE TRIGGER snippet_sync_insert AFTER INSERT ON snippet BEGIN
              UPDATE snippet SET syncID = lower(hex(randomblob(16))) WHERE id = NEW.id AND syncID IS NULL;
              INSERT INTO syncRecord (entity, localKey, modifiedAt, pending, deleted)
                SELECT 'snippet', syncID, \(nowMs), 1, 0 FROM snippet WHERE id = NEW.id
                \(markLocalWrite(deleted: false));
            END;

            CREATE TRIGGER snippet_sync_update AFTER UPDATE OF name, keyword, body, tags ON snippet
            WHEN NEW.syncID IS NOT NULL AND (
                 OLD.name IS NOT NEW.name
              OR OLD.keyword IS NOT NEW.keyword
              OR OLD.body IS NOT NEW.body
              OR OLD.tags IS NOT NEW.tags)
            BEGIN
              INSERT INTO syncRecord (entity, localKey, modifiedAt, pending, deleted)
                VALUES ('snippet', NEW.syncID, \(nowMs), 1, 0)
                \(markLocalWrite(deleted: false));
            END;

            CREATE TRIGGER snippet_sync_delete AFTER DELETE ON snippet WHEN OLD.syncID IS NOT NULL BEGIN
              INSERT INTO syncRecord (entity, localKey, modifiedAt, pending, deleted)
                VALUES ('snippet', OLD.syncID, \(nowMs), 1, 1)
                \(markLocalWrite(deleted: true));
            END;
            """

    /// `synced`: 1 once the server has taken a version of this record or this
    /// Mac received it from there. A snippet that was never synced may be
    /// adopted by a remote snippet of the same name (the first sync); one that
    /// was is a different snippet (docs/SYNC.md, "Handling per data type").
    /// `pending` can't tell the two apart, because every later edit sets it
    /// again.
    static func migrateSynced(_ db: Database) throws {
        try db.execute(sql: "ALTER TABLE syncRecord ADD COLUMN synced INTEGER NOT NULL DEFAULT 0")
    }

    /// Brings every `modifiedAt` back into `0...maxModifiedAt` as an integer,
    /// and recreates the triggers so local writes stay there (docs/SYNC.md,
    /// "Sealing and authenticated metadata"). Before, a remote record with
    /// `modifiedAt` near `Int64.max` was stored as is, and the next local write
    /// overflowed it into a REAL.
    static func migrateCapped(_ db: Database) throws {
        try db.execute(sql: """
            UPDATE syncRecord SET modifiedAt = \(maxModifiedAt) WHERE modifiedAt > \(maxModifiedAt);
            UPDATE syncRecord SET modifiedAt = 0 WHERE modifiedAt < 0;
            UPDATE syncRecord SET modifiedAt = CAST(modifiedAt AS INTEGER) WHERE typeof(modifiedAt) <> 'integer';

            DROP TRIGGER clipItem_sync_insert;
            DROP TRIGGER clipItem_sync_update;
            DROP TRIGGER clipItem_sync_delete;
            DROP TRIGGER snippet_sync_insert;
            DROP TRIGGER snippet_sync_update;
            DROP TRIGGER snippet_sync_delete;
            """)
        try db.execute(sql: triggers)
    }

    /// Protocol v2 binds each record's metadata into its seal and seals
    /// tombstones (docs/SYNC.md, "Sealing and authenticated metadata"). Every
    /// record goes out again, sealed the new way, under the `(modifiedAt,
    /// device)` it already has: the server replaces a record whose key is the
    /// same and whose content differs, so nothing wins or loses last-writer-wins
    /// because of the upgrade.
    static func migrateAuthenticated(_ db: Database) throws {
        try db.execute(sql: "UPDATE syncRecord SET pending = 1")
    }

    /// Reading list links (`v8_reading-list_items`), keyed by their URL, which
    /// never changes. Saving, editing and marking read fire; like clips, only
    /// an explicit delete leaves a tombstone (`markReadingTombstones`), so
    /// the local purge of read links stays on this Mac. Kept apart from
    /// `triggers`, which `v6_sync_capped` creates before this table exists.
    static func migrateReadingList(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TRIGGER readingItem_sync_insert AFTER INSERT ON readingItem BEGIN
              INSERT INTO syncRecord (entity, localKey, modifiedAt, pending, deleted)
                VALUES ('reading', NEW.url, \(nowMs), 1, 0)
                \(markLocalWrite(deleted: false));
            END;

            CREATE TRIGGER readingItem_sync_update AFTER UPDATE OF title, note, addedAt, readAt ON readingItem
            WHEN OLD.title IS NOT NEW.title
              OR OLD.note IS NOT NEW.note
              OR OLD.addedAt IS NOT NEW.addedAt
              OR OLD.readAt IS NOT NEW.readAt
            BEGIN
              INSERT INTO syncRecord (entity, localKey, modifiedAt, pending, deleted)
                VALUES ('reading', NEW.url, \(nowMs), 1, 0)
                \(markLocalWrite(deleted: false));
            END;

            CREATE TRIGGER readingItem_sync_delete AFTER DELETE ON readingItem BEGIN
              DELETE FROM syncRecord WHERE entity = 'reading' AND localKey = OLD.url AND deleted = 0;
            END;
            """)
    }

    /// Marks the links matching `condition` as explicitly deleted, before
    /// they are deleted in the same transaction (see `markClipTombstones`).
    static func markReadingTombstones(where condition: String, arguments: StatementArguments, db: Database) throws {
        try db.execute(sql: """
            INSERT INTO syncRecord (entity, localKey, modifiedAt, pending, deleted)
              SELECT 'reading', url, \(nowMs), 1, 1 FROM readingItem WHERE \(condition)
              \(markLocalWrite(deleted: true))
            """, arguments: arguments)
    }

    /// Marks the clips matching `condition` as explicitly deleted, before they
    /// are deleted in the same transaction. The tombstone travels to the other
    /// Mac; the delete trigger leaves it in place.
    static func markClipTombstones(where condition: String, arguments: StatementArguments, db: Database) throws {
        try db.execute(sql: """
            INSERT INTO syncRecord (entity, localKey, modifiedAt, pending, deleted)
              SELECT 'clip', contentHash, \(nowMs), 1, 1 FROM clipItem WHERE \(condition)
              \(markLocalWrite(deleted: true))
            """, arguments: arguments)
    }
}
