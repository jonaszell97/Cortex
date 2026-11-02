"""SQLite access for the sync server. All SQL lives here.

The server stores records it can't read: every payload and blob is sealed by the clients. It only
orders records by a sequence number and keeps the newest write per (collection, id).
"""

from collections.abc import Iterator, Sequence
from contextlib import contextmanager
from dataclasses import dataclass
import json
from pathlib import Path
import secrets
import sqlite3
import sys
import threading
from typing import Literal

SCHEMA = """
CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS record (
  collection  TEXT NOT NULL,
  id          TEXT NOT NULL,
  seq         INTEGER NOT NULL UNIQUE,
  modified_at INTEGER NOT NULL,
  device      TEXT NOT NULL,
  deleted     INTEGER NOT NULL,
  keep        INTEGER NOT NULL,
  blob_ids    TEXT NOT NULL,
  payload     BLOB,
  PRIMARY KEY (collection, id)
);
CREATE TABLE IF NOT EXISTS blob (
  id          TEXT PRIMARY KEY,
  data        BLOB NOT NULL,
  created_at  INTEGER NOT NULL
);
"""

RECORD_COLUMNS = "collection, id, seq, modified_at, device, deleted, keep, blob_ids, payload"


@dataclass(frozen=True)
class Record:
    collection: str
    id: str
    modified_at: int
    device: str
    deleted: bool
    keep: bool
    blob_ids: tuple[str, ...]
    payload: bytes | None
    seq: int = 0

    def same_write(self, other: "Record") -> bool:
        """Whether `other` is this exact write (a repeated push), ignoring `seq`."""
        return (
            self.modified_at == other.modified_at
            and self.device == other.device
            and self.deleted == other.deleted
            and self.keep == other.keep
            and self.blob_ids == other.blob_ids
            and self.payload == other.payload
        )


@dataclass(frozen=True)
class PushResult:
    collection: str
    id: str
    status: Literal["applied", "stale"]
    seq: int


def _record(row: sqlite3.Row) -> Record:
    return Record(
        collection=row["collection"],
        id=row["id"],
        seq=row["seq"],
        modified_at=row["modified_at"],
        device=row["device"],
        deleted=bool(row["deleted"]),
        keep=bool(row["keep"]),
        blob_ids=tuple(json.loads(row["blob_ids"])),
        payload=row["payload"],
    )


class Store:
    """One SQLite connection behind a lock. The server runs a single worker for two clients, so
    serializing every access costs nothing and keeps the transactions trivially correct."""

    def __init__(self, path: Path) -> None:
        self._lock = threading.Lock()
        self._db = sqlite3.connect(path, check_same_thread=False, isolation_level=None)
        self._db.row_factory = sqlite3.Row
        self._db.execute("PRAGMA journal_mode = WAL")
        # FULL, not NORMAL: losing the last commit on power loss would hand out a `seq` again
        # that a client has already seen.
        self._db.execute("PRAGMA synchronous = FULL")
        self._db.executescript(SCHEMA)
        with self._write() as db:
            db.execute(
                "INSERT OR IGNORE INTO meta (key, value) VALUES ('epoch', ?), ('next_seq', '1')",
                (secrets.token_hex(16),),
            )
            self._epoch = self._meta(db, "epoch")

    def close(self) -> None:
        with self._lock:
            self._db.close()

    @property
    def epoch(self) -> str:
        return self._epoch

    @contextmanager
    def _write(self) -> Iterator[sqlite3.Connection]:
        with self._lock:
            self._db.execute("BEGIN IMMEDIATE")
            try:
                yield self._db
            except BaseException:
                self._db.execute("ROLLBACK")
                raise
            self._db.execute("COMMIT")

    @staticmethod
    def _meta(db: sqlite3.Connection, key: str) -> str:
        return db.execute("SELECT value FROM meta WHERE key = ?", (key,)).fetchone()["value"]

    @staticmethod
    def _set_meta(db: sqlite3.Connection, key: str, value: str) -> None:
        db.execute("UPDATE meta SET value = ? WHERE key = ?", (value, key))

    def rotate_epoch(self) -> str:
        """Gives the database a new epoch, so both clients reset their cursor and upload again."""
        with self._write() as db:
            self._epoch = secrets.token_hex(16)
            self._set_meta(db, "epoch", self._epoch)
        return self._epoch

    def last_seq(self) -> int:
        with self._lock:
            return int(self._meta(self._db, "next_seq")) - 1

    # Records

    def push(self, records: Sequence[Record]) -> list[PushResult]:
        """Applies records in order, last writer wins by (modified_at, device), in one transaction.

        A record identical to the stored one is a repeated push: it answers `applied` with the
        stored `seq` and changes nothing. A record with the same (modified_at, device) but other
        content replaces the stored one; only the writing Mac can produce that key, and its latest
        push is its latest state.
        """
        results: list[PushResult] = []
        with self._write() as db:
            next_seq = int(self._meta(db, "next_seq"))
            for record in records:
                row = db.execute(
                    f"SELECT {RECORD_COLUMNS} FROM record WHERE collection = ? AND id = ?",
                    (record.collection, record.id),
                ).fetchone()
                if row is not None:
                    stored = _record(row)
                    new_key = (record.modified_at, record.device)
                    stored_key = (stored.modified_at, stored.device)
                    if new_key < stored_key:
                        results.append(
                            PushResult(record.collection, record.id, "stale", stored.seq)
                        )
                        continue
                    if record.same_write(stored):
                        results.append(
                            PushResult(record.collection, record.id, "applied", stored.seq)
                        )
                        continue
                # `seq` comes from the counter, never from MAX(seq) + 1: pruning can remove the
                # highest row, and a reused number would be skipped by a client already past it.
                seq = next_seq
                next_seq += 1
                db.execute(
                    f"""
                    INSERT INTO record ({RECORD_COLUMNS}) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT (collection, id) DO UPDATE SET
                      seq = excluded.seq,
                      modified_at = excluded.modified_at,
                      device = excluded.device,
                      deleted = excluded.deleted,
                      keep = excluded.keep,
                      blob_ids = excluded.blob_ids,
                      payload = excluded.payload
                    """,
                    (
                        record.collection,
                        record.id,
                        seq,
                        record.modified_at,
                        record.device,
                        int(record.deleted),
                        int(record.keep),
                        json.dumps(list(record.blob_ids)),
                        record.payload,
                    ),
                )
                results.append(PushResult(record.collection, record.id, "applied", seq))
            self._set_meta(db, "next_seq", str(next_seq))
        return results

    def changes(
        self, since: int, limit: int, max_bytes: int | None = None
    ) -> tuple[list[Record], bool]:
        """Records with `seq > since` in `seq` order, and whether more follow. The page also ends
        once its payloads reach `max_bytes`; it always holds at least one record."""
        records: list[Record] = []
        size = 0
        with self._lock:
            cursor = self._db.execute(
                f"SELECT {RECORD_COLUMNS} FROM record WHERE seq > ? ORDER BY seq LIMIT ?",
                (since, limit + 1),
            )
            # Row by row, so a page that stops early never loads the rest.
            for row in cursor:
                if len(records) == limit or (
                    max_bytes is not None and records and size >= max_bytes
                ):
                    cursor.close()
                    return records, True
                record = _record(row)
                records.append(record)
                size += len(record.payload or b"")
        return records, False

    def size_bytes(self) -> int:
        """The space the database file uses, without its free pages."""
        with self._lock:
            pages = self._db.execute("PRAGMA page_count").fetchone()[0]
            free = self._db.execute("PRAGMA freelist_count").fetchone()[0]
            page_size = self._db.execute("PRAGMA page_size").fetchone()[0]
        return int((pages - free) * page_size)

    # Blobs

    def missing_blobs(self, ids: Sequence[str]) -> list[str]:
        unique = list(dict.fromkeys(ids))
        if not unique:
            return []
        with self._lock:
            placeholders = ", ".join("?" * len(unique))
            rows = self._db.execute(
                f"SELECT id FROM blob WHERE id IN ({placeholders})", unique
            ).fetchall()
        present = {row["id"] for row in rows}
        return [blob_id for blob_id in unique if blob_id not in present]

    def put_blob(self, blob_id: str, data: bytes, now_ms: int) -> bool:
        """Stores a blob. Returns False, and changes nothing, if it already exists."""
        with self._write() as db:
            cursor = db.execute(
                "INSERT OR IGNORE INTO blob (id, data, created_at) VALUES (?, ?, ?)",
                (blob_id, data, now_ms),
            )
            return cursor.rowcount == 1

    def get_blob(self, blob_id: str) -> bytes | None:
        with self._lock:
            row = self._db.execute("SELECT data FROM blob WHERE id = ?", (blob_id,)).fetchone()
        return None if row is None else row["data"]

    # Pruning (the policy lives in prune.py)

    def prune_records(self, clip_before_ms: int, tombstone_before_ms: int) -> int:
        """Removes unpinned live clips written before `clip_before_ms`, and tombstones of any
        collection written before `tombstone_before_ms`."""
        with self._write() as db:
            cursor = db.execute(
                """
                DELETE FROM record
                WHERE (collection = 'clip' AND deleted = 0 AND keep = 0 AND modified_at < ?)
                   OR (deleted = 1 AND modified_at < ?)
                """,
                (clip_before_ms, tombstone_before_ms),
            )
            return cursor.rowcount

    def prune_blobs(self, created_before_ms: int) -> int:
        """Removes blobs that no record refers to and that were stored before
        `created_before_ms`."""
        with self._write() as db:
            cursor = db.execute(
                """
                DELETE FROM blob
                WHERE created_at < ?
                  AND id NOT IN (SELECT j.value FROM record, json_each(record.blob_ids) AS j)
                """,
                (created_before_ms,),
            )
            return cursor.rowcount


if __name__ == "__main__":
    # After restoring the database from a backup: `python -m app.store rotate-epoch <path>`.
    # The restored file still has the old epoch, but it would hand out `seq` numbers again that
    # the clients have already seen.
    if len(sys.argv) != 3 or sys.argv[1] != "rotate-epoch":
        sys.exit("usage: python -m app.store rotate-epoch /data/sync.sqlite")
    if not Path(sys.argv[2]).is_file():
        sys.exit(f"no database at {sys.argv[2]}")
    store = Store(Path(sys.argv[2]))
    print(f"new epoch: {store.rotate_epoch()}")
    store.close()
