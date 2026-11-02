# Reading List

The Reading List module keeps web links to read later. Type `+` in the palette to see them, unread first, and press ⏎ to open one in your default browser and mark it read. Cortex never loads the pages: a link's title comes from what the browser put on the clipboard.

## Using it

Type `+` in the palette (or choose *Reading List* in the status menu). Without a query the list shows the unread links, newest first, then the read ones, dimmed with a check mark, most recently read first. Typing searches titles, websites, URLs and notes; every word has to match. Read links are always searched, whatever *List read links* says. Title matches rank above website matches, which rank above matches in the URL or note. The selected link's URL, note, and when and from which app it was added or read show next to the list.

Adding a link:

- Paste or type it after `+`: the first row becomes *Add to Reading List* with the cleaned-up link, and ⏎ saves it. `+example.com/article` works without a scheme. If the link is already saved, that link is shown instead of the Add row.
- ⌘N adds the link on the clipboard.
- *Add Link from Clipboard* in the status menu does the same over whatever app is in front, and posts a notification ("Added to Reading List", or "No link on the clipboard").

A link copied from Safari or Chrome brings its page title, read from the pasteboard types `WebURLsWithTitlesPboardType` or `public.url` with `public.url-name`. Plain text counts if it is a web link with `://` or a `www.` start. Without a title, the list shows a name made from the link, such as "Context Window (claude.com)" for `https://code.claude.com/docs/en/context-window`, or just the website when the path has nothing readable.

Links are stored without tracking parameters (`utm_…`, `fbclid`, `gclid`, `dclid`, `msclkid`, `mc_cid`, `mc_eid`, `igshid`), with the scheme and host in lower case, without a plain `#anchor` and without a lone trailing slash (app-style fragments such as `#/inbox` stay). Only `http` and `https` links count, and a link with a user name or password is refused. Saving the same article twice is one link: saving it again moves it back to the top as unread, and a new title replaces the old one.

| Key | Does |
| --- | --- |
| ⏎ | Opens the link in the default browser, closes the palette and marks the link read. On the Add row: saves the link. |
| ⌥⏎ | Copies the link instead. It is recorded as a new clip in the clipboard history. |
| ⌘1 to ⌘9 | Same as ⏎ on that row. |
| ⌘R | Marks the link read or unread (the hint says which). |
| ⌘E | Edits the title and a note. ⇥ moves between the fields, ⏎ saves, Esc goes back. An empty title shows the generated name as a prompt. |
| ⌘⌫ | Deletes the link. |
| ⌘N | Adds the link on the clipboard. Beeps if there is none. |

After adding, the list reopens with the new link on top, selected. Status menu items: *Reading List* (opens `+`) and *Add Link from Clipboard*.

## Settings

Settings → Reading List (the page has the Enabled switch, on by default):

| Option | Default | Meaning |
| --- | --- | --- |
| List read links | on | Shows read links below the unread ones. Off keeps the list to what is unread; searching still finds read ones. |
| Delete read links after | 0 days (keep) | 0 to 365. A link is deleted this many days after it was read. Runs at start and every hour, and only on this Mac. |

There is no hotkey and no extra permission.

## On the iPhone

The iOS companion ([plans/IOS.md](../../plans/IOS.md), M2 and M5) has a *Reading List* tab over the same synced links: *Unread* and *Read*, search (the same ranking as `+`, always including read links), title, website and age per row, and the unread count as the tab badge.

- Tap a link to open it and mark it read: in the default browser, or with Settings → Reading List → *Open Links* → *In Cortex* in an in-app Safari view that starts in Reader when the page has one.
- Swipe right to mark read or unread, left to delete (the delete syncs, as on the Mac).
- Add a link with the paste button next to *Add a link* (the system paste control, so iOS shows no paste prompt) or by typing it. Pasted text counts with `://` or a `www.` start, as on the Mac.
- Long press: *Open*, *Add to Safari's Reading List* (Safari keeps it for offline reading; with *Safari's Reading List Marks Read*, on by default, it is marked read here), *Mark Read*/*Unread*, *Edit* (title and note), *Share*, *Copy Link*, *Delete*.
- From other apps (M5): the share sheet's *Cortex* with a web link (or text that is one) shows the title it came with, editable, and *Add*; the App Shortcut *Add to Reading List*; the Home Screen icon's quick action *Add Link from Clipboard* (iOS asks to paste). The *Reading List* widget shows the unread count and the newest titles.
- *Delete Read Links* (Never, or after 1, 7, 30, 90 or 365 days) is the phone's own purge: it runs at launch, when the app comes to the front and when the setting changes, and only on the phone. Links that arrive with an older read date are not stored, as on the Mac.

The settings are the App Group UserDefaults keys `reading-list.openLinks`, `reading-list.safariMarksRead` and `reading-list.deleteReadAfterDays`. The code is in `CortexMobile/ReadingList/` (`ReadingListModel`, `ReadingListView`).

The share extension and the App Shortcut (when it runs outside the app) don't open the database: each link is a small JSON file in `Outbox/reading-list/` of the App Group's data directory (`ReadingListOutbox` in Core), which the app adds to the database oldest first and deletes when it next runs (launch, coming to the front, background refresh). Only then does the link sync, so a link shared while Cortex hasn't run since reaches the Macs late.

## Data and privacy

Links are rows of the table `readingItem` (migration `v8_reading-list_items`) in the encrypted database `~/Library/Application Support/Cortex/Cortex.sqlite` (see [CLIPBOARD.md](CLIPBOARD.md#data-and-privacy) for the key): the normalized link (unique), title, note, the name of the app it was saved from, the date it was added and the date it was read. Nothing else is stored. The settings are the UserDefaults keys `reading-list.listRead` and `reading-list.deleteReadAfterDays`. Switching the module off deletes nothing.

Cortex does not fetch pages or contact any site. The only thing it does with a link is hand it to your default browser when you press ⏎.

**Sync.** With sync on and *Reading list* switched on in the Sync page (see [SYNC.md](../SYNC.md)), links sync encrypted: link, title, note, source app, dates, read state and deletes. An explicit delete leaves a tombstone so the other Mac deletes the link too. The newer write wins the whole link (title, note and read state together). Deleting read links after some days is local: the other Mac keeps its links until its own setting removes them. A link that arrives with a read date older than this Mac's cutoff is not stored, so purged links do not come back.

## How it works

| File | Role |
| --- | --- |
| `Cortex/Modules/ReadingList/ReadingListModule.swift` | The `CortexModule` (id `reading-list`, trigger `+`, order 25, requires the database, needs no permission). Two options, the status menu items, `SyncContributing`, and a `revision` observer that reloads an open palette. |
| `ReadingListService.swift` | Adds, edits, opens (through `NSWorkspace`), marks read, deletes, and runs the hourly purge. `link(on:)` reads a link and title from a pasteboard. |
| `ReadingListScope.swift` | The `+` scope: `ReadingListEntry` (an Add row or a saved link), `entries(for:query:includeRead:)`, the keys, the edit overlay. |
| `ReadingListSettings.swift`, `Views/ReadingListViews.swift` | Settings through `ModuleDefaults`, and the views. |
| `CortexCore/Sources/CortexCore/ReadingList/ReadingItem.swift` | The model, `normalizedURL`, `isPastedLink`, and the generated names for untitled links. |
| `ReadingListStore.swift` | Storage: add or move to top, edit, read state, delete with tombstone, `purgeRead(before:)` and `purgeCutoff(afterDays:)`. |
| `ReadingListSearch.swift` | In-memory ordering and ranking (it uses `SnippetSearch.fold` to ignore case and accents). |
| `ReadingListStore+Sync.swift` | `ReadingListSyncHandler`; the record key is the normalized URL, kept exactly as sent. |

Opening a link and the ⌥⏎ copy use the host's palette (`closeAndDeliver` with `.record(sensitive: false)` makes the copy a clip) and the Notifier for the status menu item. See [ARCHITECTURE.md](../ARCHITECTURE.md). Other modules do not use the Reading List, and it has no API of its own.

## Tests

- `CortexCore/Tests/CortexCoreTests/ReadingList/`: `ReadingListStoreTests` (normalising links, pasted text that counts as a link, saving one again, read state, purging read links and the purge cutoff, search order) and `SyncReadingListTests`.
- `CortexTests/Modules/ReadingList/ReadingListScopeTests.swift`: order, adding a typed or copied link, links and titles from the pasteboard, opening marks read, copying, ⌘R, ⌘E, ⌘⌫.
- Manual: [MANUAL_TESTS.md](../MANUAL_TESTS.md) M25 (the whole module in the palette, status menu and Settings), step 10 of M19 (sync) and M33 (the iPhone).
