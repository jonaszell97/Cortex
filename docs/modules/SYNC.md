# Sync

Sync keeps clips, snippets, the reading list, the knowledge base and your quick action files in step across two or more Macs through a small server you run yourself. Everything is encrypted on the Mac before it leaves, with a key that only your Macs have; the server holds ciphertext. Each Mac keeps a complete local database, and the server is only a mailbox: if it is down or unreachable, the palette, recording, snippets and actions behave as if sync did not exist, and the only visible change is a line in the status menu. Sync is off by default. This page is about using the module; the wire protocol, the cycle and the cryptography are in [SYNC.md](../SYNC.md).

## Using it

Sync has no palette trigger, no hotkey and no keys of its own.

**Set up the first Mac.**

1. Run a sync server (see [Running your own server](#running-your-own-server)) and note its address and token.
2. Settings → Sync: switch *Enabled* on.
3. Choose *Set up this Mac*, enter the server address (for example `https://cortex-sync.example.dev`; a missing `https://` is added) and the token.
4. *Test Connection* checks that the server answers and accepts the token, and changes nothing. It says "Connected".
5. *Set Up* creates the sync key on this Mac, stores it and the token in the Keychain, and uploads everything. It refuses a server that already holds data, because the new key cannot open it.

**Join the second Mac.**

1. On the first Mac, Settings → Sync → *Copy Pairing Code*. The code starts with `cxsync1:` and contains the server address, the token and the key. Send it to the other Mac over AirDrop or Universal Clipboard, never through a chat or mail service. Cortex records the code as a sensitive clip, so it is masked in the palette.
2. On the second Mac, switch *Enabled* on, choose *Join with pairing code*, paste the code and press *Join*.
3. Joining checks the key against the server before storing anything. A wrong or damaged code fails with a message and stores nothing. If nothing has been set up on the server yet, it says to set up the first Mac first.

**Join the iPhone.** On a Mac, Settings → Sync → *Show Pairing Code…*, then *Scan Pairing Code* in Cortex on the iPhone (or paste the code there). The iPhone syncs the knowledge base and the reading list, and needs the server to be reachable, like the Macs (Tailscale on). See [plans/IOS.md](../../plans/IOS.md) and [On the iPhone](#on-the-iphone).

The second Mac merges with the first. Identical clips have the same content hash, so they are not duplicated, and a snippet with the same name on both Macs (for example from the same Raycast import) is adopted instead of duplicated.

**Status.** Once set up, the status menu has one disabled line and *Sync Now*:

| Line | Meaning |
| --- | --- |
| Not synced yet | Sync is on and no cycle has finished. |
| Syncing… | A cycle is running (*Sync Now* is disabled). |
| Synced 3 min ago | The last cycle worked. |
| Sync paused: server unreachable | The last cycle failed, with the reason: *server unreachable*, *token rejected*, *sync key doesn't match*, *update Cortex on this Mac*, or the server's own answer. Sync retries by itself. |

Settings → Sync → *Status* has the longer version ("Last synced 12:04 · 3 sent, 7 received", or the error in plain words with the time of the last success) and a *Sync Now* button. There are no alerts and no notifications for sync errors; they appear only in these two places, and nothing in the palette shows sync state. Records simply appear when they arrive.

**When it runs.** Every trigger only requests a cycle, and requests that arrive while one runs are merged into one follow-up.

| Trigger | When |
| --- | --- |
| Launch | 2 seconds after the modules that sync are ready. |
| Wake from sleep | 10 seconds after. |
| Network change | 10 seconds after the network path changes to a working one. |
| Local change | 5 seconds after a change to something that syncs, or to a watched folder (quick actions, notes). |
| Another device's change | At once: between cycles, each device keeps a request open that the server answers when another device has sent something. |
| Every 2 minutes | Picks up what your other devices sent, in case the request above doesn't work (an older server, a network that drops it). |
| Before sleep | Push only, with a 5 second budget. |
| Palette opened | If the last success is older than 2 minutes. The palette never waits for it. |
| *Sync Now* | At once. |

After failures it backs off: 30 seconds, 1, 2, 5, 15, then 30 minutes. A wake, a network change or *Sync Now* resets this.

**Devices.** Settings → Sync → *Devices* lists every device that syncs, this Mac first: when it last synced ("Syncing" while it reports within the last 20 minutes, "Asleep since 18:02" for a Mac that went to sleep, else "Last synced 9 h ago"), its system and Cortex version with the build date, and "Update Cortex on this Mac" when another device runs a newer build of the same platform or understands a newer payload version of something it syncs. *Forget…* removes a device that is gone from the list on every device; if it syncs again, it comes back. Each device sends its report with a cycle when something about it changed (its name, version, going to sleep or waking, a failure), and otherwise every 15 minutes while it syncs. A device on a build from before the list passes over the reports and doesn't show.

**What to sync.** Settings → Sync → *What to sync* has one switch per kind of data, for the modules that are on. A switched-off module is neither sent nor applied. Switching a collection on offers its records again and pulls its older ones.

**Disconnect.** *Disconnect…* (after a confirmation) removes the sync key and the token from the Keychain and forgets the server and this Mac's place in it. Your clips, snippets and actions stay as they are, and the other Mac keeps its own copy. The Sync module stays on and shows the setup form again.

**Upload Everything Again** marks every record as not yet sent and runs a cycle. Use it after restoring a server from a backup or when a server lost data (the epoch change makes both Macs do this by themselves).

**Lost the server.** Both Macs hold everything. Start a new, empty server at the same address with the same token: its epoch differs, so both Macs upload again by themselves. At another address, Disconnect on both Macs, set up the first one against the new server and join the second. If a server comes back from a backup, give its database a new epoch (see its README) so both Macs upload again. If the sync key is lost on both Macs, disconnect, empty the server's database and set up again.

## Settings

Settings → Sync. The page also has the Enabled switch (off by default).

Before setup:

| Option | Meaning |
| --- | --- |
| Set up this Mac / Join with pairing code | The two ways in. |
| Server | The server's address. |
| Token | The server's bearer token. |
| Test Connection, Set Up | As described above. |
| Pairing code | `cxsync1:…` from the first Mac. |

After setup:

| Option | Default | Meaning |
| --- | --- | --- |
| Server | | The address in use (read only). |
| Status, Sync Now | | See above. |
| Clipboard history | on | Syncs clips. Below it, *Sensitive clips* (off) and *Largest clip* (10 MB, 1 to 30). Both are options of the Clipboard module, shown here. |
| Snippets | on | Syncs snippets. |
| Reading list | on | Syncs the reading list. |
| Your quick actions | on | Syncs the `*.toml` files in `~/.config/cortex/actions/`. |
| Notes, skills and to-dos | on | Syncs the knowledge folder. |
| Show Pairing Code… | | Shows the code as a QR code, for Cortex on the iPhone. |
| Copy Pairing Code | | Puts the code on the pasteboard, marked concealed. |
| Upload Everything Again | | See above. |
| Disconnect… | | See above. |

The list under *What to sync* follows the modules: a module that is off has no row, and rows come in the order of the modules. Hotkeys, retention settings and the ignore list never sync.

## Data and privacy

**What syncs.**

| Data | Syncs | Stays on each Mac |
| --- | --- | --- |
| Clips | All stored formats, pinned and sensitive flags, source app, dates, and deleting a single clip | Copied files (their paths are specific to a Mac), clips above *Largest clip*, sensitive clips unless *Sensitive clips* is on (on both Macs), retention purges, Clear History, the text read from images |
| Snippets | Name, keyword, text, tags, dates, deletes | Usage counts |
| Reading list | Link, title, note, source app, dates, read or unread, deletes | Deleting read links after some days |
| Quick actions | The `*.toml` files | The tools and scripts they call, subfolders, usage counts, remembered option values |
| Knowledge base | Every file in `~/.config/cortex/knowledge/`, with its modification date, and deletes | The git history, `.conflicts/`, hidden files, files over 25 MB |
| Settings | Nothing | Everything |

See the module pages for what each collection does with conflicts: [CLIPBOARD.md](CLIPBOARD.md), [SNIPPETS.md](SNIPPETS.md), [READING_LIST.md](READING_LIST.md), [ACTIONS.md](ACTIONS.md) and [KNOWLEDGE.md](KNOWLEDGE.md). In short, the newer write wins per record; the losing version of a quick action file or a knowledge file, and any file deleted on the other Mac, goes to a `.conflicts/` folder next to the originals and is never lost.

**Where the keys are.** The sync key and the server token are Keychain items in service `dev.jonaszell.cortex`, accounts `sync-key` and `sync-token`. They never go to UserDefaults or the database. The pairing code contains both and the server address, so treat it like a password. UserDefaults holds `syncServerURL` (the address), the collection switches `syncClips`, `syncSnippets`, `syncReadingList`, `syncActions` and `syncKnowledge`, and the Clipboard options `syncSensitiveClips` and `syncMaxClipMB`. The module switch is `module.sync.enabled`; before modules existed it was `syncEnabled`, which is still read until the switch is first set. None of these is secret.

**In the database.** The `syncRecord` table (migration `v4_sync`) has one small row per clip, snippet, reading list link, action file and knowledge file, with a pending flag. Triggers keep it current whether sync is on or off, and Disconnect leaves it in place. The `metadata` table holds this Mac's sync device ID, the cursor into the server's changes, the server's epoch and the time of the last success.

**What leaves the Mac.** Only with Sync switched on and set up, and only to the server address you entered; the app talks to nothing else for sync. Each record's content is sealed with AES-GCM under keys derived from the sync key. Record IDs are keyed hashes, so the server cannot link an ID to content. The server sees the ciphertext, the opaque IDs, which collection a record belongs to, timestamps, a device ID, sizes and when you sync. It cannot tell a password from a screenshot. These fields are part of what the encryption authenticates, so someone who has only the token cannot move a payload to another record, restamp an old one or turn a record into a deletion. The bearer token only keeps others from writing junk to the server. Details are in [SYNC.md](../SYNC.md).

**Safety of the local app.** The cycle starts with a health check that gives up after 5 seconds. Requests time out after 10 seconds, and the app never waits for the network. Only explicit single deletes travel; purges and Clear History never do. A wrong key or an unknown record version stops the pull without changing local data. A clock that differs from the server's by more than a minute is logged; it only decides which of two edits to the same record wins.

## Running your own server

The server is in `sync-server/` (Python, FastAPI, one SQLite file). It stores sealed records and blobs, orders them by a sequence number and keeps the newest write per record. It cannot read any of it. Its [README](../../sync-server/README.md) has the options; in short:

```sh
cd sync-server
uv sync
SYNC_TOKEN=$(openssl rand -hex 32) DATA_DIR=./data uv run uvicorn app.main:app --port 8787
```

| Env var | Default | |
| --- | --- | --- |
| `SYNC_TOKEN` | (required) | Bearer token, at least 16 characters. |
| `DATA_DIR` | `/data` | Holds `sync.sqlite`. |
| `PRUNE_CLIP_DAYS` | `60` | Unpinned clip records older than this are removed from the server. |
| `MAX_BLOB_MB` | `32` | Largest blob upload. |
| `MAX_JSON_MB` | `32` | Largest JSON body. |
| `MAX_STORAGE_MB` | `2048` | Database size above which pushes get 507 (deletions still go through). |

Run it in front of HTTPS, on a host both Macs can reach. `sync-server/compose-example.yaml` and its `Dockerfile` run it in Docker on port 8000 with a `sync-data` volume, leaving TLS to a reverse proxy. The token is the only access control, so keep the server on a private network or behind a VPN or firewall rule if you can. From a Mac, `curl https://cortex-sync.example.dev/v1/health` should answer `{"status": "ok", …}`. To use another server, Disconnect on both Macs and set up again. Back up `sync.sqlite` if you like, but both Macs hold everything, so losing the server loses nothing.

A server must be as new as the Macs. A Mac that pushes a collection the server does not know yet (a new kind of data) has those records refused; the engine skips them and syncs everything else, so deploy the server before updating the Macs.

Run its tests with `cd sync-server && uv run pytest`.

## On the iPhone

The *Devices* tab shows the same list: this iPhone first with its own status, then the other devices with the same lines and warnings, and a detail screen with everything a device reported (last report, changes it had not managed to send, its last failure, version and build date, what it syncs, and for a Mac its uptime, free disk, battery, host name and user). Swipe a device to *Forget* it. Pull to refresh syncs. iOS gives apps no device name, so Settings → *This iPhone* → *Name* sets what the Macs call it (default "iPhone").

## How it works

The sync engine and its cryptography are in CortexCore; the module is the glue to the app. See [ARCHITECTURE.md](../ARCHITECTURE.md) for the module system.

| File | Role |
| --- | --- |
| `Cortex/Modules/Sync/SyncModule.swift` | The `CortexModule` (id `sync`, no trigger, off by default, requires the database, order 70). Builds the `SyncService`, adds the status menu line and *Sync Now*, and tells the service when the palette opens. |
| `SyncService.swift` | Runs the cycles in the background: the triggers and their delays, the backoff, set up, join, disconnect, *Upload Everything Again*, the pairing code. Every trigger only requests a cycle; nothing is awaited by the palette, the pasteboard monitor or the snippet expander. |
| `SyncAPI.swift` | `SyncContributing`, `SyncContribution` and `SyncFilterValues`: how a module offers its data to Sync. |
| `SyncSettings.swift`, `SyncSettingsView.swift` | The server address and the collection switches over UserDefaults, and the Settings page. |
| `CortexCore/Sources/CortexCore/Sync/SyncEngine.swift` | An actor that runs at most one cycle at a time: health check, epoch check, handlers' `beforeCycle`, pull in pages, push of the pending rows, with last-writer-wins. |
| `SyncEntityHandler.swift`, `SyncPayloads.swift` | What a kind of data provides: scanning, a payload for a local record, and applying a remote one. The payload types are versioned. |
| `SyncKey.swift` | The sync key, its subkeys, record IDs, sealing, and `SyncPairing` (the pairing code). |
| `SyncSetup.swift`, `SyncStatus.swift` (Core) | Checking the server against the key before anything is stored (first device, joining), the credentials in the Keychain; `SyncStatus`, `SyncFailure` (the reasons in plain words) and `SyncBackoff`. Shared with the iPhone app. |
| `SyncAPI.swift` (Core), `SyncTransport.swift` | The HTTP client (an ephemeral `URLSession`, no cache, no cookies) and the protocol the engine sees. |
| `SyncSchema.swift`, `SyncState.swift` | The `syncRecord` table with its triggers, and the state in `metadata`. |
| `SyncDevices.swift` (Core) | The `device` collection: `DeviceSyncHandler` (this device's report, when it is due, and the others' reports), `DevicePayload`, `DeviceStats` (system, build, uptime, disk, battery), `SyncDevice` with its lines, and the `syncDevice` table. `SyncService` adds the handler to every cycle; it is not a module's contribution and has no switch. |

**How a module takes part.** Sync names no module. A module that has data to sync conforms to `SyncContributing` and returns `SyncContribution`s: the collection, the title and `UserDefaults` key of its switch, optional options shown below the switch, a `makeHandler` that returns its `SyncEntityHandler`, optionally a folder to watch (for files without rows in the database), `waitUntilReady` (the Clipboard's orphan sweep and purge finish before the first cycle) and `didApplyRemoteChanges` (reload what shows the data; called only after a cycle that wrote records of its collection). Sync asks the active modules for their contributions whenever it needs them, so a module that is switched off is neither sent nor applied. Today the contributors are Clipboard (`clip`), Snippets (`snippet`), Reading List (`reading`), Quick Actions (`action`) and Knowledge (`knowledge`). Because the triggers on the data tables record every local write whether sync is on or not, turning sync on later is only "mark everything pending".

**Changed options.** `SyncService` watches each contribution's switch and its toggle and integer options. When a change lets in records that were held back (a switch turned on, *Sensitive clips* on, a larger *Largest clip*), the collection's rows are offered again and its older records are pulled again.

## Tests

- `CortexCore/Tests/CortexCoreTests/Sync/`: `SyncEngineTests` (two Macs against `InMemorySyncServer`), `SyncKeyTests` (sealing, pairing codes), `SyncSetupTests` (joining, credentials), `SyncStatusTests` (the status texts, the backoff), `SyncProtocolTests` (request and response pairs shared with the server's tests), `SyncSchemaTests` (the triggers and the migration), `DeviceSyncTests` (the reports, the heartbeat, forgetting, "behind"). Each collection's handler is tested with its data: `SyncClipTests`, the snippet, reading list and action file tests, and `Knowledge/KnowledgeFileSyncTests`.
- `CortexTests/Modules/Sync/`: `SyncServiceTests` (cycles, backoff, set up, join, disconnect, with a fake transport) and `SyncSettingsTests`.
- `sync-server/tests/`: the server, run with `cd sync-server && uv run pytest`.
- Manual: [MANUAL_TESTS.md](../MANUAL_TESTS.md) M19 needs two Macs with the same build installed and a deployed server: set up and join, working with the server unreachable, copying on one Mac and opening the other, deletes, edits on both Macs while offline, action file conflicts, sensitive clips, disconnect, what to sync following the modules, the reading list and the knowledge base.
