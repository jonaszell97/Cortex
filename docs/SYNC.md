# Sync

The reference for how Cortex syncs data between your Macs: what travels, how it is stored and encrypted, how the sync cycle resolves conflicts, and how the pieces map to code. For setting it up and using it, see [the Sync module doc](modules/SYNC.md). For running the server, see [`sync-server/README.md`](../sync-server/README.md).

Sync is optional and off by default. It copies records between the local databases of your Macs through a small server you run yourself. The server holds only encrypted records and cannot read them.

**The rule above everything else: each Mac stays a complete, local app.** Sync is a background add-on. If the server is down, the network is off, the key is wrong or the sync code has a bug, the palette, clipboard recording, pasting, snippets and actions behave as they do without sync. Each Mac holds a full copy of everything it has synced. The server is a mailbox, not the source of truth.

## Design rules

| Decision | Choice | Why |
| --- | --- | --- |
| Model | Each Mac keeps its own database. A cycle pulls the other Macs' changes, then pushes its own. Conflicts are resolved per record, last writer wins. | Eventual consistency is enough when the Macs are rarely used at the same moment. Nothing waits on the network. |
| Server | A small HTTP service with one SQLite file. It stores opaque encrypted records and hands them out by sequence number. | A server that knows nothing about clips or snippets is easy to get right, easy to move and safe to lose (see [The epoch](#the-epoch)). |
| Encryption | End to end. Every payload and blob is sealed with AES-GCM using a sync key that only your devices have (in their Keychains). Record IDs are HMACs. | Clips contain passwords and tokens. The server and its backups only ever hold ciphertext. |
| Auth | One bearer token, on top of whatever network restriction you put in front of the server. | The token keeps strangers from writing junk. Confidentiality comes from the sync key, not the token. |
| Change tracking | SQLite triggers write to a `syncRecord` table. The store methods stay as they are, apart from the explicit delete of a clip, a link or an action. | The triggers catch every write path (recording, palette, editor, importers, future code) without editing them. |
| Default | Off. The Sync module is switched on per Mac. | With sync off, the only difference is the triggers' bookkeeping rows. |

## What syncs and what stays local

| Data | Synced | Stays local | Conflict rule |
| --- | --- | --- | --- |
| Clips | Content (all stored representations), sensitive flag, pinned flag, source app, `createdAt`, `lastCopiedAt`, explicit deletes | `files` clips (paths are machine-specific), clips above the size cap (10 MB by default, 1 to 30 MB), sensitive clips unless switched on, retention purges, Clear History, the derived columns (preview, thumbnail, search text, recognized text: rebuilt on arrival) | The content never changes, because the record key is the content hash. `lastCopiedAt` takes the later value, `isSensitive` is OR-ed, `isPinned` goes to the newer write. |
| Snippets | Name, keyword, body, tags, created and updated dates, deletes | `usageCount`, `lastUsedAt` | Newer write wins. A name or keyword clash is resolved on arrival (see [Handling per data type](#handling-per-data-type)). |
| Reading list | Link, title, note, source app, `addedAt`, `readAt`, explicit deletes | Deleting read links after a number of days (each Mac's own setting) | Newer write wins the whole link. The record key is the normalized URL, so the same link saved on two Macs is one record. |
| Quick actions | Every `*.toml` file at the top level of `~/.config/cortex/actions/` (content and deletion) | Usage counts and remembered option values (UserDefaults), scripts or tools a command calls, files in subfolders | Newer write wins. The losing version is kept in `actions/.conflicts/`. |
| Knowledge base | Every file below `~/.config/cortex/knowledge/` at any depth, with its modification date, and deletes | The git history (each Mac keeps its own), hidden files and hidden folders (`.git/`, `.conflicts/`), files over 25 MB | Newer write wins. The losing version is kept in `knowledge/.conflicts/`. |
| Devices | One report per device: name, platform, system and Cortex version, build date, the collections it syncs with their payload versions, when it reported, changes it couldn't send, its last failure, whether it went to sleep; Macs also uptime, free disk, battery, host name and user | | Each device writes only its own report. Another device can delete one (*Forget*); the device's next report brings it back. |
| Settings | Nothing | Hotkeys, retention, ignore list, the option values of built-in actions | |

`$XDG_CONFIG_HOME/cortex/` is used instead of `~/.config/cortex/` when that variable is set.

Each collection has its own switch in Settings → Sync, on by default once sync is set up; the devices' reports have none. Synced action files are shell commands. Anyone who holds the sync key can plant one that runs on every paired Mac. Switch off "Your quick actions" if you do not want that.

### Sensitive clips

Sensitive clips (passwords and other clips flagged as sensitive) do not sync unless "Sensitive clips" is switched on in Settings → Sync, on both Macs. The setting applies in both directions: a sensitive clip that arrives while it is off is ignored and not stored. They are encrypted like everything else.

The size cap works the same way: an oversized clip stays local, and an oversized clip that arrives is ignored. Changing either setting so that more clips qualify marks the clips as pending again and pulls the older records again.

### Action options

Built-in actions can have options (`ActionOption`, for example the length, character and side of "Pad"). The palette remembers the values per action in UserDefaults (`quickActionOptions`, written by `ActionsService.setOptions`), and Shortcuts runs use them too. They do not sync.

- Options exist only on built-in actions. User-defined TOML actions have none, so the TOML format and `ActionFilePayload` do not carry them.
- The values are keyed by action ID and option ID, which are stable and defined in code ([ADDING_ACTIONS.md](ADDING_ACTIONS.md) says not to rename them). A remembered value is a per-Mac preference like the hotkeys, and nothing breaks when the Macs differ.
- The sync code never touches them. They are not in the database, so there is no trigger, no `syncRecord` row and no payload.

If syncing them is wanted later, they could travel as one `settings` record (a map of action ID to option values). That needs a new collection, so it is not done.

### Deletes

Deleting a single clip in the palette deletes it on the other Macs. The retention purge and Clear History stay local, so each Mac keeps its own retention without emptying the others. A clip that is deleted on one Mac and copied again later on another comes back, because the newer write wins. The same holds for reading list links: only deleting one link travels, not the purge of read links.

## Architecture

```
Mac A                                        Mac B
┌──────────────────────────┐                 ┌──────────────────────────┐
│ Cortex                   │                 │ Cortex                   │
│  ClipStore / SnippetStore│                 │  ClipStore / SnippetStore│
│     │ (triggers)         │                 │     │ (triggers)         │
│  syncRecord table        │                 │  syncRecord table        │
│     │                    │                 │     │                    │
│  SyncEngine (actor) ─────┼── HTTPS ──┐ ┌───┼── SyncEngine (actor)     │
│  SyncService (timer, UI) │           ▼ ▼   │  SyncService             │
└──────────────────────────┘      sync server └──────────────────────────┘
                              cortex-sync.example.dev
                              reverse proxy (TLS) → sync-server (FastAPI)
                              → /data/sync.sqlite (ciphertext only)
```

The platform-independent part is in `CortexCore/Sources/CortexCore/Sync/`:

| File | Contents |
| --- | --- |
| `SyncKey.swift` | `SyncKey` (key, HKDF subkeys, seal and open, HMAC record and blob IDs, key check), `SyncRecordHeader` (the authenticated metadata), `SyncPairing` (the pairing code) |
| `SyncSchema.swift` | `SyncCollection`, the `syncRecord` migrations and triggers |
| `SyncState.swift` | `SyncState`: device ID, cursor, epoch and the rest of the sync bookkeeping in the `metadata` table |
| `SyncTransport.swift` | Wire types (`SyncWireRecord`, `SyncChangesPage`, ...), the `SyncTransport` protocol, transport errors |
| `SyncAPI.swift` | The `URLSession` client of the server |
| `SyncSetup.swift` | `SyncSetup` (checking the address, the first device, joining), `SyncCredentials` (server, token and key, kept in the Keychain), `SyncSetupError` |
| `SyncStatus.swift` | `SyncStatus`, `SyncFailure` (the status texts), `SyncBackoff` |
| `SyncEntityHandler.swift` | `SyncEntityHandler`: what the engine needs from each kind of data |
| `SyncPayloads.swift` | `ClipPayload`, `SnippetPayload`, `ReadingItemPayload`, `ActionFilePayload`, `KnowledgeFilePayload` (Codable, versioned) |
| `SyncEngine.swift` | `SyncEngine`: an actor that runs one cycle at a time |
| `SyncChangeWaiter.swift` | `SyncChangeWaiter`: waits on the server for other devices' changes between cycles |

The handlers sit next to the data they handle:

| File | Handler |
| --- | --- |
| `Clipboard/ClipStore+Sync.swift` | `ClipSyncHandler`: payload building, filters, merge |
| `Snippets/SnippetStore+Sync.swift` | `SnippetSyncHandler`: adoption, name and keyword clash rules |
| `ReadingList/ReadingListStore+Sync.swift` | `ReadingListSyncHandler` |
| `Actions/ActionFileSync.swift` | `ActionFileSync`: scan, write and delete TOML files |
| `Knowledge/KnowledgeFileSync.swift` | `KnowledgeFileSync`: the same for the knowledge folder tree |
| `Sync/SyncDevices.swift` | `DeviceSyncHandler`: this device's report and the others' |

The app side is the Sync module, `Cortex/Modules/Sync/`:

| File | Contents |
| --- | --- |
| `SyncModule.swift` | The module: switch, status menu line, palette-open trigger |
| `SyncAPI.swift` | `SyncContributing` and `SyncContribution`: what the other modules hand to sync |
| `SyncService.swift` | `SyncService` (`@MainActor`): scheduling, triggers, status, setup, pairing |
| `SyncSettings.swift` | UserDefaults-backed settings: the server URL and one switch per collection |
| `SyncSettingsView.swift` | The Sync page in Settings |

The iPhone has no modules: `CortexMobile/Sync/MobileSyncService.swift` runs the same engine with the knowledge, reading list and device handlers, on the iPhone's own triggers (launch, foreground, pull to refresh, network change, local changes, a push before going to the background), and waits for the other devices' changes while the app is in front. See [plans/IOS.md](../plans/IOS.md).

Sync names no other module. Clipboard, Snippets, Reading List, Quick Actions and Knowledge each conform to `SyncContributing` and return a `SyncContribution` from their `…Module.swift` (`syncContribution(for:)`). A contribution carries the collection, the handler factory, the switch title and key (such as `syncClips`), the options shown under the switch (the sensitive-clip toggle and the size cap are Clipboard's), a folder to watch, what to await before the first cycle and what to reload after remote changes. Sync asks the active modules for their contributions whenever it needs them. A module that is switched off is neither sent nor applied. For how modules are built, see [ADDING_A_MODULE.md](ADDING_A_MODULE.md).

`QuickActionService` and the knowledge index know nothing about sync. Sync writes files into their folders, and their `DirectoryWatcher`s reload them.

## Server API

The server is `sync-server/` (Python, FastAPI, one SQLite file). All endpoints except `/v1/health` need `Authorization: Bearer <token>`, compared in constant time. A missing or wrong token gets 401 with `WWW-Authenticate: Bearer`. Bodies are JSON, except blob bodies, which are raw bytes. Every response carries the epoch (see [The epoch](#the-epoch)): the `X-Sync-Epoch` header on all of them, and an `epoch` field in the body of JSON responses.

| Endpoint | Does |
| --- | --- |
| `GET /v1/health` | `{"status": "ok", "epoch": "…", "maxWait": 60}`. No auth. Used by container health checks, the app's "Test Connection" and every cycle. `maxWait` says that `/v1/changes` can wait, and for how many seconds at most; a server without it can't. |
| `GET /v1/changes?since=<seq>&limit=200&wait=0` | Records with `seq > since`, ordered by `seq`. Returns `{records, cursor, more, epoch}`. `limit` is 1 to 1000. A page also ends once it holds 8 MB of payloads (it always holds at least one record). `cursor` is the last returned `seq`, or `since` for an empty page. With `wait` (1 to 60 seconds), the server holds the answer while it has nothing after `since`, until a push stores something or the time is up (then the page is empty). See [Waiting for changes](#waiting-for-changes). |
| `POST /v1/push` | `{device, records: [...]}`. Returns `{results: [{collection, id, status, seq}], epoch}` with `status` of `applied` or `stale` (the server already has a newer write). Idempotent. |
| `POST /v1/blobs/missing` | `{ids: [...]}` → `{missing: [...], epoch}`, in request order, without duplicates. Lets the client upload only what is new. |
| `PUT /v1/blobs/{id}` | Stores a blob (raw bytes). Answers `{stored: true\|false, epoch}`; `false` means it already existed and nothing changed. |
| `GET /v1/blobs/{id}` | The blob bytes, or 404. |

A record as the server sees it:

```json
{
  "collection": "clip",            // clip | snippet | action | reading | knowledge | device | meta
  "id": "3f9c…",                   // HMAC, 32 hex chars, opaque
  "modifiedAt": 1792483200123,     // ms since 1970, set by the writing Mac
  "device": "8C1D…",               // the writing Mac's random device ID
  "deleted": false,                // tombstone: the payload is a sealed {"v":2,"deleted":true}
  "keep": false,                   // exempt from server pruning (pinned clips)
  "blobs": ["a17e…"],              // blob IDs the payload refers to (for garbage collection)
  "payload": "<base64 AES-GCM>"    // standard base64 with padding
}
```

Pulled records also carry `seq`.

The server checks every request before it writes anything. A bad record rejects the whole push.

| Field | Rule |
| --- | --- |
| `collection` | One of `clip`, `snippet`, `action`, `reading`, `knowledge`, `device`, `meta`. Clients pass over records of a collection they don't know, so a new one needs only the server updated first. |
| Record `id` | Exactly 32 lowercase hex characters. |
| Blob `id` | 32 to 64 lowercase hex characters. |
| `device` | `[A-Za-z0-9._-]`, 1 to 64 characters. |
| `modifiedAt` | An integer from 0 to 2^53, and at most a day ahead of the server's clock. |
| `payload` | Required, except on a tombstone. A tombstone may carry a payload of up to 1 KB (the sealed tombstone); v1 builds sent none. |
| Batch sizes | At most 500 records per push and 1000 blob IDs per request. |

Errors are FastAPI's `{detail}` with 401, 404, 413, 422 or 507. A 422 never echoes its input, so it cannot leak a payload. `/docs` and the OpenAPI schema are off. The server logs request lines, counts and timings, never payloads or blobs.

The server checks the collection name, so a server that predates a collection answers 422 to a push that contains it. When a collection is added, update the server before the app. The client copes with a 422 by splitting the batch and giving up on the refused record for that cycle, but nothing in that collection syncs until the server knows it.

## Server storage

```sql
CREATE TABLE meta   (key TEXT PRIMARY KEY, value TEXT NOT NULL);  -- epoch, next_seq
CREATE TABLE record (
  collection  TEXT NOT NULL,
  id          TEXT NOT NULL,
  seq         INTEGER NOT NULL UNIQUE,
  modified_at INTEGER NOT NULL,
  device      TEXT NOT NULL,
  deleted     INTEGER NOT NULL,
  keep        INTEGER NOT NULL,
  blob_ids    TEXT NOT NULL,          -- JSON array
  payload     BLOB,
  PRIMARY KEY (collection, id)
);
CREATE TABLE blob   (id TEXT PRIMARY KEY, data BLOB NOT NULL, created_at INTEGER NOT NULL);
```

- One SQLite file, `sync.sqlite` in `DATA_DIR` (`/data` in the container). WAL mode, `synchronous = FULL` so a power loss cannot hand out a `seq` twice, one connection behind a lock, and one uvicorn worker. Each push runs in one `BEGIN IMMEDIATE` transaction. With a few clients there is no concurrency to worry about.
- **Push rule (server-side last writer wins).** A record replaces the stored one only if `(modifiedAt, device)` is greater, comparing the device IDs as strings when `modifiedAt` ties. Otherwise the answer is `stale`, with the stored record's `seq`. Re-sending a record that was already applied matches the stored one exactly, so the answer is `applied` again with the same `seq`. A push that dies halfway is safe to repeat. A record with the same `(modifiedAt, device)` but different content (one Mac writing twice within a millisecond) replaces the stored one with a new `seq`.
- **`seq` comes from a counter in `meta`** that only ever increases. It is never `MAX(seq) + 1`: pruning could remove the highest row, and a reused number would be skipped by a client whose cursor is already past it.
- Blobs are keyed by ID, stored once, and never overwritten.

## The epoch

`meta.epoch` is a random ID created with the database. Clients store it. If the server's epoch changes (database lost, restored from an older backup, or moved to another host), the client resets its cursor to 0 and marks all its records for upload, tombstones included. The new server then fills up again from the Macs. Without this, a restored server would hand out `seq` numbers the clients think they already have.

A backup restore keeps the old epoch but hands out `seq` numbers again, so the server has two guards:

- When a client asks for changes past the last `seq` the database has handed out, the server rotates its epoch itself and answers an empty page with `cursor: 0` and the new epoch.
- `python -m app.store rotate-epoch /data/sync.sqlite` does it by hand after a restore (see [`sync-server/README.md`](../sync-server/README.md)).

The client checks the epoch on every response, not only on `/v1/health`, because the server can rotate during a pull. The first cycle on a Mac only stores the epoch.

## Limits and pruning

| Limit | Default | Where |
| --- | --- | --- |
| Sealed payload of one record | 4 MB (413) | fixed |
| Blob upload | 32 MB (413) | `MAX_BLOB_MB` |
| JSON request body | 32 MB (413) | `MAX_JSON_MB` |
| Database size | 2048 MB: pushes and blob uploads get 507, deletions still go through | `MAX_STORAGE_MB` |
| Page of `/v1/changes` | 8 MB of payloads | fixed |
| Clip records kept on the server | 60 days for unpinned clips | `PRUNE_CLIP_DAYS` |

The other environment variables are `SYNC_TOKEN` (required, at least 16 characters) and `DATA_DIR`. See [`sync-server/README.md`](../sync-server/README.md).

**Pruning** runs at startup and then daily. It removes:

- unpinned live clip records whose `modifiedAt` is older than `PRUNE_CLIP_DAYS` (records with `keep` set, which are the pinned clips, stay),
- tombstones of any collection older than 180 days,
- blobs that no record references and that are more than a day old (the day covers blobs uploaded just before their record).

Live snippet, action, reading, knowledge, device and `meta` records are never pruned. Pruning only removes rows from the server. Clients never treat a pruned record as a delete, and both Macs keep their own copy.

The client has matching limits. It sends push batches of at most 50 records and about 8 MB, reads pages of 200 records, refuses JSON answers over 64 MB and blob downloads over the server's 32 MB, and keeps action files to 64 KB, knowledge files to 25 MB and the clip size cap at most 30 MB.

## Deployment

Run `sync-server/` anywhere your Macs can reach it. It needs a TLS reverse proxy in front, and it should be reachable only from your own devices (a VPN or Tailnet is one way). The token is the only access control the server has, and it has no rate limiting.

With Docker Compose:

```sh
cd sync-server
SYNC_TOKEN=$(openssl rand -hex 32) docker compose -f compose-example.yaml up -d
```

`compose-example.yaml` builds the image, keeps the data in a named volume (`sync-data`, mounted at `/data`) and has a health check on `/v1/health`. The container speaks plain HTTP on port 8000 and only exposes it to other containers, so point your reverse proxy at it (or add a `ports:` entry).

Without Docker:

```sh
cd sync-server
uv sync
SYNC_TOKEN=$(openssl rand -hex 32) DATA_DIR=./data uv run uvicorn app.main:app --host 127.0.0.1 --port 8787
```

Then put a TLS proxy in front of it, such as Caddy or nginx, or `tailscale serve` on a Tailnet. The app uses the server address as given and adds `https://` if there is no scheme. Plain `http://` works but sends the token unencrypted. The content stays sealed either way.

Check it from each Mac with `curl https://cortex-sync.example.dev/v1/health`. From outside your network the same request should fail.

The server is safe to lose: both Macs hold everything. Backing up `sync.sqlite` is optional. After restoring a backup, rotate the epoch as described in [The epoch](#the-epoch). To move to another server, start the new one, then use Disconnect on every Mac, set up the first Mac against the new address and join the others with its new pairing code. Local data stays. Arriving records merge with it by content hash (clips), `syncID` (snippets) and key (the rest).

## Client schema

Migration `v4_sync` (`SyncSchema.migrate`) creates the bookkeeping table and the triggers. Later migrations extend it: `v5_sync_synced` adds `synced`, `v6_sync_capped` caps stored times and recreates the triggers, `v7_sync_authenticated` marks everything pending for the move to protocol v2, `v8_reading-list_items` adds the reading list triggers (`SyncSchema.migrateReadingList`), and `v10_sync_devices` adds the `syncDevice` table (each device's last report, as the JSON payload it arrived as, keyed by device ID; no triggers).

```sql
-- One row per synced record. Written by triggers on local changes and by the engine.
CREATE TABLE syncRecord (
  entity      TEXT NOT NULL,     -- 'clip' | 'snippet' | 'action' | 'reading' | 'knowledge' | 'device' | 'meta'
  localKey    TEXT NOT NULL,     -- clip: contentHash, snippet: syncID, action: file name,
                                 -- reading: normalized URL, knowledge: relative path,
                                 -- device: device ID, meta: 'keycheck'
  modifiedAt  INTEGER NOT NULL,  -- ms; last local write, or the remote write that was applied
  pending     INTEGER NOT NULL,  -- 1 = needs pushing
  deleted     INTEGER NOT NULL DEFAULT 0,
  device      TEXT,              -- writer of this version; NULL = this Mac
  fileHash    TEXT,              -- actions and knowledge files: SHA-256 of the last synced content
  synced      INTEGER NOT NULL DEFAULT 0,  -- 1 once the server took a version or sent one
  PRIMARY KEY (entity, localKey)
);
CREATE INDEX syncRecord_pending ON syncRecord(pending) WHERE pending = 1;

-- Stable cross-Mac identity for snippets (local IDs are autoincrement).
ALTER TABLE snippet ADD COLUMN syncID TEXT;   -- unique index snippet_syncID
```

The migration backfills one pending row per existing clip and snippet, and gives existing snippets a `syncID`. Turning sync on is then only "mark everything pending". `syncRecord.device` is NULL for this Mac's own writes, so the triggers do not need the device ID. After applying a remote record, the engine sets it to the remote device.

The `metadata` table holds the rest of the state (`SyncState`): `syncDeviceID` (random, created by the migration), `syncCursor`, `syncEpoch`, `syncLastSuccess`, `syncConfirmedKey`, `syncUnopened` and `syncCollections`. They live in the database so the cursor advances in the same transaction as the page it was read with.

### Triggers

| Trigger | Fires on | Does |
| --- | --- | --- |
| `clipItem_sync_insert` | `AFTER INSERT ON clipItem` | Upserts `('clip', contentHash, now, pending = 1, deleted = 0, device = NULL)`. |
| `clipItem_sync_update` | `AFTER UPDATE OF lastCopiedAt, isPinned, isSensitive ON clipItem`, when one of them changed | The same upsert. |
| `clipItem_sync_delete` | `AFTER DELETE ON clipItem` | Deletes the row if it is not a tombstone. Purges and Clear History leave nothing behind. An explicit delete writes its tombstone first (`ClipStore.delete(ids:)` calls `SyncSchema.markClipTombstones` in the same transaction), and that survives. |
| `snippet_sync_insert` | `AFTER INSERT ON snippet` | Assigns `syncID = lower(hex(randomblob(16)))` if it is NULL, then upserts. One trigger, so the two steps cannot run in the wrong order, and `Snippet` and `SnippetStore.save` need no changes. |
| `snippet_sync_update` | `AFTER UPDATE OF name, keyword, body, tags`, when changed | Upsert. `markUsed` touches only `usageCount` and `lastUsedAt` and does not fire. |
| `snippet_sync_delete` | `AFTER DELETE ON snippet` | Upsert with `deleted = 1`. |
| `readingItem_sync_insert` / `_update` / `_delete` | Insert, update of title, note, `addedAt`, `readAt`, delete | Like clips: only `ReadingListStore.delete(id:)` leaves a tombstone (`markReadingTombstones`). |

Actions and knowledge files have no triggers, because they are not in the database. The engine scans their folders at the start of each cycle.

Every upsert ends in `SyncSchema.markLocalWrite`: `modifiedAt = max(now, old + 1)`, capped at 2^53, `pending = 1`, `device = NULL`. A local write always gets a later `modifiedAt` than the version it replaces, even when that version came from a Mac whose clock runs ahead. Without that, an edit made right after applying such a change would answer `stale` and be lost. It also keeps two writes in the same millisecond apart, which the rule "clear `pending` only for the pushed `modifiedAt`" depends on.

The triggers are safe for the local app. They only upsert into a table with no foreign keys and no unique constraint besides the primary key they conflict on (`ON CONFLICT DO UPDATE`), and the snippet triggers skip a NULL `syncID`, so they cannot make a local write fail. With sync off, they still keep `syncRecord` current: one small row per clip, snippet and link. This keeps the schema the same whether sync is on or off.

## Keys and pairing

- **Sync key:** 32 random bytes, generated when sync is first set up on one Mac and stored in the Keychain (service `dev.jonaszell.cortex`, account `sync-key`). The bearer token goes in account `sync-token`. Neither goes to UserDefaults or the database. The server URL is not secret and is in UserDefaults (`syncServerURL`).
- **Subkeys** come from HKDF-SHA256 over the sync key, like `BlobStore`'s: the info string `"cortex sync payload v1"` gives the AES-GCM key and `"cortex sync id v1"` the HMAC-SHA256 key. The info strings are part of the keys, so changing one makes every record on the server unreadable. They stay `v1` in protocol v2.
- **Record ID** is the first 32 hex characters of `HMAC(idKey, collection + "\0" + localKey)`. The server cannot link a record ID to content. A plain content hash of a short password would be guessable. Because the ID does not depend on the Mac, the same clip copied on two Macs is one record.
- **Blob ID** is the first 32 hex characters of `HMAC(idKey, "blob\0" + SHA256(plaintext))`. It deduplicates and is stable across Macs.
- **Key check.** Setting up pushes a `meta` record (local key `keycheck`) that holds a sealed constant. Joining from another Mac decrypts it first, so a wrong key fails at setup with a clear message instead of on every record later. `SyncEngine.verifyKey()` scans the server for the first `meta` record without changing local state and answers `matches`, `mismatch` or `notFound`. A key check sealed by protocol v1 still counts, because its contents are fixed.
- **Pairing code.** Settings → Sync → "Show Pairing Code…" shows it as a QR code, for the iPhone's camera; "Copy Pairing Code" puts `cxsync1:<base64url({"u": url, "t": token, "k": key})>` on the pasteboard. `k` is standard base64 inside the JSON, and the whole JSON (sorted keys) is base64url without padding. The code is written with the type `org.nspasteboard.ConcealedType`, so Cortex records it as a sensitive clip and masks it. On another Mac, "Join with pairing code" takes it. Only `http` and `https` URLs with a host and a non-empty token are accepted, and every parse failure is the same "This isn't a Cortex pairing code." The code holds the sync key: move it over AirDrop or Universal Clipboard, never through a chat or mail service.
- **First Mac versus joining.** `SyncService.setUp` generates a key and refuses a server that already holds a key check (`serverHoldsOtherData`), because the new key could not open its data. `SyncService.join` needs `matches` (`mismatch` is "Sync key doesn't match", `notFound` is "set up the first Mac first"). Nothing is stored in the Keychain if a check fails.

Losing the key on every Mac does not lose data: the local databases are untouched. Disconnect, empty the server's database (a new epoch) and set up again with a new key.

## Sealing and authenticated metadata

Protocol v2 seals every payload with AES-GCM and binds everything the server keeps in the clear into the authentication data:

```
AAD = "v2/" + collection + "/" + id + "/" + modifiedAt + "/" + device + "/" + deleted
```

`deleted` is `true` or `false`. `SyncRecordHeader.aad` builds the string, and `SyncKey.seal(_:for:)` and `SyncKey.open(_:for:)` take the header. The fields are separated by `/`, which none of them can contain.

**Why.** The first protocol authenticated only `collection + "/" + id`. The record's payload was sealed, but its `modifiedAt`, `device` and tombstone flag were plain text, and a tombstone had no payload at all. So confidentiality depended on the sync key, while integrity depended only on the bearer token, and the token is held in more places than the key (the server's environment, its backups, every pairing code, the server operator). Whoever held only the token, or the server itself, could:

- push a tombstone with a far-future `modifiedAt` for every record ID. The tombstones would win last-writer-wins and delete every synced item on every Mac, and the record would be locked, because later real writes would answer `stale`,
- re-serve an old sealed payload with a fresh `modifiedAt`, which still opened, and bring back old snippet text or an old action command,
- push junk that failed to open and stop the pull for good.

Binding the metadata into the AAD closes these. A payload cannot be moved to another record, restamped to win, or turned into a tombstone, because the changed header no longer opens. Tombstones are sealed too: their payload is `seal({"v":2,"deleted":true})`, so only a Mac with the key can delete. The server stays dumb. It stores the same fields, and the clients do the new checks.

Two details follow:

- `keep` and `blobs` stay outside the AAD. `keep` only steers server pruning, and the blob IDs a record uses are also inside its sealed payload.
- Blob bytes are sealed with the blob ID as AAD. The ID is a MAC of the content, and records name their blobs inside the sealed payload, so blobs need no metadata.

A related hardening: a remote `modifiedAt` outside `0…2^53` or more than a day ahead of this Mac's clock is skipped, and so is one the server would refuse (see [Server API](#server-api)). Every computed local `modifiedAt` is capped at 2^53 as well. Without that, one record stamped at the far end of the range would win every comparison from then on, and a later local write could overflow it into a non-integer in SQLite.

What a token holder can still do: withhold or delete records on the server, push junk (it stops the pull for a few cycles per record, see [Applying remote records](#applying-remote-records)), and replay a genuine old write with its original metadata. That replay only wins on a Mac that never saw the newer write, for example after an epoch reset and before the other Mac has uploaded again.

## The sync cycle

`SyncEngine` is an actor that runs at most one cycle at a time. `runCycle` chains onto the one in flight. `SyncService` builds a new engine for every cycle (the engine keeps no state between cycles) so the current key, switches and settings always apply. The cursor, epoch and `pending` flags are in the database.

A cycle has these steps:

1. **Health.** `GET /v1/health` with a 5 s timeout. If it fails, the cycle ends here: the status becomes "server unreachable" and the backoff starts. Nothing local is touched.
2. **Epoch check.** If the epoch differs from the stored one, reset the cursor to 0, set `pending = 1` on every `syncRecord` row (tombstones too), queue the key check and store the new epoch. The same happens when any later response carries a different epoch, and the cycle then starts over, at most three times before it fails with "the sync server keeps changing its identity". A Mac with no stored epoch only stores it.
3. **Collections.** The cursor only speaks for the collections that had a handler while it advanced, because the pull passes over records of others. `syncCollections` keeps that set. When a collection joins it (a module or switch was turned on), the cursor goes back to 0 so the older records are pulled after all. Last-writer-wins skips what is already here. A collection that is switched off drops out of the set.
4. **Scan files.** Each handler's `beforeCycle` runs. `ActionFileSync` and `KnowledgeFileSync` hash their files. A new or changed hash becomes an upsert with `pending = 1`, stamped with the file's modification date (capped at now) so the edit that was made last wins even if this Mac only notices it later. A file that is gone becomes a tombstone. A file that is too large or not UTF-8 (actions) stays local and does not count as deleted. A failing scan is logged and does not end the cycle.
5. **Pull.** `GET /v1/changes?since=cursor` in pages of 200. Each page is applied in **one short write transaction**, and the cursor advances in the same transaction, so a crash can only replay a page and never skip one. Repeat while `more`. See [Applying remote records](#applying-remote-records).
6. **Push.** Read up to 50 `pending` rows (the key check first, then oldest first) and build their payloads, reading blobs from the local `BlobStore`. The handlers apply the filters. `POST /v1/blobs/missing` says which blobs the server lacks, those are uploaded, and then `POST /v1/push` sends the records. Blobs go before the records that refer to them, so a record never points at a blob that is not there. For each `applied` or `stale` answer: `UPDATE syncRecord SET pending = 0 WHERE … AND modifiedAt = <value that was pushed>`. An edit made during the push keeps `pending = 1` and goes out in the same cycle. Repeat until nothing is pending.
7. **Stale answers.** If the server answered `stale` for any record, it holds a newer write. The cycle pulls once more so that write arrives now instead of at the next cycle.
8. **Done.** Store `syncLastSuccess`. If anything was applied, `onRemoteChanges` runs (also when a cycle fails after it applied something), and the app reloads what shows the data.

Records that the filters exclude (a `files` clip, an oversized clip, a sensitive clip with sensitive sync off) get `pending = 0` without being pushed, and `synced` stays as it was. Changing a filter so more records qualify marks the affected rows pending again (`AppDatabase.restartSync(for:)`).

Push details:

- A batch stops growing at 50 records or about 8 MB of payloads and blobs, whichever comes first.
- On a 413 or 422, the batch is halved to find the refused record. A single refused record stays pending and is skipped for the rest of the cycle. A blob the server refuses as too large only gives up the records that use it.
- A row whose payload cannot be built is skipped for the cycle, so nothing loops.
- `SyncMode.pushOnly` skips the pull. It is used before sleep.

**Enabling sync** on a Mac with existing data does the health check and epoch check, then marks every row pending (`AppDatabase.markEverythingPending()`). The first push uploads the whole history in batches, in the background. On another Mac, the same clips have the same content hash and therefore the same record ID, so they merge instead of duplicating. Snippets with the same name are adopted (see [Handling per data type](#handling-per-data-type)).

## Applying remote records

Every applied record follows one rule: compare `(remote.modifiedAt, remote.device)` with the local `(syncRecord.modifiedAt, syncRecord.device ?? this Mac's device ID)` and apply only if the remote write is newer. A later `modifiedAt` wins, and on a tie the greater device ID (compared as UTF-8 bytes), the same tie-break as the server. `SyncEngine.isNewer` implements it. After applying, the row becomes `(modifiedAt = remote, device = remote, pending = 0, synced = 1)` in the same transaction. This also cancels the `pending = 1` that the data write's triggers left, so applied changes never echo back to the server.

A page is processed in two stages. First every record is opened and prepared outside the transaction: decrypted, checked, its blobs downloaded and decrypted. Then all of them are written in one short transaction together with the cursor. Each record runs in its own savepoint, so a record that fails undoes only itself.

Rules, in the order a record meets them:

- **Records of a collection without a handler** (one this build does not know, or whose module or switch is off) are passed over, and the cursor moves on. See "Collections" in [The sync cycle](#the-sync-cycle) for how they are pulled later.
- **Every record is opened before last-writer-wins**, tombstones included, with its metadata as AAD. Only then are its `modifiedAt`, `device` and `deleted` trusted. A tombstone whose opened payload is not the tombstone constant is skipped.
- **The record key must match.** The local key the handler decodes from the payload must hash to the record's ID, or the record is skipped. A clip's content must hash to its key.
- **Records that fail to open** (or whose blob does) stop the pull without advancing the cursor, and the status shows "Sync key doesn't match". Until some record has opened with this key, that is final: a stuck cursor is better than silently skipping data. Once one has (`syncConfirmedKey` in `metadata`), a record that does not open is junk from whoever holds the token. It stops the pull for 3 cycles (`syncUnopened` counts them per record and write) and is then skipped, so it cannot hold the cursor for good. Junk in place of the key check is skipped the same way, and the Mac queues its own key check again.
- **Records sealed by protocol v1** (they open with the v1 AAD) and v1 tombstones without a payload are skipped and do not stop the pull, because their metadata is not authenticated. Migration `v7_sync_authenticated` marks every row pending, so each Mac uploads all its records again as v2 under their existing `(modifiedAt, device)`. The server replaces a record whose key is the same and whose content differs, so the upgrade changes no winner. A v1 build that pulls a v2 record reports "Sync key doesn't match" until it is updated, so update all Macs.
- **Unknown payload versions** (`v` higher than the handler's `supportedVersion`) stop the pull with the status "Update Cortex on this Mac".
- **Out-of-range times.** A `modifiedAt` below 0, above 2^53, or more than a day ahead of this Mac's clock is skipped.
- **A failing apply of one record** (for example a snippet that fails validation) is logged with the record ID, skipped, and does not stop the page. The next edit on the other Mac sends it again.
- **Last-writer-wins.** If the local write is newer, the handler's `superseded` hook runs instead of `apply` (clips delete the blobs they downloaded, action and knowledge files keep the losing version in `.conflicts/`).

A handler's `apply` answers with one of three outcomes:

| Outcome | Meaning |
| --- | --- |
| `.applied` | Stored as the remote record says. |
| `.mergedLocally` | Stored, but the result differs from the remote record (a clip with a later local `lastCopiedAt`, a snippet that lost its keyword to a clash). The engine writes the row as a new local write, `modifiedAt = max(now, remote + 1)` and `pending = 1`, so it goes out and the other Mac converges. |
| `.ignored` | Not stored, and nothing is recorded (for example a clip that local retention would purge right away). |

A tombstone has no payload to read the local key from, so the engine computes the record IDs of the entity's local `syncRecord` rows and looks the ID up there. A tombstone for a record this Mac never had is ignored.

## Handling per data type

Each handler implements `SyncEntityHandler`: `outgoing` (the payload and blobs for a pending row, or nil if filtered), `prepare` (decode a payload and fetch its blobs, outside the transaction), `applyDeletion`, `beforeCycle` and `supportedVersion`. Every payload has a top-level `v`. Adding an optional field needs no new `v`; changing the meaning of a field does.

### Clips

`ClipStore.prepareRemote` and `ClipStore.merge` in `ClipStore+Sync.swift`.

- **Unknown content hash:** insert through the same code as local recording (`makeItem`, blob writing, `indexSensitive` from local settings), with `createdAt`, `lastCopiedAt`, `isPinned` and source app from the payload. Blobs are downloaded and decrypted first, outside the transaction, and then written to the local `BlobStore` with the local key. The clip is not stored if it is sensitive and sensitive sync is off, if it is over the size cap, or if local retention would purge it right away (unpinned and older than `maxAge`, or sensitive and older than `sensitiveMaxAge`). The derived columns are rebuilt locally. The content must hash to the payload's `contentHash`.
- **Known content hash:** `lastCopiedAt = max(local, remote)`, `isSensitive = local || remote`, `isPinned = remote`. This costs no download. If the result differs from the payload, the outcome is `.mergedLocally`.
- **Tombstone:** delete the clip, and its blob files after the commit, if the remote write is newer. A clip that was copied again locally after the remote delete stays and is pushed again.
- **`ClipPayload` v1:** `contentHash, kind, representations [{type, data | blob, size}], plainText, isSensitive, isPinned, sourceBundleID, sourceAppName, createdAt, lastCopiedAt`. Representations go inline up to `ClipStore.inlineLimit` (256 KB). Images and larger ones go as blobs, mirroring local storage. `keep` is set for pinned clips.

### Snippets

`SnippetStore.applyRemote` in `SnippetStore+Sync.swift`. The record key is `syncID`.

- A snippet with a known `syncID` is updated (name, keyword, body, tags and dates) if the remote write is newer. It does not go through `save()`, which stamps `updatedAt = now`, but the normalization and validation code (`SnippetStore.normalized(_:)`) is shared, so remote data is checked like a local edit. A snippet that fails (no name, a keyword with a space) is skipped.
- **Adoption.** Unknown `syncID` but a local snippet with the same name (ignoring case) that has never been synced (`syncRecord.pending = 1 AND synced = 0`): the local row takes the remote `syncID`, and the newer write decides the content. This covers the first sync, when both Macs hold the same import. `pending` alone is not enough, because every later edit sets it again, and renaming a synced snippet onto a name another Mac just used would merge two unrelated snippets. If the local content wins, the outcome is `.mergedLocally` and it goes back out under the new key. The old key's `syncRecord` row is deleted in the same transaction.
- **Name clash** with a different snippet (synced or not): the older of the two writes gives way and gets "Name (2)" (the first free number). Both Macs compare the same two `(modifiedAt, device)` stamps, so both decide alike. Always renumbering the incoming snippet would let each Mac rename the other's, and the names would chase each other.
- **Keyword clash:** the older of the two writes drops its keyword. These are the same rules as the Raycast importer, but decided by write time instead of import order.
- When the stored result differs from the payload (a number, a dropped keyword, adopted local content), the outcome is `.mergedLocally`.
- **Known gap:** if both Macs push their never-synced copy of the same snippet before either has pulled, each copy is already synced when the other arrives, and both Macs end up with "Name" and "Name (2)". Delete one by hand. The first cycle of each Mac pulls before it pushes, so this needs two first cycles to overlap.
- **Tombstone:** delete if the remote write is newer.
- Afterwards the Snippets module reloads its keyword table (`SnippetsService.reloadAfterSync()`), so keyword expansion sees new snippets right away.
- **`SnippetPayload` v1:** `syncID, name, keyword, body, tags, createdAt, updatedAt`.

### Reading list

`ReadingListStore.applyRemote` in `ReadingListStore+Sync.swift`.

- The key is the link's normalized URL (`ReadingItem.normalizedURL`), which never changes once saved. There is no `syncID`.
- **Remote upsert,** if newer: insert or overwrite the link with the payload's fields. The URL is taken as sent (it is the record key), as long as it is a web link at all. A later build that normalizes differently still agrees on old keys.
- **Deletes** work like clips: only `ReadingListStore.delete(id:)` leaves a tombstone. The purge of read links ("Delete read links after N days") is local. A remote version of a link that this Mac's purge would delete is not stored (the handler gets the cutoff when the cycle starts), so purged links do not come back from the server, this Mac's own records included.
- **`ReadingItemPayload` v1:** `url, title, note, sourceAppName, addedAt, readAt`.

### Quick actions

`ActionFileSync`, with no database rows other than `syncRecord`.

- Only `*.toml` files at the top level of the actions folder, each up to 64 KB and valid UTF-8. The key is the file name, and `fileHash` is the hash of the last content synced.
- File names from the server are checked before anything is written: no path separators, no leading dot, no `:`, must end in `.toml`, at most 255 bytes. A record that fails is skipped.
- **Remote upsert,** if newer: write to a temporary file in the folder, then `rename(2)` it over the target, so a reader sees the old or the new content and never half. The existing `DirectoryWatcher` reloads the actions. If the local file differs and has unpushed changes (or was never synced), the local version is first saved to `actions/.conflicts/<name>-<UTC yyyyMMdd-HHmmss>-<first 8 hash chars>.toml`. The loader does not read subfolders, so the conflict copy never shows up as a duplicate action. The same content is stored there once.
- **A remote write that loses** to a newer local one is also saved to `.conflicts/`, unless it is only this Mac's own record coming back.
- **Remote tombstone,** if newer: the file moves to `.conflicts/` instead of being deleted. Actions are hand-written, so a deleted one stays recoverable.
- **Case-insensitive volumes:** `Foo.toml` and `foo.toml` are two records but one file on a default macOS volume. This is not handled; the later write replaces the other.
- **`ActionFilePayload` v1:** `fileName, contents`.

### Knowledge base

`KnowledgeFileSync`, the same design as actions for a folder tree, with no database rows other than `syncRecord`.

- Every file below the knowledge folder at any depth, except hidden files and anything in a hidden folder (`.git/`, `.conflicts/`, `.gitignore`, `.DS_Store`), each up to 25 MB. The key is the path relative to the folder, and `fileHash` is the hash of the last content synced. Paths from the server are checked (no `..`, nothing hidden, no empty component). Files up to 256 KB go inline in the payload, larger ones (pictures in `assets/`) as blobs.
- The scan hashes only files whose size or modification date changed since the last cycle (`KnowledgeFileHashes`, kept by the app). A missing folder is not scanned, so it never turns into a tombstone per file. The folder last scanned is kept in `metadata` (`knowledgeSyncFolder`). When another folder is chosen, the `knowledge` rows are forgotten and the cursor goes back to 0, instead of every file of the old folder being deleted on the other Mac. The iPhone stores a fixed name (`folderIdentity`) instead of the path, because the absolute path of an app's container may change.
- **Remote upsert,** if newer: atomic write as for actions, with the other Mac's modification date. Unpushed local changes go to `.conflicts/<folders>/<name>-<timestamp>-<hash>.<ext>` first. A remote tombstone, if newer, moves the file there too and removes the folders it leaves empty below the project's folder. It only takes a file of exactly that name, because a case-insensitive volume may hold another record's file under it.
- A rename is a delete and a create, so the other Mac keeps the old name's last version in `.conflicts/`.
- **`KnowledgeFilePayload` v1:** `path, modified, data | blob, size`.

### Devices

`DeviceSyncHandler`, one record per device, keyed by its device ID. Every cycle on the Macs and the iPhone carries it; it has no switch.

- **When a report goes out.** `beforeCycle` builds this device's report and marks its row pending if there is none yet (the first cycle, or after another device forgot it), if something besides the volatile values changed (name, version, build date, collections, failure, going to sleep or waking, boot date), or if the last one is 15 minutes old. Unsent count, free disk and battery alone wait for that heartbeat. The local-change observation leaves `device` rows out, so a report never counts as a change waiting or asks for another cycle.
- **What it says.** `outgoing` fills in the volatile values when the record is pushed, so `reportedAt` is a moment the device was syncing, and `unsent` counts pending rows written before the last successful cycle ended (what that cycle could not send, not what was changed since). A Mac's push before sleep sets `asleepSince`; its first cycle after waking clears it. The last failure is the last failed cycle's message and time; a cycle that fails sends nothing, so it shows once sync works again.
- **Other devices' reports** are stored as they arrived (fields a later build adds survive), and go out again unchanged after an epoch change.
- **Forget** deletes a device's row and pushes a sealed tombstone. A device that hears it was forgotten reports again with its next cycle.
- **Activity and "behind"** are worked out by the reader: *syncing* while the last report is at most 20 minutes old, *asleep since* while `asleepSince` is set, else *last synced* at the report; *behind* when another device understands a higher payload version of a collection this one syncs, or has a higher version and build on the same platform. From-source builds all say 0.1.0 (1) today, so the build date is shown next to the version.
- Each cycle's report (`SyncCycleReport.changedCollections`) names the collections it wrote, so the apps reload only what changed rather than every module on each device's heartbeat.
- **`DevicePayload` v1:** `deviceID, name, platform, osVersion, appVersion, appBuild, builtAt?, collections, reportedAt, unsent, lastFailure?, asleepSince?, bootedAt?, diskFree?, diskTotal?, battery?, hostName?, userName?`.

## Scheduling

`SyncService` (`Cortex/Modules/Sync/SyncService.swift`) decides when a cycle runs. Every trigger only requests a cycle. Of several requests the earliest wins, so a stream of local changes cannot push a cycle back. A request that arrives while a cycle runs is merged into one follow-up. Nothing here is awaited by the palette, the pasteboard monitor or the snippet expander. All triggers are off while sync is off.

| Trigger | Why |
| --- | --- |
| Launch, 2 s after every contribution is ready (for the clipboard: after the orphan sweep and the first purge, like recording) | Catch up after a restart |
| Wake from sleep (`NSWorkspace.didWakeNotification`), plus 10 s | Arriving at work or home. This is the important one. |
| Network path change to a satisfied path (`NWPathMonitor`), plus 10 s | The VPN or network reconnects |
| Local changes: a GRDB observation on the number of pending `syncRecord` rows (not counting `device`), plus 5 s | Changes leave soon after they are made, without hooks into the modules. It counts rows instead of watching the table, so the engine's own bookkeeping does not wake it again. |
| A change in a contribution's watched folder (actions, knowledge), plus 5 s | Edited files. Changes to hidden files only (`.git/`, `.conflicts/`) ask for nothing. |
| The server has records this device hasn't pulled ([Waiting for changes](#waiting-for-changes)), at once | Another device's changes arrive within seconds. |
| Every 2 minutes | The fallback for when waiting doesn't work (an older server, a request that failed). A cycle without changes is two small requests (health, changes) and a look at the synced folders' file sizes and dates. |
| Before sleep (`willSleepNotification`): push only, cancelled after 5 s, best effort | Leaving the Mac: the others get the latest state |
| The palette opens and the last success is more than 2 minutes old | Freshness at the moment it matters. The palette never waits for it. |
| "Sync Now" (status menu, Settings) | By hand |
| A switch or option of a collection changed | Re-offer what a wider filter lets in, plus 2 s |

Of a burst of local changes, the first one decides: the cycle runs 5 s after it, and changes made meanwhile go with it. Changes made during the cycle get one follow-up.

### Waiting for changes

The server can't reach the devices, but it sees every push. So between cycles each device keeps one request open that the server answers when there is something to pull (`SyncChangeWaiter`, started by `SyncService` and `MobileSyncService`):

1. After each successful full cycle (not the push before sleep), the waiter asks `/v1/health`. Without `maxWait` it stops until the next cycle.
2. It asks `GET /v1/changes?since=<cursor>&limit=1&wait=25`. Records, or another epoch, request a cycle at once, and the waiter ends. That cycle pulls them and starts a new waiter from its cursor.
3. An empty answer after the wait asks again. An empty answer in less than half the wait means something on the way does not hold requests, and the waiter stops until the next cycle, so it can never ask in a tight loop. A failure stops it the same way; the ordinary triggers and their backoff still apply.
4. A cycle cancels the waiter when it starts (it pulls anyway). Stopping the triggers (sync off, disconnect, the iPhone going to the background) cancels it too.

A device's own push also wakes its waiter, because the cursor is behind the records it just sent. The cycle that follows pulls them back (which the next cycle would do anyway), sends nothing and catches the cursor up, so it ends there.

On the server, `push` wakes every waiting request when it stored at least one record (`PushSignal`, in memory, so the server runs one worker). A waiting request checks once a second whether its client hung up, and then ends, so cancelled waits do not hold any of the 16 connections uvicorn accepts (`--limit-concurrency`). Each device holds one. The request's timeout on the client is the wait plus 15 s. Keep `wait` below what the reverse proxy allows a response to take; Traefik v3 sets no limit on that by default.

**Backoff** after a failed cycle: 30 s, 1, 2, 5, 15, then 30 minutes (`SyncBackoff`). The ordinary triggers wait for it. A wake, a network change or "Sync Now" resets it and runs at once.

**Network.** `SyncAPI` uses an ephemeral `URLSession` with no cache and no cookies, `timeoutIntervalForRequest = 10`, `timeoutIntervalForResource = 120` (for blobs) and `waitsForConnectivity = false`, so being off the network fails fast instead of hanging. The health check has a 5 s timeout and logs a warning when the `Date` header differs from this Mac's clock by more than 60 s. Responses are read as they stream in and refused once they exceed a limit.

## The UI and status messages

**Settings → Sync** (the Sync module's page; the module switch above it turns sync on, and it is off by default):

- Not set up: a picker between "Set up this Mac" (server address and token, "Test Connection", "Set Up") and "Join with pairing code" ("Join"). "Test Connection" calls `health` and then an authenticated `changes`, so a wrong token shows up before setting up. A server address without a scheme gets `https://`.
- Set up: the server address, the status row with "Sync Now", one switch per collection of the modules that are on, each with its module's options below it (sensitive clips and the largest clip for clips), "Show Pairing Code…" (a QR code for the iPhone), "Copy Pairing Code", "Upload Everything Again" (marks every row pending) and "Disconnect…".
- "Disconnect" removes the Keychain items, forgets the server URL, resets the cursor and epoch, and stops. The local data and the `syncRecord` rows stay as they are, and setting up or joining again marks everything pending.

**Status menu:** one disabled line under the existing items, plus "Sync Now", both only while sync is set up. There are no alerts and no notifications for sync errors. They show up only in this menu and in Settings. Nothing in the palette shows sync state. Records simply appear when they arrive.

| Status | Menu line | Settings row |
| --- | --- | --- |
| Not set up or off | (hidden) | "Sync is off" |
| On, no cycle finished yet | "Not synced yet" (or "Synced 3 min ago" from the last success) | "Waiting for the first sync" |
| Running | "Syncing…" | "Syncing…" |
| Last cycle succeeded | "Synced 3 min ago" | "Last synced 12:04 · 3 sent, 7 received" |
| Last cycle failed | "Sync paused: …" | The failure text (in red), then "· Last synced …" |

The failure texts come from `SyncEngineError.description` (the menu uses the short form):

| Error | Settings text | Menu |
| --- | --- | --- |
| Server not reachable | "Server unreachable — check your network or VPN" | "server unreachable" |
| 401 | "Token rejected" | "token rejected" |
| A record does not open | "Sync key doesn't match" | "sync key doesn't match" |
| Newer payload version | "Update Cortex on this Mac" | "update Cortex on this Mac" |
| 507 | "The sync server's storage is full" | the same text |
| Any other status | "The sync server answered 500" | the same text |
| Unreadable answer | "The sync server sent an unexpected answer" | the same text |
| Epoch keeps changing | "The sync server keeps changing its identity" | the same text |

Setup has its own errors: no valid server address, no token, "The server already holds data from another sync key. To start over, reset the server's database first.", "The server has no data yet. Set up sync on the other Mac first, then join from here." and a Keychain error.

## What keeps the local app safe

| Risk | Guard |
| --- | --- |
| Server or network down | The cycle stops at the health check (5 s). Backoff follows. Nothing is awaited by the UI, the pasteboard monitor or the palette. |
| Slow or hanging server | Short request timeouts. The engine runs on its own actor and touches the main actor only to post a status update. |
| Database contention with recording | Sync writes go through the same `DatabasePool` writer in transactions of at most one page (200 small records). Blobs are downloaded, decrypted and written to disk before the transaction, the same pattern as `ClipStore.record`. |
| Crash mid-sync | Pull: the cursor advances in the same transaction as the page. Push: the server is idempotent, and `pending` is cleared only for the exact `modifiedAt` that was pushed. Orphaned blobs are swept by the existing `removeOrphanBlobs()` at launch. Files written by an interrupted page are seen by the next scan as a changed file with the remote content and pushed again, which is harmless. |
| Bug in apply code | Per-record savepoint and `try`/`catch`: a broken record is logged and skipped, and the rest of the page applies. Remote data goes through the same normalization and validation as local edits. |
| Remote wipes local data | Only explicit single deletes travel. Purges and Clear History never do. A delete applies only if it is newer than the local write and only if it is sealed with the key and its metadata (see [Sealing and authenticated metadata](#sealing-and-authenticated-metadata)): the token alone cannot delete or roll back anything. Deleted action and knowledge files go to `.conflicts/`, never away. |
| Wrong key, new app version | The pull stops without advancing the cursor. A status line explains it. Local data is unchanged. |
| Junk from a token holder | Records that do not open stop the pull for 3 cycles once the key is confirmed, then are skipped. Out-of-range times are skipped. |
| Server loses its data | The epoch changes, the Macs upload again, and nothing local is lost (see [The epoch](#the-epoch)). |
| Clock skew between Macs | Last writer wins uses each Mac's clock. The client compares its clock with the server's `Date` header and logs a warning above 60 s. A skewed clock only decides which of two edits to the same record wins. |
| Sync key lost on all Macs | The local databases are untouched. Set up again with a new key and an empty server database. |
| Sync turned off | No timer, no observation, no network. The triggers keep their bookkeeping rows, which nothing reads. |

## Tests

- `make test` runs the CortexCore tests: `SyncSchemaTests`, `SyncKeyTests`, `SyncProtocolTests`, `SyncEngineTests` (two `AppDatabase`s against one fake server), `SyncChangeWaiterTests`, and the per-type `SyncClipTests`, `SyncSnippetTests`, `SyncActionTests`, `SyncReadingListTests` and `KnowledgeFileSyncTests`.
- `make test-app` runs `SyncSettingsTests` and `SyncServiceTests`.
- `cd sync-server && uv run pytest` runs the server tests against a temporary database.
- `sync-server/tests/fixtures/*.json` holds the protocol as request and response pairs. pytest replays them against the real server, and the Swift tests replay them against `InMemorySyncServer`, which implements the server's semantics for tests. That keeps the fake honest. The format is in `sync-server/tests/fixtures/README.md`.
- `RealServerTests` runs the Swift engine against a real server when `SYNC_TEST_SERVER_URL` and `SYNC_TEST_SERVER_TOKEN` are set. Use a fresh server.
