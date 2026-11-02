# Clipboard

The Clipboard module keeps a searchable history of what you copy: text, rich text, images and files. It is the palette's default scope: with nothing typed before the query, the palette shows the history, newest first, with the selected clip's full content next to it. ⏎ pastes a clip into the app you came from.

## Using it

Open the palette with ⇧⌘V (the palette hotkey is set in Settings → General, not by this module) or with *Open Cortex* in the status menu. The clipboard has no trigger prefix. Type to search; every word has to match the start of a word in the clip's text, in the text read from an image, or in the name of the app it came from.

To search the history for text that starts with another module's trigger (`;`, `+`, `?`, `!`, `>`, `$`, `:`, `::`, `=`), put a backslash in front: `\:8080` searches for `:8080`. `\\` searches for a leading backslash.

| Key | Does |
| --- | --- |
| ⏎ | Pastes the clip in the richest form the clip has (formatting, image, files). |
| ⇧⏎ | Pastes plain text only. A files clip pastes its paths, an image pastes the text read from it once there is some. |
| ⌥⏎ | Copies the clip without pasting. |
| ⌘1 to ⌘9 | Pastes the clip in that row (the number is shown in the row), like ⏎. ⌘⇧1 to ⌘⇧9 paste like ⇧⏎. |
| ⌘P | Pins or unpins the clip. Pinned clips are never purged. |
| ⌘⌫ | Deletes the clip. |
| ⌘E | Opens the snippet editor with this clip's text as a new snippet (only while the Snippets module is on). |
| ⌘N | Opens the snippet editor on an empty new snippet (only while Snippets is on). |
| ⌘K | Shows the quick actions for the selected clip (only while Quick Actions is on). |
| Hold ⌥ | Reveals sensitive clips, in the list and in the preview. |
| Click, double-click | Select, paste. |

With *Paste as plain text by default* on, ⏎ and ⇧⏎ swap roles. The hint bar at the bottom always shows the current meaning.

Pasting needs the Accessibility permission, because Cortex posts ⌘V. Without it, ⏎ only copies and the onboarding window opens. A pasted or copied clip moves to the top of the history.

Status menu items:

- *Pause Recording* (checked while paused). While recording is paused, the menu bar icon becomes a pause symbol so it is not forgotten.
- *Clear History…* asks first, then deletes everything except pinned clips.

The preview shows the clip as it was copied: rich text with its fonts, an image with the text read from it below, a list of files with their folders, or a swatch with the colour in several formats for a clip that is only a colour.

The module is on by default.

## Settings

Settings → Clipboard (the module's page also has the Enabled switch):

| Option | Default | Meaning |
| --- | --- | --- |
| Pause recording | off | Nothing is recorded while on. Also in the status menu. |
| Paste as plain text by default | off | Swaps ⏎ and ⇧⏎. |
| Search text in images | on | Reads the text in image clips on this Mac, so screenshots are found by what they say (see [Text Recognition](TEXT_RECOGNITION.md)). Turning it on reads the clips that have no text yet, newest first. |
| Keep items for | 30 days | 1, 7, 30, 90 or 365 days, or Forever. |
| Keep at most | 2,000 items | 500, 1,000, 2,000, 5,000, 10,000 or any number. |
| Items in history | | The count, with *Clear History…*. |
| Keep sensitive items for | Same as other items | Or 1, 7 or 30 days. Only shortens; it never keeps a sensitive clip longer than the first two options allow. |
| Include their text in search | on | Whether the text of sensitive clips is searchable. Changing it rebuilds the search text of the sensitive clips at once. |
| Detect passwords and tokens | on | Flags copied text that looks like a secret (see [Data and privacy](#data-and-privacy)). |
| Ignored apps | none | Copies made while one of these apps is frontmost are not recorded. *Add App…* opens a picker in /Applications. |
| Import → Pastebot | | *Import History…* reads Pastebot 2's history and pasteboards (see below). |

Retention and the item limit never touch pinned clips. A changed retention setting is applied immediately; it is also applied at launch and once an hour.

When Sync is set up, the *What to sync* list on the Sync page has a *Clipboard history* entry with two options of this module: *Sensitive clips* (off) and *Largest clip* (10 MB, 1 to 30). See [SYNC.md](../SYNC.md).

Importing from Pastebot: the importer reads the SQLite databases in Pastebot 2's group container (`~/Library/Group Containers/9JTH7AWHE6.com.tapbots.Pastebot2Mac/Library/Application Support`). The history is imported with its original dates; every other Pastebot pasteboard is imported as pinned clips. Clips already in the history are skipped and keep their dates. The dialog shows the counts before anything is imported.

## Data and privacy

**What is stored.** Each clip is a row in `clipItem` (kind, preview, plain text, search text, flags for sensitive and pinned, source app, size, thumbnail, dates, and the text read from an image in `recognizedText`) with its pasteboard types in `clipRepresentation`. Only these types are kept: file URLs, PNG, TIFF, RTFD, RTF, HTML and plain text; images in other formats (JPEG, HEIC, GIF, WebP) are converted to PNG. Search uses the SQLite full-text table `clipItemFTS` over `searchText`. Content that Cortex itself wrote (a pasted clip, snippet, emoji, symbol) carries a marker type and is not recorded again. The same content copied twice is one clip: its date moves to now.

Images and any payload above 256 KB are not in the row. They are separate files in `~/Library/Application Support/Cortex/Blobs/`, one per payload, encrypted with AES-GCM under a key derived from the database key. The database is `~/Library/Application Support/Cortex/Cortex.sqlite`, encrypted with SQLCipher; its key is the Keychain item `database-key` in service `dev.jonaszell.cortex`. Blob files are created with mode 0600 in a 0700 folder. At launch Cortex deletes blob files that no row refers to.

A copy over 25 MB is not recorded. Settings are in UserDefaults under the keys `retentionDays`, `retentionMaxItems`, `sensitiveRetentionDays`, `indexSensitiveText`, `detectSensitiveText`, `recognizeImageText`, `pastePlainByDefault`, `ignoredBundleIDs`, `isRecordingPaused`, `syncSensitiveClips` and `syncMaxClipMB`. None of them is secret. Switching the module off stops recording and purging and deletes nothing.

**Sensitive clips.** A clip is flagged sensitive when:

- the copying app marked it as concealed, transient or auto-generated (the conventions of nspasteboard.org, plus 1Password's own type), or
- it was copied in a known password manager (1Password, Apple Passwords, Keychain Access, Bitwarden, KeePassXC, LastPass, Enpass, Dashlane, Proton Pass), or
- with *Detect passwords and tokens* on, its text looks like a secret: private keys, prefixed API tokens (GitHub, OpenAI, Stripe, Slack, AWS and others), JWTs, credentials in a URL, random-looking tokens, and password-shaped single words. The detector prefers missing a secret to masking ordinary text and skips text over 64 KB (`SensitiveTextDetector`). Text read from an image is checked the same way and can flag the image clip.

Sensitive clips are recorded, but shown as `••••••••` in the list and as "Sensitive" in the preview until you hold ⌥. Once flagged, a clip stays flagged. They can be kept for a shorter time, and their text can be left out of the search index. When Cortex pastes one, it marks the pasteboard content as concealed, writes it with the current-host-only option (so Universal Clipboard does not send it), and clears the pasteboard 90 seconds later if nothing else was copied. A snippet's `{clipboard offset=n}` never pastes a sensitive clip, `$` form suggestions leave them out, and the AI actions are not offered for them (see [AI](AI.md)).

**Text read from images.** Done by the system's Vision framework on this Mac, in the background, one clip at a time. The text is stored in `clipItem.recognizedText` and never synced; each Mac reads its own clips.

**Sync.** Clips sync only when sync is on and *Clipboard history* is switched on in the Sync page (see [SYNC.md](../SYNC.md)). Everything is encrypted on the Mac before it leaves. What syncs and what does not:

- Synced: text, rich text and image clips with all stored representations, the pinned and sensitive flags, source app, dates, and the deletion of a single clip.
- Stays on the Mac: copied files (their paths are specific to a Mac), clips over *Largest clip*, sensitive clips unless *Sensitive clips* is on (on both Macs), retention purges, *Clear History*, and the recognised image text.
- An arriving clip that this Mac's retention would purge at once is not stored.
- When both Macs have a clip, the later last-copied date wins, "sensitive" sticks, and the pin follows the newer write.

**What leaves the Mac.** Nothing, except through sync, or when you run an AI action on a non-sensitive clip.

## How it works

Platform-independent storage is in `CortexCore/Sources/CortexCore/Clipboard/`; the macOS parts are in `Cortex/Modules/Clipboard/`.

| File | Role |
| --- | --- |
| `ClipboardModule.swift` | The `CortexModule` (id `clipboard`, trigger `.default`, order 10, requires the database, asks for Accessibility). Builds the service and scope, provides the options, the status menu items and the pause icon, implements `ClipboardAPI` and `SyncContributing`. |
| `ClipboardService.swift` | Owns recording, the hourly purge, the image-text indexer and the actions the palette performs (`perform`, pin, delete, clear, Pastebot import). Blocking store work runs off the main actor. |
| `PasteboardMonitor.swift` | An actor that polls `NSPasteboard.changeCount` every 250 ms (macOS has no change notification), skips Cortex's own writes, paused state, ignored apps and over-size copies, flags sensitive text, and records through `ClipStore`. While Cortex borrows the pasteboard (`PasteboardActivity`) it leaves the change unread. |
| `ImageTextIndexer.swift` | Reads the text of image clips in the background through `TextRecognizing` (see [TEXT_RECOGNITION.md](TEXT_RECOGNITION.md)). Woken after startup, after each copy and after sync. |
| `ClipboardScope.swift` | The `PaletteScope`: search, selection, the keys above, paste actions. Uses `SnippetsAPI` and `ActionsAPI` for ⌘E, ⌘N and ⌘K, and hides those hints when the other module is off. |
| `ClipboardSettings.swift`, `ClipboardSettingsView.swift` | UserDefaults-backed settings and the sections below the options. |
| `Views/` | The list row, the preview pane, the colour swatch. |
| `ClipboardAPI.swift` | What other modules may use: `recentTexts(upTo:)` (older clips for `{clipboard offset=n}`), `recentTexts(limit:)` (suggestions for `$` forms) and `detectsSensitiveText`. |
| `ClipStore.swift`, `ClipStore+Sync.swift` | Recording (de-duplication by SHA-256 content hash), search, retention, tombstones for explicit deletes, the sync handler `ClipSyncHandler`. |
| `ClipItem.swift`, `ClipSnapshot.swift`, `ClipType.swift` | The models; `ClipSnapshot` decides a clip's kind (files, image, rich text or text). `SensitivityRules` holds the marker types and password manager IDs. |
| `SensitiveTextDetector.swift`, `BlobStore.swift`, `Thumbnail.swift`, `PastebotImporter.swift` | As named. |

The host provides the rest (see [ARCHITECTURE.md](../ARCHITECTURE.md)): `PasteService` and `Paster` write to the pasteboard and post ⌘V, `PasteboardReader` turns a pasteboard into a `ClipSnapshot`, and the palette handles the trigger, the escape backslash and the hint bar. Other modules reach the history only through `ClipboardAPI`. `AppDatabase` owns the tables (migrations `v2_clips` and `v9_clipboard_recognized-text`, plus the sync bookkeeping of `v4_sync` and later). The database is opened without the module too, so switching it off keeps the history.

To change what is recorded, edit `PasteboardReader.snapshot` and `ClipSnapshot.kind`. To add a sensitive-text pattern, edit `SensitiveTextDetector` and add a case to its tests.

## Tests

- `CortexCore/Tests/CortexCoreTests/Clipboard/`: `ClipStoreTests` (recording, de-duplication, search, pin, delete, retention, blobs, recognised text), `SensitiveTextDetectorTests`, `PastebotImporterTests` (against a fixture) and `SyncClipTests`.
- `CortexTests/Modules/Clipboard/`: `PasteboardMonitorTests` (reading real pasteboard content on a private pasteboard, pause, ignore list, size limit), `ClipboardScopeTests`, `ClipboardSettingsTests`, `ImageTextIndexerTests`, `ClipPreviewTests` and `RichTextRoundTripTests`.
- Manual: [MANUAL_TESTS.md](../MANUAL_TESTS.md) M1 to M12 (recording from real apps, pasting into real apps, copy only, images and files, a password manager, panel behaviour, the lock screen, the status menu, Settings, the Pastebot import and running without Accessibility) and M19 for sync.
