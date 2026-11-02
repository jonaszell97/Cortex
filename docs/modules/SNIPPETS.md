# Snippets

The Snippets module keeps saved texts and pastes them for you, either from the palette or when you type a short keyword in any app. A snippet can hold placeholders: the date, the clipboard, a cursor position, or fields that Cortex asks for before pasting. Snippets from Raycast can be imported, and exported again.

## Using it

Type `;` in the palette. The list shows your snippets, most used first, with the selected snippet's text next to it (placeholders as written). Typing searches: every word has to match somewhere, and a better match ranks higher. The order of preference is the keyword (`;sig` is also found by `sig`), the start of the name or of a word in it, tags, then any part of the name, letters of the name in order, and finally the text.

| Key | Does |
| --- | --- |
| ⏎ | Pastes the snippet as plain text into the app you came from. A snippet with fill-ins opens its form first. |
| ⌥⏎ | Copies it instead (the form opens first here too). |
| ⌘1 to ⌘9 | Pastes the snippet in that row. |
| ⌘E | Opens the selected snippet in the editor. |
| ⌘N | Opens the editor on a new snippet. |

Snippets always paste as plain text; ⇧ makes no difference. A pasted snippet is not recorded in the clipboard history, and a snippet with `{cursor}` leaves the cursor there. Pasting needs Accessibility, like every paste.

The fill-in form has a field per name, in order of first appearance, each starting with its default. ⇥ moves to the next field, ⏎ pastes, ⌥⏎ copies, Esc goes back to the list (a second Esc closes the palette).

**Keyword expansion** (off by default): with *Expand keywords as you type* on, typing a snippet's keyword in any app replaces it with the snippet. Cortex deletes the typed keyword, pastes the snippet as plain text and puts the previous clipboard back, so ⌘V afterwards still pastes what you had copied. Rules:

- The keyword has to start a word: `Hello ;sig` expands, `foo;sig` does not (the character before must not be a letter or digit).
- A backspace is followed. Arrow keys, Home, End, Page Up and Down, Esc, ⌥⌫ and any ⌘ or ⌃ shortcut, a mouse click, switching apps, sleep and locking the screen all forget what was typed so far.
- A snippet with fill-ins opens the palette with its form on top of the app you typed in. ⏎ pastes there; Esc closes the palette and leaves the keyword deleted.
- Nothing expands in password fields (macOS hides keystrokes from Cortex while secure input is on), in the palette's search field, or in Cortex's own windows such as the editor.

The snippet editor (status menu → *Snippets…*, ⌘E or ⌘N in the palette, or *Open Editor…* in Settings) has the list in the sidebar, with a search field and *+* (⌘N) at the top. Each row shows the name, the first line of the text and the keyword. ⌫ deletes the selected snippet after asking; right-clicking a row offers *Duplicate* (an unsaved copy without the keyword, since keywords are unique), *Copy* (the text as written, not recorded in the clipboard history) and *Delete…*.

On the right, the name is the title. Under it are the keyword (optional, for example `;sig`) and the tags as chips: type a tag into *Add tag* and press ⏎ or a comma to add it, and click a chip's × to remove it. A tag typed but not yet added is saved too. At the end of that line is how often the snippet was used and when last. The text below has an *Edit* / *Preview* switch: Edit shows the text with every placeholder tinted, without smart quotes or dashes; Preview shows it rendered with today's date, markers for the clipboard and fill-ins, and `▏` where the cursor goes. *Insert Placeholder* puts one at the cursor. ⌘S saves, *Revert* undoes edits. Switching to another snippet saves first; closing with unsaved changes asks. The footer shows save errors (see below).

The clipboard's ⌘E ("Save as snippet") and ⌘N, and the Quick Actions module's *Create Snippet* action, open the editor on a new snippet through `SnippetsAPI`. Those hints appear only while Snippets is on.

### Placeholders

| Placeholder | Becomes |
| --- | --- |
| `{clipboard}` | The text on the clipboard. `{clipboard offset=1}` is the text clip before it, up to offset 100. A sensitive clip pastes nothing. `{clipboard\|plans/.*\\.md}` pastes it only if the regular expression matches somewhere in it (anchor with `^` and `$` for all of it); otherwise it becomes the text `{placeholder}`, to fill in by hand. A modifier can follow, and the expression can't contain `{` or `}`. |
| `{cursor}` | Nothing; the cursor is moved here after pasting. Only the first one counts. |
| `{uuid}` | A new UUID, different for each occurrence. |
| `{date}`, `{time}`, `{datetime}`, `{day}` | Now, in your locale (`{day}` is the weekday). |
| `{date:yyyy-MM-dd}` | Now, in a Unicode date pattern. `time` and `datetime` take patterns the same way. |
| `{name}` | A fill-in, asked for before pasting. The same name twice is asked once. Letters, digits, `_`, `-` and inner spaces, at most 40 characters. |

Raycast's spelling works too, so imported snippets run unchanged: `{date format="yyyy-MM-dd" offset="+1d"}` (units `m h d w M y`), `{argument name="name" default="x"}`, and modifiers after a bar: `{clipboard | uppercase}` (`uppercase`, `lowercase`, `trim`, `percent-encode`, `json-stringify`, `raw`). Braces that hold anything else (JSON, code, a name starting with a space, a `{` before the closing `}`, a line break) stay as written. Raycast's `{selection}`, `{browser-tab}` and `{snippet}` are not filled in; the import preview warns about them.

## Settings

Settings → Snippets (with the module's Enabled switch, on by default):

| Option | Default | Meaning |
| --- | --- | --- |
| Snippets | | The count, and *Open Editor…*. |
| Expand keywords as you type | off | Starts the keyword event tap. Shows "Needs Accessibility access" with a *Grant Access…* button while it cannot start. |
| Import → Raycast snippets (JSON) | | *Import…* and *Export…*, described below. |

There is no hotkey for this module. The palette trigger is `;`.

**Import** takes the file from Raycast's *Export Snippets* command (a JSON list of `name`, `text` and optional `keyword`; a wrapping object with a `snippets` list is accepted too). A preview lists every entry first and changes nothing:

- New: no snippet of that name (compared ignoring ASCII case).
- Changed: the name exists, with other text or keyword. A toggle, on by default, decides whether these are replaced. A replaced snippet keeps its name, tags and usage count and takes text and keyword from the file.
- Unchanged: the name, text and keyword all match. Importing the same file twice therefore changes nothing.
- Duplicate: an earlier entry in the file has the same name. Invalid: no name or no text.
- A keyword that contains a space, or that another snippet already uses, is left out of that entry, with a note.

**Export** writes the same JSON format, sorted by name, to a file readable only by you (mode 0600). Tags and usage counts have no place in the format. Snippets often hold addresses and signatures; keep the file off cloud drives and mail.

Saving a snippet fails with a message when the name is empty or already used (ignoring case), when the keyword contains whitespace, or when another snippet has the keyword.

## Data and privacy

Snippets are rows of the table `snippet` (name, keyword, body, tags as JSON, usage count, last used, dates and a `syncID`) in the encrypted database `~/Library/Application Support/Cortex/Cortex.sqlite` (see [CLIPBOARD.md](CLIPBOARD.md#data-and-privacy) for the key). Names and keywords are unique. Switching the module off deletes nothing. The only setting is the UserDefaults key `snippetKeywordExpansion`.

**Keyword expansion** is the only part that sees what you type. With it off, no event tap exists. With it on, a tap on its own thread sees key presses and mouse clicks, passes every event on unchanged, and keeps the last typed characters (at least 20, or the longest keyword plus one) in memory. Nothing typed is written to disk or the log. The buffer is cleared as listed above. The tap is a normal one covered by the Accessibility permission; no Input Monitoring is needed. Events that Cortex posts itself (the backspaces and ⌘V of an expansion) carry a tag, so the tap ignores them.

**Placeholders.** `{clipboard}` reads the text on the pasteboard at the time of pasting. `{clipboard offset=n}` reads older text clips from the history through the Clipboard module's API ([CLIPBOARD.md](CLIPBOARD.md)); a clip flagged sensitive gives nothing, and without the Clipboard module older offsets are empty.

**Sync.** With sync on and *Snippets* switched on in the Sync page (see [SYNC.md](../SYNC.md)), name, keyword, text, tags, dates and deletes sync, encrypted. Usage counts stay on each Mac. When two Macs change the same snippet, the newer write wins. If a name or keyword is taken by another snippet, the older write gives way: a name gets a number (`Name (2)`), a keyword is dropped. The first time, an unsynced local snippet with the same name as a remote one (for example the same Raycast import on both Macs) is merged with it instead of duplicated. Nothing else leaves the Mac.

## How it works

Logic that needs no AppKit is in `CortexCore/Sources/CortexCore/Snippets/`; the app side is in `Cortex/Modules/Snippets/`.

| File | Role |
| --- | --- |
| `SnippetsModule.swift` | The `CortexModule` (id `snippets`, trigger `;`, order 20, requires the database, asks for Accessibility). Implements `SnippetsAPI` and `SyncContributing`, and runs the keyword tap through `context.whileWanted`, so it exists only while the setting is on and Accessibility is granted. |
| `SnippetsService.swift` | Owns the store, renders and pastes snippets (`perform`), runs an expansion (`expand`), imports and exports. Bumps `revision` after each change so open views and the keyword table reload. |
| `SnippetsScope.swift` | The `;` palette scope, the fill-in overlay (`fillInOverlay`) and `FillInForm`. |
| `KeywordExpander.swift`, `KeywordBuffer.swift` | The event tap on its own thread and the in-memory buffer. `KeywordExpander.process` and `action` are static and tested without a tap. |
| `Editor/` | `SnippetEditorWindowController`, `SnippetEditorModel`, `SnippetEditorView`, and `SnippetTextView` (an `NSTextView` that tints placeholders found by `SnippetTemplate.placeholderRanges` and inserts at the cursor). |
| `SnippetsSettings.swift`, `SnippetsSettingsView.swift`, `Views/SnippetViews.swift` | Settings, the import dialog and the palette views. |
| `SnippetsAPI.swift` | `editSnippet(_:)` with `SnippetEditRequest`, used by Clipboard and Quick Actions. |
| `Snippet.swift`, `SnippetStore.swift`, `SnippetSearch.swift` | Model, storage with the uniqueness rules, ranking (in memory). |
| `SnippetTemplate.swift` | Parses a body into text and placeholders and renders it with a `SnippetContext` (clipboard texts, fill-ins, clock, UUID source, so tests are deterministic). |
| `RaycastSnippets.swift` | The JSON format, and `SnippetImportPlan` (the dry run) with `SnippetStore.apply`. |
| `SnippetStore+Sync.swift` | `SnippetSyncHandler`: payloads, name and keyword conflicts, adopting identical snippets. |

The host's `PasteService.deliver` does the pasting and, with `restoringPasteboard`, the lending and restoring of the clipboard that expansion needs (see [ARCHITECTURE.md](../ARCHITECTURE.md)). The table comes from migration `v3_snippets`; the `syncID` column and the triggers that record changes for sync come from `v4_sync`. To add a placeholder, extend `SnippetTemplate.Placeholder.Kind`, its parser and renderer, add it to `SnippetEditorView.placeholderHelp` (the *Insert Placeholder* menu), and test it in `SnippetTemplateTests`.

## Tests

- `CortexCore/Tests/CortexCoreTests/Snippets/`: `SnippetStoreTests` (unique names and keywords, normalising), `SnippetTemplateTests` (placeholders, Raycast spellings, rendering), `RaycastSnippetsTests` (against `Fixtures/raycast-snippets.json`: dry run, duplicates, unchanged on re-import, keyword conflicts, export round trip) and `SyncSnippetTests`. Search ranking is tested there too.
- `CortexTests/Modules/Snippets/`: `SnippetsScopeTests` (the `;` scope, fill-in form state, keys, restoring the clipboard), `KeywordExpansionTests` (the buffer and which keys reset it) and `SnippetEditorModelTests` (save errors, switching, tags, duplicate, delete, preview).
- Manual: [MANUAL_TESTS.md](../MANUAL_TESTS.md) M14 (editor), M15 (snippets in the palette), M16 (keyword expansion in real apps), M17 (Raycast import and export) and M19 (sync).
