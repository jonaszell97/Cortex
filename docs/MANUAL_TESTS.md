# Manual tests

What the automated tests cannot cover: how real apps read the pasteboard and react to ⌘V, password managers, the lock screen, system prompts, signing and the look of the palette. These are the parts that break between macOS releases, so run this list:

- before calling a phase done,
- after every macOS update (including point releases),
- after changing anything in `Cortex/Host/Palette/`, `Cortex/Host/Pasting/`, `Cortex/Host/StatusMenu/`, `Cortex/Host/Settings/`, or a module in `Cortex/Modules/` (the checks of that module: M14–M17 for Snippets, M25 for the Reading List, M29–M31 for the Knowledge base, M18 for Quick Actions, M23 for Commands, M24 for AI, M20 for Scrolling, M21 and M22 for Emoji and Symbols, M28 for the Calculator, M26 for the Color Picker, M27 for Text Recognition, most of M2–M11 for Clipboard),
- for [M19](#m19-sync), after changing anything in `Cortex/Modules/Sync/`, a module's sync contribution, `CortexCore/Sources/CortexCore/Sync/` (or a `…+Sync.swift` handler next to a store) or `sync-server/`.

It takes about 65 minutes, plus about 20 for M19, which needs two Macs and the deployed server and can be skipped when sync isn't touched. Record each run in the [log](#log) at the end.

## Automated first

Run both test suites before starting. Both must pass.

```bash
make test
```

```bash
make test-app
```

If sync is involved, also:

```bash
cd sync-server && uv run pytest
```

| Suite | Covers |
| --- | --- |
| `make test` (CortexCore, `swift test`) | Encrypted database and blob store, migrations, de-duplication, full-text search, sensitive-text indexing, detecting secrets in unmarked text (tokens, keys, passwords, and ordinary text left alone), pin, delete, clear, retention, Pastebot importer against a fixture, snippet storage (unique names and keywords), the `$` commands (reading the query, suggestions, field values, `$disk`'s volumes and table, `$mem` from `vm_stat`, `ps` and `/proc/meminfo` samples, `$cpu` from `top` and `/proc` samples, `$gpu` from `ioreg`, `nvidia-smi` and `amdgpu` samples, the hosts of `~/.ssh/config`), snippet search ranking, placeholder rendering (Raycast spellings included), the emoji data, search (names, keywords, shortcodes, German, ranking), skin tones and usage decay, Raycast snippet import against a fixture (dry run, duplicates, unchanged on re-import, keyword conflicts) and export round trip, the built-in text actions, the JSON formatter, TOML action files and their error messages, file actions against real files (sips, PDFKit, zip, and ffmpeg when installed), output names that never replace a file, shell actions (placeholders as environment variables, hostile file names and text, stdin/stdout, failures, cancelling), and sync: the `v4_sync`/`v5_sync_synced` bookkeeping for every store method, the key, ID and pairing-code crypto (pinned against reference values), the engine with two databases against a fake server (convergence, concurrent edits, crashes between apply and cursor, epoch resets, wrong key, unknown payload version), and clips, snippets, reading list links and action files through it (blobs, merges, deletes vs. purges, filters, adopting identical snippets, name and keyword clashes, `.conflicts/`), the reading list (normalizing links, saving one again, read state, purging read links, search order), the calculator (numbers and the decimal comma, precedence, unfinished versus wrong input, functions, rounding and formatting, every kind of unit, exact factors, the `in` rule, German names, equivalents), the AI actions: the OpenAI requests and answers against canned responses (JSON schema requests included), error messages, list prices and usage totals, and the knowledge base: front matter, classifying paths, the index and its ranking, `@project` and `#tag`, to-do lists and checklists, edits and moves, the git history, the Outline and Trello importers against recorded exports, the skills links, `cortex-mcp` spoken to in JSON-RPC (tools, resources, prompts, roots), the knowledge folder through the sync engine (paths at any depth, blobs, `.conflicts/`, a missing or moved folder), and filing with AI (requests, reading answers, writing and applying proposals) |
| `uv run pytest` (`sync-server/`) | The server API against a temporary database: auth, last-writer-wins and idempotent pushes, cursor paging, the `seq` counter after pruning, blobs, size limits, epochs, and the protocol fixtures that the Swift tests replay |
| `make test-app` (CortexTests, hosted in the app) | Reading each kind of pasteboard content (text, RTF, HTML, PNG/TIFF/JPEG, files, password-manager markers), writing clips back in rich and plain mode, skipping the app's own pastes, pause, ignore list, flagging text that looks like a secret (and not when switched off), size limit, palette key bindings, palette selection and filtering, the `:` emoji scope (grid movement across rows and categories, search, frequently used row, skin tone and usage settings), the `::` symbol scope (this Mac's symbol list with localised copies and too new symbols left out, search ranking and keywords, the PNG a symbol pastes as), settings defaults, the `;` snippet scope and fill-in form state, fill-in keys, snippet text writes and the clipboard restore after an expansion, the keyword buffer and which keys reset it, the snippet editor (save errors, switching, delete, preview), the `+` reading list scope (order, adding a typed or copied link, links and titles from the pasteboard, opening marks read, copying, ⌘R, ⌘E, ⌘⌫), the `=` calculator scope (rows for calculations, conversions and quantities, German numbers, errors, pasting and copying, ⇥, recent calculations, stored settings), the `>` actions scope (input, filtering, previews, ⌘K), the `$` commands scope and form (typed arguments, suggestions from the clipboard and the history, ↑↓ into them, choices, paths and drops, ⏎ rules, remembered options), action input from the pasteboard, reloading the actions folder after an in-place edit, usage ordering, scroll settings, the step size slider and which scroll events count as trackpad or mouse and get reversed or stepped, sync settings and filters, status texts and the backoff schedule, and setting up, pairing, failing and disconnecting a `SyncService` against a stub server, the AI module: the API key, models per vendor, usage totals that survive a relaunch, the AI actions following the module's switch, and sensitive input never offered to or sent by them, and the knowledge base: the `?` and `!` scopes (rows, capture, keys, reloading on file changes), the note editor's model, the browser's model, the skills links and the MCP line, the folder's sync contribution, and `$note`, `$todo` and `$tidy` with their review overlays |

`make test-app` uses a private pasteboard and a temporary database, never your clipboard or history. It is signed ad hoc so it runs over SSH too.

## Setup

1. At the Mac (not over SSH), open `Cortex.xcworkspace` in Xcode and run the **Cortex** scheme (⌘R). This builds with the Apple Development certificate, which the Accessibility permission and the Keychain item are tied to.
2. Optional: watch the app's log in Terminal while testing.

   ```bash
   log stream --predicate 'subsystem == "dev.jonaszell.cortex"' --level debug
   ```

Tested apps, unless a step says otherwise: TextEdit, Safari, Terminal, Xcode, Mail, and one Electron app (Slack, VS Code or Discord).

If pasting does not work although Cortex is switched on under Accessibility, the permission is pinned to an older (unsigned) build. Reset it, relaunch Cortex and grant it again:

```bash
tccutil reset Accessibility dev.jonaszell.Cortex
```

## Checks

### M1. Launch

1. Launch the app (or relaunch it from Xcode).
   - The brain icon appears in the menu bar. No "database can't be opened" alert, no Keychain prompt.
   - If Accessibility is missing, the onboarding window opens. Grant it, and the window shows "Access granted" within a second or two.
2. Quit from the status menu and run again. The history from before is still there.

### M2. Recording from real apps

The unit tests use synthetic pasteboard content; this checks what real apps put there.

| Copy | Expected in the palette (⇧⌘V) |
| --- | --- |
| A sentence in TextEdit (plain text document) | Text icon, TextEdit's app icon, "just now" |
| Bold text from a web page in Safari | Rich-text icon; preview pane shows the full text |
| An image in Safari (right-click → Copy Image) | Thumbnail in the row, image in the preview |
| A screenshot to the clipboard (⌃⇧⌘4) | Thumbnail; preview shows the screenshot |
| Two files in Finder | One entry listing both file names; preview lists both with their folders |
| A cell range in Numbers or Excel, or a paragraph from Pages or Word | Rich-text entry, not an image |

### M3. Pasting into real apps

For each tested app, place the cursor in a text field or editor, open the palette and:

| Keys | Expected |
| --- | --- |
| ⏎ on a rich-text item | Pastes with formatting where the app supports it (bold stays bold in TextEdit, Mail) |
| ⇧⏎ on the same item | Pastes plain text |
| ⌘1, ⌘2 | Paste the first and second item directly |

Check in every app:

- The text lands in the app you were in, at the cursor, and that app keeps focus.
- In Terminal, ⇧⏎ pastes plain text and the palette does **not** reopen (⇧⌘V is its hotkey).
- In Safari, test both the address bar and a text field on a web page.
- After pasting, the pasted item moves to the top of the list. It is not added a second time.

### M4. Copy only

1. Select an item, press ⌥⏎. The palette closes and nothing is pasted.
2. Press ⌘V yourself. The item is pasted.

### M5. Images and files

1. Paste an image item into a Mail message and into a Notes note. The image appears.
2. Paste a files item into a Finder window (⌘V in an empty folder). The files are copied there.
3. Paste the files item with ⇧⏎ into TextEdit. Their paths are pasted as text.

### M6. Password manager

1. Copy a password from your password manager (copy the password field, not the username).
2. In the palette, the item has a key icon and shows `••••••••`. The preview pane says "Sensitive" and "Hold ⌥ to reveal".
3. Hold ⌥: the row and the preview show the password. Release: masked again.
4. Select it and press ⏎ in a password field (a website login form). The correct password is pasted.
5. In TextEdit, type and copy a made-up token such as `ghp_` followed by 36 letters and digits, then the word `hello`. The token is masked in the palette, `hello` is not. Switch off Settings → Clipboard → "Detect passwords and tokens" and copy another made-up token: it is shown in clear.

### M7. Panel behaviour

1. Open the palette over a full-screen app. It appears on top, on the current Space.
2. With two displays, move the mouse to the other display and open the palette. It opens centred on that display.
3. Esc closes it. Clicking outside it closes it. Both times the previous app has focus and you can type into it immediately.
4. While the palette is open, the app you came from still shows as active in the menu bar (the palette never takes focus away from it).
5. Click a clip: it is selected and its preview shows at once, as fast as with the arrow keys. Double-click one: it is pasted. The same in the `;` snippets and `>` actions lists.

### M8. Lock screen

1. Open the palette, hold ⌥ so a sensitive item is revealed.
2. Lock the screen (⌃⌘Q) and unlock.
3. The palette is closed. Opening it shows the sensitive item masked.

### M9. Status menu

1. Status menu → Pause Recording. The menu bar icon changes to a pause symbol, and the menu item has a checkmark.
2. Copy something in TextEdit. It does not appear in the palette.
3. Unpause from the status menu. The icon is the brain again, and new copies are recorded (the copy from step 2 is not picked up later).
4. Status menu → Clear History… → Clear History. Only pinned items remain.
5. The menu reads, each group after a separator: Open Cortex (⇧⌘V) and Settings… (⌘,); Pause Recording and Clear History…; Snippets…; Quick Actions (⌃⌥⌘A); the sync line and Sync Now (only while sync is set up); Grant Accessibility Access… (only without it); Quit Cortex. Snippets… opens the editor, Quick Actions opens `>`.
6. Run a slow quick action (a file with `command = 'sleep 30'`) and open the menu: the job is listed under Quick Actions and its progress updates while the menu stays open; the icon is a progress ring, also while recording is paused. Choosing the job cancels it.
7. Drop a file from Finder on the menu bar icon: the palette opens `>` on it. Switch Quick Actions off and drop again: nothing happens, and Quick Actions and its jobs are gone from the menu.
8. While sync is set up and a sync is running, Sync Now is greyed out.

### M10. Settings window

1. Status menu → Settings…. The window opens in front, and Cortex appears in the Dock and in ⌘Tab. Switch to another app and back with the Dock icon or ⌘Tab: the window comes back. Closing it returns focus to the previous app, and the Dock icon goes away.
2. Open Settings and the snippet editor, minimize the editor, close Settings: the Dock icon stays, and clicking it brings the editor back. Close the editor: the icon goes away.
3. Clipboard → Ignored apps → Add App…: the file picker opens in /Applications. Pick TextEdit; it appears with its icon. Copies in TextEdit are no longer recorded. Remove it with the minus button.
4. Toggle "Paste as plain text by default". The hint bar at the bottom of the palette swaps "Paste" and "Paste as text".
5. Change the hotkey in "Open palette" to something else, use it, then set it back to ⇧⌘V.
6. The sidebar lists General and every module in order: Clipboard, Snippets, Quick Actions, Emoji, SF Symbols, Scrolling, Sync. Scrolling and Sync are greyed out until switched on. Each page starts with the module's symbol, summary, trigger and an Enabled switch; the settings of a module that is off are greyed out but visible.
7. Switch Emoji off: the palette's placeholder loses ": emoji", and `:smile` searches the clipboard history. Switch it on again: `:` works as before.
8. Switch Quick Actions off: ⌃⌥⌘A and ⌃⌥⌘S do nothing (and reach the frontmost app), Quick Actions is gone from the status menu, ⌘K on a clip shows no hint, and a Shortcuts run of "Transform Text with Cortex" fails with "Quick Actions are switched off in Cortex Settings". Switch it on: all of it works again without a relaunch.
9. Switch Clipboard off: copies are not recorded, and the empty palette lists the triggers (`;`, `>`, `:`, `::`). Switch it on: copies made meanwhile do not show up, new ones do.
10. Switch Snippets off while keyword expansion is on: typing a keyword does nothing, and ⌘E on a clip shows no hint. With every module that needs Accessibility switched off, General → Permissions is empty and the status menu does not offer to grant it.

### M11. Pastebot import (once, while Pastebot is installed)

1. Settings → Import → Import History….
2. macOS may ask whether Cortex may access data from other apps. Allow.
3. The confirmation lists the history and each saved pasteboard (for example "Helpful Things") with item counts.
4. Import. The result reports how many items were imported and how many were already present.
5. In the palette: old Pastebot items appear at their original dates with their original apps, and items from saved pasteboards are pinned.

### M12. Without Accessibility (after macOS updates)

1. System Settings → Privacy & Security → Accessibility: turn Cortex off.
2. Open the palette and press ⏎ on an item. Nothing is pasted, the item is on the clipboard (⌘V pastes it), and the onboarding window opens.
3. Turn the permission back on.

### M13. Launch at login (only for the copy in /Applications)

1. Run the installed copy from /Applications, open Settings and turn on "Launch at login".
2. Log out and in again. The menu bar icon appears without starting the app by hand.

### M14. Snippet editor

1. Status menu → Snippets…. The editor opens in front with the list in the sidebar, a search field and + at its top. Each row shows the name, the text's first line and the keyword. Clicking a snippet highlights it and shows it on the right; its name, the title, is fully visible below the toolbar, in light and dark mode.
2. ⌘N, name it "Test sig", keyword `;tsig`, type `test` into Add tag and press ⏎, then `mail,`: two tag chips. Insert Placeholder → `{cursor}` after typing `Best regards`, then a line break and `Alex, "{date:yyyy-MM-dd}"`: both placeholders are tinted and the quotes stay straight. Preview shows `Best regards▏`, a line break, and `Alex, "…"` with today's date.
3. ⌘S. The snippet appears in the list with its keyword. Remove the `mail` chip with its ×: Save is enabled; ⌘S.
4. ⌘N again, name it "test SIG" (same name, other case), add a text, ⌘S. The footer says a snippet with that name already exists; nothing is saved.
5. Edit the text of "Test sig", then click another snippet without saving: the edit was saved. Edit again and close the window: it asks Save / Cancel / Don't Save.
6. Search for `tsig`: only "Test sig" is left. Clear the search. Right-click it → Duplicate: an unsaved "Test sig copy" without keyword; ⌘S. Right-click → Copy, then ⌘V in TextEdit: the text with its placeholders as written.
7. Select a scratch snippet in the list and press ⌫, confirm: it is deleted and the next one is selected.

### M15. Snippets in the palette

Use a snippet with `{cursor}` and one with a named fill-in such as `Hi {name}, about {topic}`.

1. Open the palette and type `;`. The list shows snippets, most used first, and the hint bar shows Paste, Copy, Edit, New snippet. The preview shows the text with its placeholders.
2. Type `;tsig` and `;test`: the snippet is found by keyword and by name. Delete the `;`: the clipboard history is back.
3. In TextEdit, Mail, Safari (a text field) and Slack: select the cursor snippet and press ⏎. The text is pasted as plain text, the cursor ends up where `{cursor}` was, and the app keeps focus.
4. Select the fill-in snippet and press ⏎. A form with "name" and "topic" opens, the first field focused. Tab moves to the second field. ⏎ pastes the text with both values filled in.
5. Open the form again and press Esc: back to the snippet list, nothing pasted. Esc again closes the palette.
6. ⌥⏎ on a snippet only copies it; ⌘V pastes it.
7. The pasted snippet does not appear as a new item in the clipboard history.
8. ⌘E on a snippet opens it in the editor. In the clipboard list, ⌘E on a text clip opens a new snippet with that text.

### M16. Keyword expansion

1. Settings → Snippets: "Expand keywords as you type" is off. Turn it on. No warning appears (Accessibility is granted). If macOS asks for Input Monitoring instead, note it in the log below.
2. Copy some text, then in TextEdit type `Hello ;tsig`. The keyword is replaced by the snippet, the cursor lands at `{cursor}`, and ⌘V afterwards still pastes the text copied before (the clipboard was restored).
3. Repeat in Mail, Slack and a Safari text field. In Safari's address bar too.
4. Type `foo;tsig` (no space before the keyword): nothing expands.
5. Type `;ts`, click somewhere else in the same document, type `ig`: nothing expands (the click cleared the buffer). Same with `;ts`, ⌘Tab to another app and back, `ig`.
6. Type `;tsix`, ⌫, then `g`: it expands (backspace is followed).
7. Type the fill-in snippet's keyword: the palette opens with the form. ⏎ pastes into the app you typed in; Esc closes the palette and leaves the keyword deleted.
8. Type the keyword into a password field (a website login): nothing expands.
9. Type the keyword into the palette's own search field and into the snippet editor: nothing expands.
10. Turn the setting off and type the keyword again: nothing expands. `log stream --predicate 'subsystem == "dev.jonaszell.cortex"' --level debug` shows "Keyword expansion off" and never any typed text.

### M17. Raycast snippet import and export

On the other Mac, Raycast → Export Snippets, and move the file over AirDrop (see [Snippets](modules/SNIPPETS.md)).

1. Settings → Snippets → Import → Raycast snippets (JSON) → Import…, pick the file. A preview lists every snippet as New, Changed, Unchanged, Duplicate or invalid, with notes for keywords already in use and for Raycast-only placeholders such as `{selection}`. Nothing is imported yet.
2. Cancel. Snippet count in Settings → Snippets is unchanged.
3. Import again and confirm. The result reports how many were added. Spot-check a few snippets with placeholders in the palette.
4. Import the same file a second time: everything is Unchanged and Import is disabled.
5. Export… to the Desktop. The file is readable JSON with `name`, `text` and `keyword`, and `ls -l` shows `-rw-------`. Delete it afterwards, and the Raycast file on both Macs.

### M18. Quick actions

Needs `brew install ffmpeg imagemagick`. Settings → Quick Actions lists the tools as found.

1. Copy `{"b":1,"a":[1,2]}` somewhere, open the palette and type `>`. The right pane says "Clipboard" and shows the text; "Format JSON" is selected and its result is previewed with `b` before `a`. ⏎ pastes the formatted JSON into TextEdit. It appears at the top of the clipboard history with Cortex as its source.
2. In the clip list, select an older text clip and press ⌘K: the actions now say "Selected clip". Pick "QR Code", ⌥⏎: the code is the newest clip, with its thumbnail, and Preview (File → New from Clipboard) shows a scannable code. ⌘K on a sensitive clip (a password) and "Base64 Encode": the result is masked in the history too.
3. "Count Words" on any text posts a notification with the counts. The first notification asks for permission; allow it.
   Copy `Hi {name},` and run "Create Snippet" (`>snip`): the preview shows the text, ⏎ opens the snippet editor on a new, unsaved snippet with exactly that text, and nothing is pasted or added to the history.
   Select `$ echo hello` in a text editor, press the selection hotkey and run "Save as Command": the preview shows `echo hello`, ⏎ asks for a name. `kill` asks again, saying it is a built-in's name; `two words` asks again too. `hi` shows a confirmation (Save is not red) with `$hi`, the command and `~/.config/cortex/actions/hi.toml`; Save writes it, a notification says so, the selection is unchanged, and `$hi` runs it at once. Cancel in either alert writes nothing.
   Copy `7` and type `>pad`: below the preview, Options show Side (Left), Length (10) and Character (0), and the preview is `0000000007`. Press ⇥: the cursor is in Length; type `3` over it and the preview is `007` at once. ⇥ to Character and type `x`: the field holds just `x` (not `0x`) and the preview is `xx7`. Click Right: `7xx`. Clear Length: the preview says "Length must be a whole number from 1 to 1000" in red. Set it back to 3, press ↓ and ↑: the cursor is back in the search field. ⏎ pastes `7xx`. Close and reopen the palette, `>pad`: the options are still Right, 3, `x`.
4. In Finder, select a HEIC photo and press ⌃⌥⌘A. The first time macOS asks whether Cortex may control Finder: allow it (the palette closes; press the hotkey again). The pane says "Finder selection" with the file name; "Convert Image to JPEG" is in the list (type `jpg` if it is not first). ⏎: a notification says it was created, `IMG_….jpg` is next to the original, and clicking the notification selects it in Finder. Run it again: the second result is `IMG_… 2.jpg`, the first is untouched.
5. Select a 20–60 s video, ⌃⌥⌘A, "Convert Video to GIF". After about a second a card appears in the top-right corner of the screen with the mouse, below the menu bar: action name, file name, a filling progress bar and a percentage. The menu bar icon is a ring filling clockwise; the status menu lists the job too. Typing in the app in front keeps working while the card is up. When the job ends, the card fades out and the icon is the brain again. Run it again and click the card's ✕ (first click, without activating anything): it says "Cancelling…", disappears, no notification, no half-written GIF next to the video. Cancelling from the status menu works the same way. Start two conversions at once: the card shows two rows.
   Convert a single small image: it finishes before the card would appear, and nothing flashes.
6. Select two PDFs and run "Merge PDFs"; select a folder and run "Compress to ZIP". Check the results open.
7. Drag a PNG from Finder onto the menu bar icon: the icon highlights and the palette opens on the dropped file. Open the palette with ⇧⌘V, then drag a file from Finder onto it: it stays open and switches to the file's actions. Click into Finder without dragging: the palette closes as before.
8. Copy a screenshot (⇧⌃⌘4), press ⌃⌥⌘A outside Finder, "Resize Image to 800 px": the result is in Downloads.
9. Finder: right-click a file → Quick Actions (or Services) → "Open in Cortex" opens the palette's actions on it. If the entry is missing, enable it in System Settings → Keyboard → Keyboard Shortcuts → Services, and note it in the log below.
10. Create `~/.config/cortex/actions/upper.toml` with `name = "Shout"`, `accepts = ["text"]`, `command = "tr a-z A-Z"`. Without restarting, `>shout` finds it and ⏎ pastes the uppercased clipboard. Break the file (rename `command` to `comand`) and save: Settings → Quick Actions lists the file with "Unknown key “comand”", and the action is gone from the palette.
11. Shortcuts app: a new shortcut finds "Transform Text with Cortex"; with action "Base64 Encode" and text `hello` it returns `aGVsbG8=`. "Run Cortex Action on Files" with "Convert Image to JPEG" on a Finder file writes the JPEG next to it.
12. Act on the selection. Copy `keep me` (with a rich-text source such as TextEdit if you like). In TextEdit type `hello world`, select it and press ⌃⌥⌘S. The palette opens on the actions with the pane saying "Selection" and the text; the selection stays highlighted in TextEdit. Pick "Uppercase", ⏎: the selection becomes `HELLO WORLD`. Paste somewhere else: `keep me` is still the clipboard, and the history has neither `hello world` nor `HELLO WORLD`.
    Select text again and use "Base64 Encode" with ⌥⏎: nothing is replaced, the clipboard now holds the result. Esc instead: nothing changes and the clipboard is still as it was. Press ⌃⌥⌘S with nothing selected: a notification says nothing is selected. Try it in Safari, a Chrome or Electron app (VS Code, Slack) and Terminal; note apps where it does not work in the log below. Without Accessibility permission the onboarding window opens instead.
13. Shortcut fields (Settings). Click "Act on the selection": the field shows an accent border and "Press shortcut" at once, also when Settings was not the front window (the first click records). Press ⌥⌘S: it is shown as ⌥⌘S and the hotkey works in TextEdit. Repeat ten times, alternating ⌥⌘S and ⌃⌥⌘S, and once re-recording the shortcut that is already set. Click ✕ next to a field: it is cleared at once and the hotkey stops working (click it right after a failed recording, too). Press plain `S` or ⌘C while recording: it beeps and says why, still recording. Esc cancels, ⌫ clears. Start recording, then close Settings with ⌘W: all hotkeys (⇧⌘V) still work.
14. One file format. Copy the four example files from the README (`shrink-video.toml`, `github.toml`, `deploy.toml`, `tracking.toml`) into `~/.config/cortex/actions/`. Settings → Quick Actions lists all four without problems, the ones with a trigger with `$gh owner/repo`, `$deploy …` and `$track …`. Copy `1Z999AA10123456784` and type `>`: "Track Parcel" is in the list and previews the UPS URL; copy `hello`: it is not, but `$track 1Z999AA10123456784` previews the same URL. An old command file from before (a `trigger`, a `command`, no `accepts`) still works the same way, and so does an old action file. Add `argument = "optional"` to `tracking.toml`: Settings reports "Give either “accepts” or “argument”, not both".

### M19. Sync

Needs two Macs with the same build installed (`make install` on both), the server deployed ([Deployment](SYNC.md#deployment)) and both Macs able to reach it. Back up `~/Library/Application Support/Cortex/` on both before the first run. Settings → Sync shows the status; the status menu has the one-line version.

1. **Setup.** First Mac: Settings → Sync → switch Enabled on, Set up this Mac, enter the server and token, Test Connection says "Connected", then Set Up. The status goes to "Last synced … · N sent". Copy Pairing Code; the clip appears in the palette masked. Second Mac: Join with pairing code, paste. The history merges without duplicates, each snippet is there once, and actions from the other Mac appear in the palette (`>`). Joining with a changed character in the code fails with a clear message and stores nothing.
2. **Sync with the server unreachable.** On one Mac go offline from the server (turn off the VPN that reaches it, for example). Open the palette, paste, type in a snippet keyword, and run an action: no delays, no alerts. After Sync Now (or the next automatic attempt) the status menu says "Sync paused: server unreachable" and Settings says "Server unreachable — is Tailscale connected?". Reconnect and choose Sync Now: "Synced just now".
3. **Copy on one Mac, close the lid, open the other.** Copy a unique text on Mac A, close the lid. Open Mac B (awake, with the palette closed): the clip is in B's palette within a minute of B waking (A pushed it before sleeping).
4. **Deletes.** Delete one clip on A with ⌘⌫ in the palette: it disappears on B after both sync. Status menu → Clear History… on A: B's history is unaffected. A clip that was deleted and then copied again on B is back on A.
5. **Snippet edited on both Macs while offline.** Turn the network off on both, edit the same snippet on both (the second edit later), turn it on, sync both twice: both show the later edit, and there is no duplicate. Give two different new snippets the same keyword the same way: the keyword ends up on the later one on both Macs.
6. **Action edited on both.** Edit the same `~/.config/cortex/actions/*.toml` on both while offline, the second one later, then sync both: both files hold the later content, and the other version is in `.conflicts/` on at least one Mac. The palette shows one entry for the action, not two. Delete an action file on A: on B it moves to `.conflicts/` and leaves the palette.
7. **Sensitive clips.** Copy a password from the password manager on A. With "Sensitive clips" off (default), it never reaches B. Turn it on on both, sync: it arrives on B, masked, and still revealed only with ⌥.
8. **Disconnect.** Settings → Sync → Disconnect on B: the status menu line goes away, local data stays, and the Keychain items `sync-key` and `sync-token` are gone (Keychain Access, service `dev.jonaszell.cortex`).
9. **What to sync follows the modules.** Settings → Sync → What to sync lists Clipboard history (with Sensitive clips and Largest clip below it, greyed while it is off), Snippets, Reading list and Your quick actions. Switch Snippets off in its own page: its row disappears from Sync's page, and a snippet added on A no longer arrives on B (nor do B's on A). Switch it on again: the snippets added meanwhile sync after the next cycle, and the keyword table on B knows them. Switch "Your quick actions" off in What to sync: a new action file on A stays there; on again, it arrives.
10. **Reading list.** Add a link with a title on A and mark another read: after both sync, B lists both, the second one read. Edit the note on B: it shows on A. Delete a link on A: it goes on B. With *Delete read links after* set to 1 day on A only, a link read more than a day ago disappears from A at the next launch and stays on B.
11. **Knowledge base.** Deploy the server from this commit first (it has to know the `knowledge` collection). On A, save a note with `?` in a project, add a picture to that project's `assets/` (over 256 KB) and add a to-do with `!`: within a minute of syncing both, B's `?` and `!` list them and the picture is there, with the same modification dates. Edit the note on both while offline (B later), sync both twice: both have B's text, and A's is in `~/.config/cortex/knowledge/.conflicts/<project>/notes/`. Rename a note in the editor on A: on B the new name appears and the old one moves to `.conflicts/`. Delete a skill on A: on B its folder goes (the files in `.conflicts/`) and its link leaves `~/.claude/skills/`. A git commit on either Mac does not start a sync cycle (the log shows no cycle a minute after a change apart from the change's own), and `.git/` never arrives on the other Mac. Settings → Sync → What to sync lists *Notes, skills and to-dos*; switched off, a new note on A stays there.

### M20. Scroll reversal

Quit Scroll Reverser (and any other app that changes scrolling) first. Natural scrolling is on in System Settings.

1. Settings → Scrolling: Enabled is off (on if "Adjust scrolling" was on before modules), Reverse vertical and Mouse are on, the step size slider is at about a fifth. Switch Enabled on. No warning appears (Accessibility is granted).
2. In Safari and in a Finder list, scroll with the trackpad: natural direction (content follows the fingers), including the momentum after lifting them. Scroll with the wheel mouse: classic direction (wheel down moves the content up).
3. Scroll the trackpad quickly and, while it is still coasting, turn the mouse wheel: each keeps its own direction.
4. Horizontal trackpad swipes in a wide spreadsheet or a timeline: unchanged, with Horizontal checked too (only the mouse is reversed).
5. Turn the mouse wheel one notch at a time in a long page: each notch scrolls about three lines. Move the step size slider to the right: notches scroll further, the trackpad is unchanged. All the way left: notches scroll as without Cortex. Spinning the wheel fast still accelerates.
6. While the palette is open and a quick action is running, scrolling elsewhere does not lag.
7. Switch Enabled off: the mouse follows the system direction again. The log shows "Scroll reversal on" and "Scroll reversal off".

### M21. Emoji search

1. Open the palette and type `:`. The hint bar shows Paste, Copy, Skin tone, Move. The grid shows every category with its title (no "Frequently used" before the first use), the first emoji selected, and below it the selected emoji large with its name, shortcodes and code point.
2. ←, →, ↑, ↓ move the selection; → at the end of a row continues in the next row, ↓ at the end of a category goes to the first row of the next one. The grid scrolls along and keeps the selection (and the category title) in view. In the clipboard list (no `:`), ← and → still move the caret in the search field.
3. Type `:thumbs`. 👍 and 👎 are found; the first is selected. `:thumbsup:` (with the closing colon) and `:+1` find 👍 too. `:fire` puts 🔥 first. `:daumen` (German is among the system languages) finds 👍 and the name below the grid is "Daumen hoch". Type `:zzzz`: "No matching emoji".
4. Press ⇥ a few times: the "Skin tone" hand in the bottom corner changes through the five tones and back to yellow, and 👍, 👋 and the other hands in the grid follow. Emoji without variants (🔥) stay as they are.
5. In TextEdit, Mail, Safari (a text field), Slack, Messages and Xcode: select an emoji with ⏎ and the palette closes, the emoji is pasted at the cursor, and the app keeps focus. A double click on an emoji pastes it too. In Terminal, the emoji appears at the prompt.
6. Copy some text first, then paste an emoji with ⏎: ⌘V afterwards still pastes the text copied before (the clipboard is restored once TextEdit has read the emoji). Pasting adds nothing to the clipboard history, neither the emoji nor the restore.
7. ⌥⏎ copies the emoji without pasting it; ⌘V pastes it. The emoji is the newest clip in the history. ⌘1 pastes the first emoji of the grid.
8. Reopen the palette and type `:`: a "Frequently used" row with the emoji just used comes first, most used on the left. Quit and start Cortex again: the row and the skin tone are still there.
9. Without Accessibility (as in M12): ⏎ copies the emoji and the permission prompt appears.

### M22. SF Symbols search

1. Open the palette and type `::`. The hint bar shows Paste name, Paste image, Copy name, Copy image, Move. The grid shows "All symbols" (several thousand, drawn as you scroll; scrolling and holding an arrow key stay smooth), the first selected, and below it the name in monospace, the macOS version it needs and its search words.
2. Type `::star`: `star` comes first, then `star.fill`, then the other `star…` names. `::star.f` finds `star.fill`. `::mail` also finds `envelope` (a keyword). `::lock open` finds `lock.open` and `lock.open.fill`. `::zzzz`: "No matching symbols". Arrow keys work as in the emoji grid; ⇥ does nothing.
3. In Xcode (a Swift file) and TextEdit: select `star.fill` with ⏎. The text `star.fill` is pasted, the palette closes, the app keeps focus. A double click on a symbol pastes its name too.
4. In Keynote (or Pages, Figma, Slack): ⇧⏎ on `star.fill` pastes a black star picture with a transparent background, sharp when enlarged to about 250 pt. A multicolor symbol (`::cloud.sun.rain`) pastes as a black silhouette.
5. Copy some text first, then paste a symbol with ⏎ and with ⇧⏎: ⌘V afterwards still pastes the text (restored once TextEdit has read the symbol). Nothing is added to the clipboard history.
6. ⌥⏎ copies the name, ⌥⇧⏎ the picture; neither pastes. ⌘1 pastes the first symbol's name, ⌘⇧1 its picture.
7. Reopen the palette and type `::`: a "Frequently used" row comes first; it is separate from the emoji row (`:`). Type `:` and then a second `:` and the grid switches from emoji to symbols; delete one colon and it switches back.
8. None of the cells in the grid is empty (symbols that need a newer macOS than the installed one are left out).
9. Without Accessibility (as in M12): ⏎ copies the name and the permission prompt appears.
10. Copy `:8080` and `;sig`, open the palette and type `\:8080`, then `\;sig`: the clipboard list (not the emoji grid or snippets) shows each clip, and the hint bar is the clipboard one.

### M23. Commands

1. The list. Copy some text, open the palette and type `$`: the placeholder named "$ commands" before; the list has every command, each row in monospace as it is typed (`$kill node`, `$port 3000`, `$disk Macintosh HD`, `$mem`, `$cpu`, `$gpu`, `$open ~/Downloads`, `$code cortex`, `$term cortex`, `$clip …`, `$sound airhorn`, `$uuid`, `$token 32`, then your files' and, with AI on, `$ask …` and `$img …`), the title below. The pane of the selected one says what it does and what it takes ("Port: a number from 1 to 65535, required"), "⏎ fills it in" and "or type $port 3000"; ⏎ opens the form (step 13) and nothing runs. Rows show what you type, and the example only while nothing is typed: `$code` has `cortex` dimmed after it, `$code mathical` reads `$code mathical` with nothing dimmed (not `$code cortex`), and `$disk /mnt/usb @pi` keeps the `@pi`. Type `$po`: only the port command; `$kil node`: "No matching commands". Type `>`: neither "Kill Process" nor "Kill Process on Port" is listed, and `>port 3000` lists nothing. Settings → Commands lists every command with where it is from.
2. Start a server in Terminal: `python3 -m http.server 8765`. Type `$port 8765`. After a moment the pane shows "Kill Python?" (or the name `lsof` reports), the PID, your user, `TCP *:8765` and the full command line with `http.server 8765`; the pane's first line reads `$port 8765` in monospace and the hints bar says ⏎ Kill… with no ⌥⏎ (⌥⏎ beeps). Change it to `$port 8766`: "Nothing is listening on port 8766 …" plainly in grey with an info symbol, not in red, the hints bar back to ⏎ Run and paste, ⌥⏎ Run and copy, and ⏎ beeps. `$port abc`: a red "not a port number" (an error, unlike the grey notice), and ⏎ beeps. `$kill :8765` finds the server too. Copy `8765` and type `>`: "Kill Process on Port" is in the list and previews the server, the header saying "Clipboard".
3. With `$port 8765`, ⏎: the palette closes and an alert asks "Kill Python?" with the same details, the Kill button red and default. Esc: nothing happens, the server keeps running, and the app that was in front has focus again.
4. ⏎ again and press ⏎ in the alert: the server stops at once (Terminal shows the prompt), a notification says "Ended Python (PID …) on port 8765", and focus is back in the app that was in front.
5. Start `sh -c "trap '' TERM; exec python3 -m http.server 8765"`, kill it the same way: about 3 seconds later the notification says "Force-killed …".
6. Open the alert for a running server, stop the server in Terminal (⌃C) and start it again (new PID), then press Kill: the notification says "Nothing is listening on port 8765 any more" and the new server keeps running.
7. `$port 22` with Remote Login on (or another port only root listens on): "Nothing is listening on port 22 (only your own processes are checked)", as a grey notice. Copy `22` and type `>`, choose Kill Process on Port, ⏎: a notification says "Nothing is listening on port 22 (only your own processes are checked)" (not "failed").
8. Docker Desktop (or OrbStack) running: `docker run -d --rm -p 8766:80 --name m23 nginx`. `$port 8766` previews "Stop container m23?" with the image and ports, and no mention of `com.docker.backend`. ⏎, ⏎: the container stops (`docker ps` no longer lists it), the notification says "Stopped container m23 on port 8766", and Docker and other containers keep running. `$port 8766` again: "Nothing is listening …".
9. `python3 -m http.server 8765` again. `$kill python` (or the name step 2 showed) lists it, with the command line; with two servers on different ports, `$kill python 8765` lists only one. `$kill <its PID>` finds it too. ⏎, ⏎ kills it: "Ended … (PID …)". `$kill loginwindow`: "loginwindow is not offered …" (a grey notice), and so is `$kill nope-nothing` ("None of your processes is called “nope-nothing”"). `$kill com.docker.backend` previews a warning that it stops all containers; press Esc.
10. Typing keeps the selection: type `$kill n`, press ↓ to "Kill Process on Port", go on typing `ode`: the selection stays. Its pane says what it takes, as the typed text belongs to `$kill`.
11. Your own commands. Create `~/.config/cortex/actions/gh.toml` with `name = "GitHub"`, `trigger = "gh"`, `url = "https://github.com/{argument}"`, `example = "owner/repo"`. Without restarting, `$gh` lists it as `$gh owner/repo`, and Settings → Quick Actions lists it under "Your actions" with `$gh owner/repo`. `$gh apple/swift` previews the URL and the hints bar says ⏎ Open, ⌥⏎ Copy link; ⏎ opens it in the browser. Add `deploy.toml` with `name = "Deploy"`, `trigger = "deploy"`, `command = "sleep 2; say {argument}"`, `confirm = true`: `$deploy hello` previews "Run Deploy?" with `sleep 2; say 'hello'`; ⏎ shows the alert, Run: after a second the progress card says Deploy / `Run Deploy` with a cancel button, then the Mac says "hello" and a notification says "Done". Remove `confirm`: the pane shows the line it will run, ⏎ runs it at once and the card says `$deploy hello`. Set the trigger to `kill`: Settings → Quick Actions lists "“kill” is the name of a built-in command" and `$kill` is the built-in again.
12. Switch Quick Actions off: Commands is off too and says it needs Quick Actions, and `$port 3000` searches the clipboard history. Switch it back on: `$` is there again.
13. The form. Copy `8765` (the server of step 2 running), copy some other text, then copy `8765` again. Type `$port`, ⏎: the list gives way to the form (the search field greyed out, still `$port`) with "Kill Process on Port", what it does, the Port field empty with the cursor in it and "required", and under it `8765` with "Clipboard", nothing more (the other text is no port). The hints bar says ⏎ Run, ⌥⏎ Run and copy, esc Back. ⏎ on the empty field beeps and outlines it in red. ↓: `8765` is in the field and after a moment the preview below shows "Kill Python?" (without a header line, the field shows what was typed) and the hints bar reads ⏎ Kill… with no ⌥⏎; ↑: the field is empty again. Type `87`: the suggestion stays; type `x`: it goes. Clear the field, ↓, ⏎: the alert asks to kill the server; Esc in it.
14. Type `$port`, ⏎, type `30`, Esc: the list is back with `$port`. ⏎: the form shows `30` again. Esc twice: the palette closes; open it, `$port`, ⏎: the field is empty. `$port abc`, ⇥: the form with `abc` and a red "Port: a whole number from 1 to 65535"; ⏎ beeps.
15. With AI on: copy a paragraph, type `$ask`, ⏎: the Prompt field is several lines high and empty, with the paragraph's first line under it and "Clipboard · … characters" when it is long. Type `Summarize:`, ⇧⏎ breaks the line; the clipboard entry is gone (it does not contain what was typed). Select all, delete, ↓, ⏎: the answer about the paragraph is pasted. `$img`, ⏎: the same form for the picture's description, and below it a Model option with the image model of Settings → AI selected and `gpt-image-2` next to it. ⇥ to it, → picks `gpt-image-2`; type a description and ⏎: the picture comes (Settings → AI → Usage counts it under `gpt-image-2`). `$img`, ⏎ again: `gpt-image-2` is still selected. Esc without running after changing it back: the next time it is still `gpt-image-2`.
16. A command file with `trigger = "reveal"`, `accepts = ["files"]`, `command = "open -R {input}"` (it takes files only): `$reveal`, ⏎, then drag a file with a space in its name from Finder onto the palette: the field shows `'~/…/its name'` (quoted), the palette stays open and ⏎ reveals the file. Type a path that does not exist: a red "Argument: no file or folder at …".
17. `$mem`: the pane draws it at once: the memory used of the physical memory (as "About This Mac" says) and what is free, the pressure badge (green "Normal" unless the Mac is short of memory), one bar growing in from the left split into App memory, Wired, Compressed and Cached files with their sizes below, a thin Swap bar with "… of …", then "Your largest processes": ten of your processes with their app's icon (a browser's helpers show the browser's), a bar for their share of the largest, and their size; the numbers are close to Activity Monitor's Memory tab. ⏎ in TextEdit (Format → Make Plain Text, a monospaced font) pastes the text table (Physical memory, Used, App memory, Wired, Compressed, Cached files, Swap used, the processes) with its columns lined up. ⇥ opens the form, whose Host field lists This Mac, selected, then the hosts of `~/.ssh/config` (not GitHub's); ←→ pick one and the pane follows. `$mem @raspberrypi` (or `$mem @rasp`, any Linux host there; the row keeps the `@raspberrypi` as typed, and the pane says "Loading Memory Usage on raspberrypi…" while it connects) shows that host after a moment: "raspberrypi · Linux" over the numbers, a server icon, Kernel instead of Wired, no Compressed while zswap is off, no pressure badge, and "Largest processes" of every user, close to what `free -h` and `top` say on it. `$mem @nas` (not in the config) shows a red "“@nas” is not a host in ~/.ssh/config. Hosts: …", and so does a bare `$mem @`; `$mem @raspberrypi @linode` says "One host at a time"; `$mem pi` is no host any more and is not accepted (the pane shows what the command takes); a host that is off shows ssh's own error after about 5 seconds; a Mac as host shows the same as `$mem` there, with "· macOS", the pressure badge and its processes' icons where the same app is installed here; a host running something else says only macOS and Linux hosts are read. `$cpu` (shown about a second after it is selected, while it samples): "… % busy" with the Mac's chip and core count, one bar of User and System with Idle below, a column per core rising to how busy it is (orange from 80 %, red from 92 %), the three load averages as chips (orange from 70 % of the cores, red past them), and "Busiest processes" of every user with their share of one core (over 100 % for a process using several); close to Activity Monitor's CPU tab, and `top` itself is not listed. `$cpu @raspberrypi` adds the temperature badge (green under 70 °C) and the board's model, like `top` and `vcgencmd measure_temp` there; a Mac host has no core columns and no temperature. ⏎ pastes the text table. `$gpu` (also after about a second): the chip and its GPU core count, a ring of how busy the GPU is, Renderer and Tiler bars beside it and the memory in use, then "Busiest processes" with their share of the GPU's time; WindowServer is usually among them, and playing a video or a game moves its process to the top, close to Activity Monitor's GPU column. A Mac host shows the same. `$gpu @raspberrypi` says it has no GPU Cortex can read (only NVIDIA through `nvidia-smi` and AMD through `amdgpu` are read on Linux); on a Linux host with one of those, each card shows its busy ring, memory of its total, temperature and power, then "GPU memory by process" like `nvidia-smi`.
18. `$disk`, ⏎: the pane draws the startup volume at once and ⏎ pastes its table (⇥ opens the form, which lists the mounted volumes, the startup volume first, and has a Host field); `$disk backup`, ⏎ pastes that volume's table: the name and file system, Total, Used with a percentage, Free and Purgeable, close to what Finder's Get Info and System Settings → General → Storage say. `$disk /` draws the pane: the drive's icon, name, file system and mount point, a ring filling up to the used percentage (purgeable space paler at its end; orange from 80 %, red from 92 %), the free space large beside it, and a bar with Used, Purgeable and Free below. `$disk @raspberrypi` draws the host's root file system with a server icon ("over SSH · ext4 · /"), close to `df -h /` there; `$disk /mnt/usb @raspberrypi` the file system that path is on, named "raspberrypi:/mnt/usb" (the form's Host field set to raspberrypi turns the field into a Path, with no volumes suggested; set back to This Mac it lists the volumes again). A Mac host works too (its file system from `diskutil`, "APFS"). `$disk usb @raspberrypi` says the path must start with /. `$disk raspberrypi` is a volume now: "“raspberrypi” is not a mounted volume". `$disk macintosh hd` (any case) and `$disk /` preview the same; `$disk Floppy` shows a red "“Floppy” is not a mounted volume. Mounted: …" and ⏎ beeps. With a USB stick or disk image mounted, it is listed and works too; eject it and it is gone the next time the form opens.
19. `$open ~/Downloads`: the pane shows the Downloads icon, the path and "⏎ shows it in Finder"; the hints bar says ⏎ Show in Finder, ⌥⏎ Copy path; ⏎ opens a Finder window on Downloads. `$open ~/Library/Preferences/.GlobalPreferences.plist` (a file) and `$open /Applications/Safari.app` (a package): Finder selects them in their folder, and Safari does not start. `$open /nope`: a red "No file or folder at /nope"; `$open Downloads`: "… is not a path". Copy a path with a space in it (⌥⌘C on a folder in Finder), `$open`, ⏎: the form suggests it, ↓ ⏎ opens it. With that path still copied, `>`: Open in Finder is listed and ⏎ opens it; copy a file in Finder (⌘C) and `>` lists it too; copy plain text and it is not listed.
20. `$code`, ⇥: the form lists the folders in `~/Developer` by name, the field marked "required". `$code`, ⏎: the form opens, and nothing else. `$co`: the hints bar has no ⌘E; `$code` (and `$code cor`): it shows "⌘E Edit projects.toml", and so does the form. ⌘E: the palette closes and VS Code opens `~/.config/cortex/projects.toml`; without the file, it is written first with every line commented out, and `$code cortex` still works. `$code cortex` (or `$code cor`): the pane shows `vscode://file/…/Cortex` and the hints bar says ⏎ Open in VS Code, ⌥⏎ Copy link; ⏎ opens it in VS Code in a new window, and the project open before stays in its own. `$code cortex` again: no new window, the Cortex window comes to the front. `$code pi` (SSH, below) also opens a new window. `$code my` with two projects starting with "my": "could be …: type more of the name". In `~/.config/cortex/projects.toml` add a `[pi]` with `host` an alias from `~/.ssh/config` and an absolute `path`: `$code pi` opens it over Remote-SSH. Break the file (`path = 3`): the preview shows "projects.toml: [pi] (line …): path is text in quotes"; fix it and the next keystroke previews again. `$code ~/.zshrc` (and a file with a space in its name, typed unquoted as copied): the pane shows `vscode://file/…`, ⏎ opens the file in VS Code. `$code`, ⇥, drag a file from Finder onto the palette: the field shows its quoted path and ⏎ opens it. `$code /nope`: a red "No file or folder at /nope".
21. `$term`: the pane says "⏎ opens it in Terminal" with the Terminal icon and your home folder, and the hints bar ⏎ Open in Terminal, ⌥⏎ Copy path; ⏎ opens a new Terminal window there, and nothing is pasted. `$term cortex` (or `$term cor`): a new window in `~/Developer/Cortex`. `$term ~/Downloads` and `$term ~/.zshrc` (a file: its folder, the home folder). `$term nope`: "No folder is called “nope”. Folders: …". ⌘E: VS Code opens `~/.config/cortex/terminal.toml`, written with every line commented out; add `app = "Ghostty"` (or another terminal you have) and `[dl]` with `path = "~/Downloads"`: `$term dl` opens it in that app and the pane names it. `app = "Nope"`: the pane shows "No app called “Nope” in Applications: …". `[pi]` with a `host`: "terminal.toml: [pi] (line …): unknown key “host”: a folder has a path".
22. `$uuid`: the pane shows a new UUID at once (uppercase, like `E621E1F8-C36C-495A-93FC-0C247A3E6E5F`); Esc and `$uuid` again shows another. ⏎ in TextEdit pastes the one shown, and ⌘V pastes it again; ⌥⏎ only copies it. Either way it is the newest clip.
23. `$token`: the pane shows 32 letters and digits at once, a new one each time it is selected. ⏎ in TextEdit pastes it; in the history it is a sensitive clip (masked), and 90 seconds later ⌘V pastes nothing. `$token 64` is 64 characters; `$token 4` shows a red "Length must be a whole number from 8 to 512" and ⏎ beeps. ⇥ opens the form: Format → Hex gives only `0-9a-f`, URL-safe adds `-` and `_`, and the format is remembered for the next `$token`.
24. `$clip`: on a YouTube video, copy the link at a moment with a clear sound (Share → Start at). Type `$clip `, paste, then ` 3 horn`: the pane says "Cuts 0:03 from …" and "saves it as ~/.config/cortex/sounds/horn.mp4". ⏎: the palette closes, the progress card shows after a second, and a notification "Created horn.mp4" shows it in Finder; the clip is 3 seconds long and starts at the moment of the link. `$clip <a link without t=> 1:00 2` saves the video's title as the name; again with the same name adds " 2". `$clip <link> 4` (no start): the pane says what is missing, in red, and ⏎ beeps. Without yt-dlp (or with an old one): the notification says to install (or update) it.
25. `$sound`: ⇥: the form lists `horn` and the other clips, the field marked "required". `$sound ho`: the pane shows "⏎ plays it", `horn` and its path, the hints bar ⏎ Play, ⌥⏎ Copy path; ⏎ plays it, and nothing is pasted. `$sound ho` twice quickly: both play over each other. `$sound`, ⏎: the form opens. ⌘E on `$sound`: VS Code opens `~/.config/cortex/sounds.toml`, written with every line commented out; add `[bell]` with `path = "/System/Library/Sounds/Glass.aiff"`: `$sound bell` plays it. `[x]` with no path: the pane shows "sounds.toml: [x] (line …): path is missing". `$sound nope`: "No sound is called “nope”. Sounds: …".
26. `$port` and `$kill` on a host (needs a Mac or Linux machine in `~/.ssh/config` that you can reach without a password, here `pi`). On it start `python3 -m http.server 8765`. `$port 8765 @pi` (or `@p` while only `pi` starts with it): the pane says "Loading Kill Process on Port on pi…", then "Kill python3 on pi?" with the PID, `TCP 0.0.0.0:8765` (or `[::]:8765`) and the full command line. `$port 8766 @pi`: "Nothing is listening on port 8766 on pi (only your own processes are checked)". ⏎, ⏎ in the alert: the server stops on pi, the notification says "Ended python3 (PID …) on pi (port 8765)", and nothing on this Mac was touched. Do it again with `sh -c "trap '' TERM; exec python3 -m http.server 8765"` on pi: about 3 seconds later "Force-killed … on pi (port 8765): it did not quit after SIGTERM". `$kill python3 @pi` lists the server with its command line, `$kill http.server @pi` finds it by command line, `$kill :8765 @pi` is `$port 8765 @pi`, and `$kill nope @pi` says "None of your processes on pi is called “nope”". Confirm the alert, then restart the server on pi before pressing Kill: "… has already quit on pi" (a PID that another program has taken is not signalled). On a Linux host with Docker: `docker run -d --rm -p 8767:80 --name m23 nginx`, `$port 8767 @pi` previews "Stop container m23 on pi?" even though `ss` shows no process for it, and ⏎, ⏎ stops it ("Stopped container m23 on pi (port 8767)"). `$port 22 @pi`: root's sshd is not yours, so "Nothing is listening …". With pi switched off or unreachable, `$kill node @pi`: the preview's error is ssh's, starting with "pi:", after at most 5 seconds. The Host field in the `$kill` form lists This Mac first and starts there every time. The pane's first line reads `$port 8765 @pi` with a small "on pi" tag at its right.
27. The hints per outcome. With the palette over TextEdit, type each and read the hints bar once the pane has shown the outcome (before it, and for an error or a notice, it reads ⏎ Run and paste, ⌥⏎ Run and copy): `$uuid` ⏎ Paste, ⌥⏎ Copy; `$gh apple/swift` (step 11) ⏎ Open, ⌥⏎ Copy link; `$code cortex` ⏎ Open in VS Code, ⌥⏎ Copy link; `$term` ⏎ Open in Terminal (or the app of `terminal.toml`), ⌥⏎ Copy path; `$open ~/Downloads` ⏎ Show in Finder, ⌥⏎ Copy path; `$sound ho` ⏎ Play, ⌥⏎ Copy path; `$port 8765` with the server running ⏎ Kill…, and with two listeners ⏎ Kill 2 Processes…, with a container ⏎ Stop Container…, never a ⌥⏎; `$deploy hello` (step 11, with `confirm`) shows its own confirming button and "…"; a shell command file or `$clip …` (step 24) ⏎ Start, ⌥⏎ Start and copy; `$color` ⏎ Pick Colour and `$ocr` ⏎ Capture Text, no ⌥⏎. ⌘1–⌘9 always say Run. In the form (⇥) the hints bar says ⏎ Run, ⌥⏎ Run and copy until the pane shows the outcome for the fields, then the same words as the list.
28. ⌥⏎ on what opens. `$gh apple/swift`, ⌥⏎: the palette closes, the browser does not open, and ⌘V in TextEdit pastes `https://github.com/apple/swift`; it is the newest clip (an ordinary one, not masked). `$code cortex` ⌥⏎ pastes the `vscode://file/…/Cortex` link, `$open ~/Downloads` and `$term cortex` paste the path (`/Users/…/Downloads`, with spaces as they are, not a `file:` link), `$sound ho` the sound's path, and nothing opens, shows or plays. ⏎ on the same still opens, shows or plays. ⌥⏎ on `$port 8765` and on `$color` beeps and does nothing (no alert, no eyedropper); on `$nap`-like shell files it starts the job and copies the output when it is text. In a form, ⌥⏎ does the same as in the list.
29. Live refresh. `$mem`: the numbers and bars move on their own about every 2 seconds, without the pane flashing or going back to "Loading". Start something heavy (`yes > /dev/null`, a large build) and the used memory and the process list follow. `$cpu` and `$gpu` (also about every 2 seconds, with the sampling pause) do the same. ⏎ in TextEdit pastes the table of the moment ⏎ was pressed. Move to `$uuid`: the UUID stays as it was (it never refreshes). Go back to `$mem` and stop typing in the palette for a minute with Activity Monitor open: Cortex's own CPU use stays low while it refreshes, and drops to nothing when you close the palette or type `>`. `$mem @pi` (a reachable host) refreshes every few seconds too; switch the host off (or turn Wi-Fi off) while it shows: the last numbers stay and a small grey line under them says "Couldn't refresh: …" with ssh's reason; switch it on again and the line goes by itself. ⇥ on `$mem` opens the form, which refreshes its own copy; Esc goes back to the list, which carries on. Change the form's Host: the pane shows "Loading Memory Usage on pi…" once, then refreshes.
30. Nothing to do is a notice. With nothing on port 8766: `$port 8766` and `$kill nope-nothing` show a grey sentence with an info symbol (red is only for real errors: `$port abc`, `$mem @nas`, a host that is off), and ⏎ and ⌥⏎ beep. Same on a host: `$port 8766 @pi` says "… on pi (only your own processes are checked)", `$kill nope @pi` "None of your processes on pi is called “nope”", `$kill systemd @pi` "systemd is not offered …". With Docker running only its own forwarder on a port, `$port` says the runtime "is left alone", as a notice too. Copy `8766`, `>` Kill Process on Port, ⏎: a notification with the sentence and the title "Kill Process on Port", not "… failed".
31. `@host` for every command that takes one (a reachable `pi` in `~/.ssh/config`): `$kill node @pi`, `$port 3000 @pi`, `$mem @pi`, `$cpu @pi`, `$gpu @pi` and `$disk /mnt/usb @pi`. Each row keeps the `@pi` as typed, the pane's first line is the command as typed with the "on pi" tag, and the progress card or notification names the host. `@p` works while one alias starts with it; `@nas` (unknown) is a red error listing the hosts, `@pi @linode` says "One host at a time". `$ask a@b.com @x` keeps both words in the prompt (not a host command). Open the form (⇥) of each: a Host field after the argument, This Mac first and selected whatever the last run used; ←→ pick `pi` and the pane follows; ⏎ runs on it and the next form starts at This Mac again. A command that takes no host (`$uuid`) has no Host field and no ⇥ hint.

### M24. AI actions

Needs an OpenAI API key with a little credit; the whole check costs well under a cent plus one picture.

1. Settings → AI: the page says the text goes to OpenAI. Switch *Enabled* on; with Quick Actions off, the switch is off and says it needs the Quick Actions module. Paste the key, *Save*: the field says "Saved". Keychain Access lists `ai.openai-api-key` under Cortex's service.
2. Copy `Ths sentense has two typos.`, open the palette, type `>proof`: Proofread is listed; the pane says "Sends the text to OpenAI (gpt-6-luna) and pastes the corrected text." and nothing is sent yet (Usage still shows 0 requests). In TextEdit, ⏎: the corrected sentence is pasted (or, after more than 5 seconds, a notification says it is on the clipboard) and is a new clip.
3. Select a paragraph in TextEdit, press ⌃⌥⌘S, choose Summarize: the summary replaces the selection, and neither is in the history.
4. Copy some text and type `>`: no "Ask AI" or "Generate Image" (they are commands). `$ask What is the capital of Austria? One word.`, ⏎: `Vienna` (or similar) is pasted; the pane said "Sends the text to OpenAI (…) and pastes the answer." before.
5. `$img a red fox in the snow, watercolor`, ⏎: the progress card shows Generate Image with `$img a red fox …`, then a notification says the result is on the clipboard; ⌘V in Keynote or Preview (New from Clipboard) shows the picture, and the history has an image clip.
6. Settings → AI → Usage: requests per model with tokens and a dollar estimate (a few hundredths of a cent for the text, a few cents for the picture). Quit and relaunch: the totals are still there. *Reset* asks first, then shows zeros and today's date.
7. Copy a password from your password manager (or ⌘K on a masked clip): `>proof` lists no AI action. Through Shortcuts ("Transform Text with Cortex", Proofread) on normal text, the corrected text comes back.
8. *Remove* the key, then run Proofread: a notification says "No OpenAI API key yet: add one in Cortex Settings → AI". Save a wrong key: "OpenAI rejected the API key". Set the text model to `gpt-nonexistent`: the notification quotes OpenAI's error; clear the field and the default is used again.
9. Switch AI off: no AI action in `>` or in Shortcuts' action picker, and `$ask` finds nothing.

### M25. Reading list

1. Copy a link in Safari (address bar, ⌘C), open the palette and type `+`: the empty list says "Nothing to read". ⌘N adds the link with the page's title; the row shows the title, the website and "just now", the preview the link and "Added just now from Safari" (or the app the palette was opened over).
2. Type `+example.com/a?utm_source=x`: the first row is "Add to Reading List" with `https://example.com/a`, and the hints bar says ⏎ Add. ⏎: the query goes back to `+` and the new link is on top, selected, titled `A (example.com)`. Type it again: the saved link shows instead of the Add row.
3. ⌘E: a form with Title (empty, showing `A (example.com)`) and Note, the cursor in Title. Type a title, ⇥, a note, ⏎: back in the list with the new title; the preview shows the note.
4. ⏎ on a link: the palette closes and the page opens in the default browser. Open the palette, `+`: the link is now below the unread ones, dimmed, with a check mark, and the preview says "Read just now". ⌘R marks it unread again (the hint says Mark unread on a read link).
5. ⌥⏎ copies the link without opening it; it is the newest clip in the history.
6. ⌘⌫ deletes the selected link; the next one is selected.
7. Settings → Reading List: switch *List read links* off: `+` shows only unread links, and typing part of a read one's title still finds it.
8. Status menu: *Add Link from Clipboard* with a link on the clipboard posts "Added to Reading List" with its title; with plain text, "No link on the clipboard". *Reading List* opens the palette on `+`.
9. Switch the module off: `+` searches the clipboard history and the status menu items are gone. On again: the links are still there.

### M26. Color picker

1. Press ⌃⌥⌘C over any app: the system eyedropper appears without a permission prompt. Click a pixel: a notification says "Copied #…", and the value is the newest clip in the history, with a swatch of that colour instead of the text icon.
2. Open a Display P3 image (a vivid photo) in Preview and pick a saturated pixel. Digital Color Meter set to "Display in sRGB" shows the same value as Cortex's (within one step per channel).
3. Press ⌃⌥⌘C again while the eyedropper is showing: nothing changes. Esc: nothing is copied, the clipboard still holds what it held before.
4. Open the palette, choose *Pick Color* from the status menu: the palette closes, the eyedropper appears.
5. Settings → Color Picker: *Copy as* CSS rgb() gives `rgb(…)`, SwiftUI Color gives `Color(red: …)`; *Uppercase hex* is greyed out for those. Back to hex with *Uppercase hex* off: `#1a2b3c`. Turn the notification off: picking is silent.
6. Copy `#ff8800`, `rgb(0 128 255 / 50%)` and `hsl(120, 100%, 25%)` from TextEdit: each row shows a swatch (the half-transparent one over a checkerboard), and its preview a large swatch with Hex, RGB, HSL and SwiftUI. Copy `color: #ff8800` and `123456`: plain text rows. Check white (`#fff`) and black (`#000`) swatches in light and dark mode: both have a visible border.
7. Open the palette over TextEdit and type `$color`: the row is *Pick Color*, the pane says what it does. ⏎: the palette closes and the eyedropper appears at once, with no progress card. Click a pixel: the colour is copied (not pasted) with the notification. Again with Esc: no notification, nothing copied, no "failed" notification.
8. Switch the module off: ⌃⌥⌘C does nothing, *Pick Color* is gone from the status menu and `$color` from `$`; swatches stay (they belong to the history).

### M27. Text recognition

Searching image clips (Clipboard module, on by default):

1. Take a few screenshots with ⌃⇧⌘4 (to the clipboard) of windows with text: a web page, a Finder window with a sidebar, a German text with umlauts. Within a few seconds each, searching the palette for a word that only appears in a screenshot finds it. The preview shows the image with *Text in image* below it, selectable, in light and dark mode.
2. On a history with many images (or after a Pastebot import): Activity Monitor shows Cortex working at low priority until the backfill is done, then idle; note how long it took and for how many images. Last week's screenshot is then found by its text.
3. Select a screenshot with text: the hints read *Paste* and *Paste text*. ⇧⏎ in TextEdit pastes the text, ⏎ the image, ⌘E opens the snippet editor with the text. A screenshot without text (a photo) keeps *Paste as text* and ⇧⏎ pastes the image.
4. Copy a screenshot of an API token (for example a `ghp_…` test token shown in TextEdit): the clip turns sensitive once its text is read (masked, ⌥ reveals). With *Include their text in search* off, the token's words are not found.
5. Settings → Clipboard → *Search text in images* off, take a new screenshot: its text is not found. On again: found a moment later.

Capturing text (Text Recognition module, off by default):

6. Switch on Settings → Text Recognition. Settings → General → Permissions lists *Screen Recording*. Press ⌃⌥⌘T before granting it: an alert explains and opens System Settings; nothing else happens. Grant it, quit and open Cortex.
7. ⌃⌥⌘T over Safari: the system crosshair appears. Drag over a paragraph: a notification says "Copied n lines" with the first line, and the text is the newest clip (from Cortex). Press Space during the selection and click a window: its text is copied. Esc: nothing copied, no notification.
8. Capture a region with no text (a photo): a notification says *No text found*; the clipboard is unchanged.
9. Capture two columns of an article, and a table (Numbers, or a web table): the columns come one after the other, and the table pastes into Numbers cell by cell. Turn on *Join the lines of a paragraph*: a wrapped paragraph comes out as one line, a word broken with a hyphen is whole again.
10. Capture the whole of a large display (drag across it): small sidebar and menu text is in the result. Note whether the first capture after a new build of Cortex takes noticeably long (Vision preparing its model).
11. Press ⌃⌥⌘T again while the crosshair shows: nothing changes. With the palette open, choose *Capture Text* in the status menu: the palette closes first. `$ocr` in the palette: the crosshair appears at once, with no progress card.
12. ⌘K on an image clip: *Recognize Text* is offered, ⏎ pastes its text. Select two PNGs in Finder and run it from `>`: their texts, one after the other.
13. Setting *Language* to German and capturing an English text still works (worse); back to *Automatic*. Switch the module off: ⌃⌥⌘T does nothing, *Capture Text* is gone from the status menu, `$ocr` from `$` and *Recognize Text* from `>`. Search in image clips keeps working.
14. After a few weeks: does macOS ask again to allow Cortex to record the screen (the periodic confirmation for screen capture)? Note it in the log.

### M28. Calculator

1. Open the palette over TextEdit and type `=`: with no recent calculations the list says "Calculate" with examples. The placeholder of an empty palette lists `= calculate` between emoji and symbols.
2. Type `=1920/1080` one character at a time: no error flashes while typing (`=1920/` shows the examples). The rows are `1.777777778` (Result) and `1.7777777777777777` (Plain number, for code); the pane shows `1920 ÷ 1080` and the result large, in light and dark mode and in both palette styles. ⏎ pastes `1.777777778` into TextEdit; it is the newest clip in the history.
3. `=1920*1080`: `2,073,600` with your number format (`2.073.600` in German), then `2073600`. ⌘2 pastes the plain one. ⌥⏎ copies without pasting.
4. With a German number format (System Settings → General → Language & Region → Number format `1.234.567,89`; reopen the palette): `=3,5*2` is `7`, `=1/4` gives `0,25` and `0.25`. Settings → Calculator → *Result format* Point: `0.25` only. Back to System.
5. `=3 in to cm`: `7.62 cm` and `7.62`; the pane says `3 inches → centimetres`. `=100 km/h in mph`, `=20 °C to F`, `=1 GiB to MB` and `=2 Stunden in Minuten` give 62.13711922 mph, 68 °F, 1073.741824 MB and 120 min. `=5 ft`: `1.524 m`, `152.4 cm`, `60 in`.
6. Errors: `=1/0` shows "Division by zero" in red and ⏎ beeps; `=3 kg to cm` "Can't convert mass to length"; `=3 flurbs` "Unknown unit: flurbs". `=3 m to c` shows no error.
7. `=1920/1080`, ⇥: the field reads `=1.7777777777777777` with the cursor at the end; type `*1080` and the result is `1,920`. `=3 in to cm`, ⇥: `=7.62 cm`; type ` to in` and the result is `3 in`.
8. Type `=` alone: the recent calculations, newest first, each with `= …` under it. ⏎ puts the selected one back into the field. ⌘⌫ forgets it. ⌘⌫ with a calculation typed deletes text as usual.
9. Settings → Calculator: *Significant digits* 3 gives `3.14` for `=pi`. *Keep recent calculations* off: `=` alone lists nothing and nothing is added. *Clear* is greyed out without recents.
10. Switch the module off: `=2+2` searches the clipboard history and `=` is gone from the placeholder. On again: the recents are still there.

### M29. Knowledge base

Back up `~/.config/cortex/knowledge/` first if it holds real notes, or point the module at a scratch folder: `defaults write <bundle ID> knowledge.folder /tmp/knowledge` (remove it with `defaults delete` afterwards). Have VS Code installed.

1. Status menu → *Open Knowledge Folder*: Finder shows the folder with `inbox/`. Open the palette, type `?`: the placeholder of the empty palette mentions "? notes, ! to-dos"; the list shows the projects (the inbox first), then recent items, or "Nothing here yet".
2. Type `?how to convert png to svg`: nothing matches, the last rows are *Save as note “how to convert png to svg”* and, with text on the clipboard, *Save clipboard as note …*; the pane shows the file it will write (`inbox/notes/<today>-how-to-convert-png-to-svg.md`). ⏎ on the clipboard row: the palette closes; in Finder the file is there with front matter and the clipboard text as body. `?convert`: the note is found, the snippet of its body in the row. Copy `sk-proj-` followed by 40 letters and digits, `?key`, *Save clipboard as note*: the row shows a lock and ⏎ asks first.
3. In VS Code, add a fenced `sh` code block and a second one to that note and save: within a second `?convert` shows them under the preview as ⌘1 and ⌘2; ⌘2 in TextEdit pastes the second block's code. ⏎ pastes the body, ⌥⏎ only copies it. ⌘⏎ opens the file in VS Code.
4. Create `server-config/README.md` with `name: Server config` and `summary: The home server` in front matter. `?` lists *Server config* with its summary; ⏎ on it puts `?@server-config ` in the field and lists its items. `?@serv docker` and `?#cli` narrow as expected.
5. Type `?@homelab`: the only row is *New project “Homelab”* with `@homelab` and a pane saying what it creates. ⏎: the field becomes `?@homelab ` and Finder shows `homelab/README.md` with `name: Homelab`. Type `?a note for the nas #hw @HomeLab-NAS`: *New project “HomeLab NAS”* comes first, then *Save as note* (into the inbox). ⏎ on the first: the field becomes `?@homelab-nas a note for the nas #hw` and *Save as note* now goes there. `?@!!!` offers nothing.
6. ⌘E on the note: the editor window opens with title, project, tags and the Markdown. Change the title and the project to Server config, ⌘S: the file moves to `server-config/notes/<new-slug>.md`. Edit it in VS Code meanwhile and save in the editor again: it asks whether to overwrite or reload. ⌘⌫ in `?` asks, then moves the file to the Trash.
7. Type `!`: the open to-dos (or an empty list). `!fix the backup @server #urgent`, ⏎: the palette stays on `!@server-config ` with the new to-do selected; its row shows the project. Add a checklist in VS Code (`- [ ] one`, `- [ ] two`), then in `!` press ⇥: the first item is selected; ⏎ ticks it (the file shows `- [x] one`), esc goes back to the list. ⌘D closes the to-do (dimmed until the query changes), ⌘D again reopens it. `!done` lists the closed ones. Add `due: <yesterday>`: it moves to the top and says "Overdue since …".
8. Status menu → *Browse Knowledge…*: a window with the projects on the left (the inbox first, each with its item count), Notes / To-Dos / Skills above the middle list with a search field and +, and the selected item on the right: the title as a heading, the project, tags and *Add tag* as chips, *Updated …* on the right, Edit / Preview with *Open in VS Code*, the Markdown, and Revert / Save at the bottom. Rows have two lines and a pill (a note's age, a to-do's due day, orange when due). Type in the search field: the list narrows to items with every word; ✕ clears it. To-Dos lists *Open (n)*, then *Done (n)* collapsed: click its header and the done ones show. Click a to-do's circle: it moves under Done (check the file says `status: done`). Edit the text, add a tag with ⏎ and remove one with ✕: *Edited* shows at the bottom; click another note: the first is saved (check the file; other front matter keys are kept). Type a tag without ⏎ and click another note: it is saved too. Change a title, ⌘S: the file is renamed and stays selected. *Preview* renders the Markdown (headings, lists, code); on a to-do, tick a checklist box there and ⌘S: the file has `- [x]`. Click the project chip, pick another project: the item leaves the list at once, the next one is selected, and the file is in the other project's folder with the edits. On a skill the project chip has no arrow. The due chip opens a calendar; pick a day, ⌘S: the file's `due` changes; *Remove Due Day* removes it. *Updated …* shows the path, dates and other front matter keys. Right-click a row: *Move to* moves it, *Show in Finder* reveals the file, *Copy Text* copies the Markdown, *Move to Trash…* (or ⌫) asks, then the file is in the Trash. + (⌘N) asks for a title and creates a note (or a to-do) in the project, selected. On Skills, + is disabled. Edit, then change the same file in VS Code and click another item: it asks to overwrite or reload and stays put. Edit and close the window: the edit is saved. *Open in VS Code* (or ⌘O) saves, then opens the file; save a change there and the window shows it within a second. In `?`, ⌘O on an item opens the window on it, on a project on that project. Check light and dark mode.
9. Copy two lines of text, ⌘K on the clip (or the selection hotkey on selected text): *Save as Note* and *Add as To-Do* are offered; each writes to the inbox with the first line as the title and posts a notification. Status menu → *New To-Do…* opens `!`.
10. Settings → Knowledge: the counts, the folder, *Keep a git history* and *Link skills into ~/.claude/skills* on. A minute after the last change, `git -C ~/.config/cortex/knowledge log --oneline` lists a commit by Cortex naming the changed files. Without the Command Line Tools, Settings says git is missing and nothing else changes.
11. Record a hotkey for *Search and capture notes*: it opens and closes the palette at `?` over any app.
12. **Outline import** (once, with a real export): Outline → Settings → Export → All collections, download the zip. Settings → Knowledge → Outline → *Import…*, choose the zip: the sheet lists the collections with their document counts, each on a project of the same name or *New project*. Map one to *Inbox*, skip one, import: the report counts notes, attachments and broken links. Open a note with a picture: the picture shows in VS Code's Markdown preview (`../assets/…`). Run the import again: everything is skipped.
13. **Trello import** (once per board): export each board as JSON. Settings → Knowledge → Trello → *Import…*, choose two files: two projects with one to-do per card; done lists' cards are done; labels and other lists are tags; checklists are task lists. Import one board again: nothing new.
14. Switch the module off: `?` and `!` search the clipboard history, the status menu items and the browser window are gone, *Save as Note* is gone from ⌘K, and Settings has no *Projects* page. On again: everything is there.
15. **Projects and colours.** Settings → Projects lists every project (the inbox first) with its symbol on its colour, `@id`, item count and its label. Projects without a `color` each have one, the inbox gray; relaunching keeps the same colours. *Edit…* a project: pick *Teal* and `server.rack` in the grid, add a linked folder, *Save*: the README gains `symbol: server.rack`, `color: teal` and `folders: [~/…]`, its text and other keys stay. In `?`, the project's row shows the symbol in teal and its items show a teal label with the symbol on a faint tint; in `!` its to-dos do too; the browser's sidebar shows the teal symbol; with a row selected the label turns white. Check light and dark mode: the labels stay calm next to each other. Type `chartreuse` into the symbol field: a warning and *Save* is disabled. *New Project…*: type a name, the folder field suggests its slug; type a folder that exists: a warning and *Create* is disabled; create one: the folder and its README appear and `?` lists it. On the iPhone after a sync, the project list and an item's header show the same colours.

### M30. Agents (MCP and skills)

Needs Claude Code; optionally Claude Desktop.

1. Settings → Knowledge → Agents shows `claude mcp add --scope user cortex /Applications/Cortex.app/Contents/MacOS/cortex-mcp` (with `-- … --folder …` when `knowledge.folder` is set); *Copy* and run it in Terminal. `claude mcp list` shows `cortex` connected.
2. In a Claude Code session inside `~/Developer/homelab` (with `folders: [~/Developer/homelab]` in that project's README): "Search my knowledge base for docker" lists the notes with their paths; "Add a to-do to rotate the S3 key" writes it to `server-config/todos/` (the current project), and `!` shows it within a second. Ask it to save a text containing an API key: it asks you before writing.
3. `/mcp__cortex__file-this some text` and `/mcp__cortex__tidy-inbox` appear as prompts and lead the agent through filing and tidying, with proposals to confirm.
4. Create a skill (`server-config/skills/deploy-a-service/SKILL.md` with `name` and `description`): `~/.claude/skills/deploy-a-service` is a symlink into the knowledge folder, and a new Claude Code session lists the skill. A folder of the same name already in `~/.claude/skills/` is left alone and listed in Settings. Switch *Link skills* off: the link goes.
5. "Make me a `$gh` command that opens a GitHub repository": the agent calls `create_action`, `~/.config/cortex/actions/gh.toml` appears, Settings → Quick Actions lists it under *Your actions* within a second and `$gh apple/swift` opens the page. Ask for a `$port` command: it is refused with the reason and nothing is written.
6. Quit Cortex: the MCP tools still work in Claude Code. In Claude Desktop (Settings → Developer → add the same executable): the tools work there too.

### M31. Filing with AI

Needs AI on with a key (M24) and Commands on; costs well under a cent.

1. `$` lists `$note …`, `$todo …` and `$tidy` with the knowledge base on; with AI off they are gone. `$note`, ⏎: the form with a Text field and the clipboard as its suggestion; the pane says what is sent to OpenAI and that the note is shown before saving. Usage counts nothing yet.
2. Over TextEdit: `$note potrace only reads bitmaps, so convert with magick input.png -threshold 50% input.pbm, then potrace input.pbm -s -o output.svg`, ⏎: the progress card shows while OpenAI answers, then the palette opens with *New note*, a title, a project, the file it will write, tags and the Markdown with the commands in a code block. ⇥ and ⇧⇥ go round the projects (the file path follows). ⏎: the palette closes; `?potrace` finds the note in the chosen project. Esc instead discards it and closes the palette.
3. `$note how to deploy a service with docker compose: 1. push to main 2. pull on the server 3. restart`: it proposes a *New skill* with a name in hyphens and a description; ⏎ writes `skills/<name>/SKILL.md` and its link appears in `~/.claude/skills/`.
4. `$todo rotate the S3 key on atlas by friday, check the cron log and update the restic env first`: *New to-do* with Friday's date as the due day and two checklist items; ⏎ adds it, `!` shows it on top.
5. Put three notes in the inbox (one clearly about a project, one about the same subject as an existing note in a project, one random). `$tidy`, ⏎: the list shows a proposal per item it would change, all ticked, with the target project or *Merge* and the reason. ↓ and ⇥ skip one (dimmed); ⏎ applies the others: the moved note is in its project under the proposed title, the merged one is at the end of the other note under a `##` heading and in the Trash. Edit an inbox note between `$tidy` and ⏎: it stays as it is and a notification says so. `$tidy` with an empty inbox: the notification says the inbox is empty and nothing is sent.
6. Copy a password from the password manager, `$note`, ⏎: the clipboard is not suggested. Type a text with an API key (`sk-proj-` and 40 letters and digits) and ⏎: a notification says it is not sent, and Usage counts no request.

### M32. iPhone: joining and the knowledge base

Needs a Mac with sync set up against the deployed server, an iPhone with Cortex (`make install-ios`) and Tailscale.

1. On the Mac, Settings → Sync → *Show Pairing Code…*: a QR code in a sheet; *Done* closes it. On the iPhone, *Scan Pairing Code*: the camera asks for permission once, then the app joins, says "Syncing for the first time…" and shows the projects, the inbox first, with their counts and open to-dos.
2. *Paste* with a copied pairing code works the same. A damaged code says "This isn't a Cortex pairing code."; a code from another server's key says "Sync key doesn't match"; nothing is stored either way.
3. Open a project: open to-dos, notes, skills and done to-dos; *About* opens the README. Open a note with headings, lists, a task list, a code block, a quote, a table, a link and an image from `assets/`: all render; the link opens Safari.
4. Search a word from a note's body: it is found with a snippet. `@server docker` and `#tag` narrow as on the Mac.
5. Flight mode, quit and reopen the app: everything is still there and searchable. Settings shows "Server unreachable — is Tailscale connected?" after pull to refresh.
6. Edit a note on the Mac, pull to refresh on the iPhone: the change shows. Delete it on the Mac: the open note says "Not here anymore".
7. Settings → *Disconnect…*: back to the join screen; the Mac's sync is unaffected.

### M33. iPhone: the reading list

Needs the joined iPhone from M32 and a Mac with *Reading list* switched on in Settings → Sync.

1. On the Mac, save a link with `+`. Pull to refresh on the iPhone's *Reading List* tab: it is on top of *Unread* with its title, website and age, and the tab badge counts it. Tap it: it opens in Safari (two taps from the home screen) and moves to *Read*; on the Mac it shows read after its next cycle.
2. Swipe right on a link: *Mark Read* (on *Read*: *Mark Unread*); swipe left: *Delete*. The delete reaches the Mac; the read state too.
3. Copy a link in Safari (long press → *Copy Link*), then the paste button next to *Add a link*: no paste prompt, the link is added without tracking parameters. Type `example.com/a` and Return: added. Type `hello`: "“hello” is not a web link."
4. Long press a link: *Edit* changes the title and note (both reach the Mac); *Share* opens the share sheet; *Copy Link* puts the link on the clipboard.
5. Long press → *Add to Safari's Reading List*: it is in Safari's Reading List (and downloads for offline reading if Safari is set to), and moves to *Read* here. With Settings → Reading List → *Safari's Reading List Marks Read* off, it stays unread.
6. Settings → *Open Links* → *In Cortex*: tapping a link opens it inside the app, in Reader for an article; *Done* goes back.
7. Search a word from a note or a site: read and unread links are both found, read ones with a check mark.
8. Settings → *Delete Read Links* → *After 1 Day* with a link read two days ago (on the Mac, or before changing the clock): it disappears from *Read* at once and stays on the Mac. It does not come back after the next sync.
9. On the *Read* list, switch to another app for a minute, lock the phone, come back: still on *Reading List*, *Read*. No new `Cortex-…` crash report in Settings → Privacy & Security → Analytics & Improvements → Analytics Data.
10. Add a link: the footer says "1 change not sent yet" for a few seconds, then "Synced just now". The Mac has it within about 10 seconds without touching it.

### M34. iPhone: editing the knowledge base

Needs the joined iPhone from M32.

1. *Knowledge* → *+* → *New Note*: title, a project (the inbox by default), tags, a Markdown body; *Save*. It is in its project at once. In a project, *+* → *New To-Do* puts it in that project; *Due Date* sets the day. *+* → *New Project…* makes a project folder with a README in a colour of its own.
2. *To-Dos*: open to-dos, the due ones on top, overdue ones in red. The circle (or a swipe to the right) ticks one off and it moves to *Done*; *Done* lists them last done first, and the circle reopens one. Swipe left: *Delete*, after asking.
3. Open a to-do with a checklist: tapping a box ticks it (tapping the text doesn't); *Add item* adds one at the end of the list. A `- [ ]` line inside a code block is not a box.
4. *Edit* (the pencil): change the title and the project and *Save*: the item view stays on the item, now in the other project. Type a GitHub token (`ghp_` and 36 letters and digits) into a body and *Save*: "Save anyway?" asks; *Cancel* keeps the editor open. Saving the same note again with the token still in it doesn't ask again.
5. Start editing a note, switch to another app, swipe Cortex away in the app switcher, open it again: the editor is back with the text typed.
6. Open a note's editor on the iPhone and type. Edit the same note on the Mac and wait two minutes (the iPhone pulls every two minutes while it is in front). *Save* on the iPhone says "Changed meanwhile". *Keep Mine* overwrites the Mac's version, *Take Theirs* drops the edit, *Copy Mine* saves it as "… (copy)" next to the Mac's.
7. *More* → *Delete…* on a note: gone on the iPhone; on the Mac after its next cycle, with the file in `knowledge/.conflicts/`.
8. Flight mode: add a to-do, tick its checklist, edit a note. The footers say how many changes are not sent yet. Flight mode off: within a minute the Mac has all of it.
9. Edit the same note on the Mac and, before the iPhone syncs, on the iPhone (flight mode helps). After both synced, the older edit is in `.conflicts/` on one side: on the iPhone, Settings → *Conflict Copies* lists it; *Restore* puts it back and keeps the other version there in turn, and the Mac gets the restored text.

### M35. iPhone: actions on the knowledge base

Needs the joined iPhone from M32, and a to-do with a due day and two open checklist items.

1. On *To-Dos*, swipe right on the to-do → *Remind* → *One Reminder*. The first time: Cortex asks for access to Reminders, then for the list (the default one is ticked). "Added to …" shows at the bottom. In Reminders: the to-do's title, the due day without a time, the checklist and a `cortex://item/…` link as notes. Tap the link: Cortex opens with the to-do.
2. *Remind* again: "Reminder updated", still one reminder. Change the to-do's title on the Mac, sync, *Remind*: the reminder has the new title. Delete the reminder in Reminders, *Remind*: it is added again.
3. Long press the to-do → *Add to Reminders* → *One per Item*: a reminder per open checklist item, each with "From “…”" and the link; the single reminder from step 1 is completed. Tick an item in Cortex, *One per Item* again: its reminder is completed.
4. Long press the to-do → *Add to Calendar*: the calendar's editor, all-day on the due day, with the link as URL; *Add* puts it in the calendar without Cortex asking for calendar access. A note or a to-do without a due day has no *Add to Calendar*.
5. Open a note → *More* → *Add to Notes…* → *Notes* in the share sheet: a new note with the title as its title and the body as plain text (bullets, ☐/☑, links with their address). In Shortcuts, make "Cortex to Notes" (*Create Note* with *Shortcut Input*), enter the name in Settings → Actions → *Notes Shortcut*: *Add to Notes* now runs it and comes back to Cortex.
6. *Copy* → *Copy as Markdown*, *Copy Text*, *Copy Link*: paste each into Notes: `# Title` and the body; the body alone; the `cortex://` link, which opens the item when tapped. *Share* → *Share Text…* and *Share File…*: the text, and the `.md` file with its front matter (AirDrop it to the Mac).
7. Settings → Actions → *Reminders List*: pick another list; the next new reminder goes there, the old ones stay where they are and are still updated.
8. In Safari, open `cortex://search?q=docker`: Cortex shows the Knowledge search with "docker" filled in. `cortex://new?kind=todo` opens the editor for a new to-do.

### M36. iPhone: capture from anywhere

Needs the joined iPhone from M32 with Cortex installed after M5 (`make install-ios`), and a to-do with a due day.

1. In Safari, open an article, *Share* → *Cortex*: a sheet *Reading List* with the page's title, editable; *Add* closes it. Count the seconds from tapping *Share*: under five. Open Cortex: the link is on top of *Unread*. On the Mac it is there after its next cycle. Without opening Cortex, it reaches the Mac only once iOS gives Cortex a background refresh (hours, not minutes).
2. Select a paragraph in Safari, *Share* → *Cortex*: *New Note* with the first line as the title, *Save*. One picture from Photos, then three at once: a note each in the inbox with the pictures in `inbox/assets/`, shown in the note. On the Mac after Cortex ran on the phone.
3. Long press the Cortex icon: *New Note* and *New To-Do* open the editor; *Add Link from Clipboard* with a link copied asks to paste, then shows *Reading List* with the link and a confirmation. With text that is no link: "The clipboard has no web link."
4. Spotlight: type the title of a note: it is among the results (Cortex's icon); tapping it opens the note in Cortex. Settings → *Show in Spotlight* off: it is gone from Spotlight; on again: back after the app was in front.
5. Spotlight or Shortcuts: *Add Note* asks for the text and saves it without opening Cortex; *Add To-Do* asks for the to-do (a due day is optional in Shortcuts); *Add to Reading List* asks for a link. Each is in Cortex the next time it opens. *Search Knowledge* opens the Knowledge search; *Open To-Dos* the To-Dos tab. "Hey Siri, add a note to Cortex" works too.
6. Home Screen widgets: *To-Dos* in small (count and the first three), medium and large (rows with circles; overdue in red). Tick the circle: the row goes, the count drops, and the file is done in Cortex; on the Mac after Cortex ran. Tap a row: Cortex opens with the to-do; tap elsewhere: the To-Dos tab. *Reading List* in small and medium: the unread count and the newest titles; a tap opens *Reading List*.
7. Lock Screen: add *New Note* (circular) and the *To-Dos* and *Reading List* accessory widgets. *New Note* opens Cortex with the editor (after unlocking).
8. Control Center: add the *New Note* control; tapping it opens the editor. Settings → Action Button → *Controls* → *New Note*: pressing the Action button opens the editor.
9. Leave the phone untouched for a few hours with Cortex in the background; add a to-do on the Mac meanwhile. The *To-Dos* widget shows it without opening Cortex (iOS decides when; a phone in Low Power Mode may not refresh at all).
10. After each of the above: no new `Cortex-…`, `CortexShare-…` or `CortexWidgets-…` crash report in Settings → Privacy & Security → Analytics & Improvements → Analytics Data (`0xdead10cc` would mean something held the database while suspended).


### M37. iPhone and Macs: connected devices

Needs the sync server updated for the `device` collection first (it refuses the reports otherwise), both Macs and the iPhone on a build from after M6 (`make install`, `make install-ios`).

1. iPhone → *Devices*: this iPhone on top ("This iPhone · Synced …"), both Macs below, each "Syncing" with its Cortex and macOS version. Tap a Mac: its last report, build date, what it syncs, uptime, free disk, battery on a laptop, host name and user.
2. Mac → Settings → Sync → *Devices*: the same three, this Mac marked "(this Mac)".
3. Put the Mac mini to sleep. Within a minute (after the next cycle on the phone, or pull to refresh): "Asleep since …" with the time. The next morning it still says so. Wake it: "Syncing" again within a few minutes.
4. iPhone → Settings → *This iPhone* → *Name*: type a name. On the Mac it shows within a minute or two.
5. Install a newer build on one Mac only (a higher `CURRENT_PROJECT_VERSION`): the other shows "Update Cortex on this Mac" on all three devices.
6. Quit Cortex on one Mac for over 20 minutes without sleeping it: "Last synced 25 min ago".
7. Swipe a Mac → *Forget* on the iPhone: it is gone there and from the other Mac's list after its next cycle; a few minutes later it is back, since it still syncs (it hears it was forgotten and reports again).

| Date | macOS | Commit | Result | Notes |
| --- | --- | --- | --- | --- |
| 2026-10-16 | 27.0.1 | Phase 1 commit | Partial: M1, M2 pass | Also checked by hand: bold text pastes bold, Safari "Copy Image" records an image. Remaining checks deferred until later phases. |
