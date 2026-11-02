# Text Recognition

Cortex reads text in images in two ways, both on this Mac with Apple's Vision framework, offline. The first makes image clips searchable: the clipboard history reads the text in every screenshot and image you copy, so the palette finds a screenshot by a word in it. The second captures text from the screen: a hotkey shows the system's crosshair, you select a region, and its text is copied as a new clip. The first half belongs to the Clipboard module and needs no permission. The second is the Text Recognition module, which is off by default because it needs Screen Recording.

## Using it

**Searching image clips.** Nothing to do. Type a word that appears in a screenshot into the palette (the Clipboard scope) and the clip is found. The preview shows the image with *Text in image* below it (selectable, cut to a preview length like other text). The text is read in the background, newest clip first, so a screenshot taken a minute ago is searchable before the backfill of last month's finishes.

| Key | On an image clip that has text |
| --- | --- |
| ⇧⏎ | Pastes the recognised text instead of the image. The hint reads *Paste text* (instead of *Paste as text*). With *Paste as plain text by default* on, ⏎ and ⇧⏎ swap roles. |
| ⌥⏎ | Copies the clip as it is, image and all. |
| ⌘E | Opens the snippet editor with the recognised text. |

An image clip without text keeps *Paste as text*, and ⇧⏎ pastes the image.

**Capturing text** (Text Recognition module, off by default):

- Press ⌃⌥⌘T, choose *Capture Text* in the status menu, or run `$ocr` in the palette. The system's crosshair appears, as with ⌘⇧4: drag over a region, or press Space and click a window.
- The text is copied and becomes the newest clip. A notification says "Copied 3 lines" with the first line (it can be turned off).
- Esc leaves the clipboard as it was. A region without text shows the notification *No text found* and also leaves the clipboard alone.
- A second press while the selection is showing is ignored. If the palette is open, it closes first.
- Columns are read one after the other and a table comes out as tab-separated rows, which paste into a spreadsheet cell by cell. This holds for regions up to 1200 pixels each way; larger ones are read line by line.
- Text that looks like a password or token is flagged sensitive, so it is masked in the history. The notification says so instead of showing its first line.
- Without the Screen Recording permission, the hotkey, the menu item and `$ocr` show an alert that explains why and opens System Settings.

**Recognize Text** is a quick action for images: a copied image, an image clip (⌘K in the palette), image files selected in Finder or dropped onto the palette, and Shortcuts. It gives the text to paste or copy. See [The quick action](#the-quick-action).

## Settings

Image clips are searched by default; the option for it is on the Clipboard page.

Settings → Clipboard:

| Option | Default | Meaning |
| --- | --- | --- |
| Search text in images | on | Reads the text in image clips. Turning it off stops after the clip being read and leaves the text already read where it is; turning it on again continues. |

Settings → Text Recognition (the page also has the Enabled switch, off by default):

| Option | Default | Meaning |
| --- | --- | --- |
| Capture text (hotkey) | ⌃⌥⌘T | Starts a capture. |
| Join the lines of a paragraph | off | Off, line breaks are kept as on screen. On, the lines of a paragraph become one, joined with spaces; a line that ends with a hyphen is joined without one. |
| Show a notification after capturing | on | "Copied n lines". *No text found* and errors are always shown. |
| Language | Automatic | Automatic detects the language and prefers the languages of this Mac. Otherwise one of the languages Vision supports. Also used by *Recognize Text*. |

Settings → General → Permissions lists *Screen Recording* while the Text Recognition module is on. Searching image clips does not need it.

## Data and privacy

**What is stored.** Text read from an image clip is in the database column `clipItem.recognizedText` (added by migration `v9_clipboard_recognized-text`) and in the clip's `searchText`, which feeds the full-text index. `NULL` means not read yet, `""` means read and no text found (or the image could not be read), anything else is the text. The database is encrypted like the rest of the history (see [CLIPBOARD.md](CLIPBOARD.md)). The capture stores nothing of its own: its text becomes an ordinary text clip. The module's UserDefaults keys are `text-recognition.joinLines`, `text-recognition.notify` and `text-recognition.language`, and the module switch `module.text-recognition.enabled`; the hotkey is `captureText`. The Clipboard option is `recognizeImageText`. There are no Keychain items.

**The captured image.** `screencapture` writes it to a folder in the temporary directory that only Cortex can read (mode 0700). It is deleted as soon as its text has been read, or if you press Esc. It is never kept.

**What leaves the Mac.** Nothing. Vision runs on the device. The recognised text does not sync: it is derived from the image, so each Mac reads the clips it has, including those that arrive from the other Mac. Writing it does not mark the clip for sync, so the backfill never uploads a screenshot again. The sync triggers watch only the last-copied date, the pinned flag and the sensitive flag. If the text flags the clip as sensitive, that flag is an ordinary change and syncs as such (see [SYNC.md](../SYNC.md)); a copy that reached the other Mac before its text was read is not called back. The captured text is a text clip and syncs like any other clip.

**Sensitive content.** Recognised text follows the rules of copied text (see [CLIPBOARD.md](CLIPBOARD.md)):

- It is always stored.
- It goes into the search index only when the clip is not sensitive or *Include their text in search* is on. Changing that setting rebuilds the search text of the sensitive clips.
- A sensitive clip is masked in the list and in the preview, image and text, until you hold ⌥.
- With *Detect passwords and tokens* on, the detector reads the recognised text too and flags the clip, so a screenshot of an API key becomes a sensitive clip. The capture applies the same detector before recording the text. When the Clipboard module is off, the capture assumes detection is on.

**Screen Recording.** The capture needs the permission, because without it a screenshot shows only the wallpaper. Cortex checks it with `CGPreflightScreenCaptureAccess()` and asks with `CGRequestScreenCaptureAccess()`. macOS applies a grant only after Cortex is quit and opened again, and the alert says so. Onboarding asks only for Accessibility, so Screen Recording appears only in Settings → General → Permissions, and only while a module that lists it is on. macOS may ask again from time to time to allow the screen capture.

## How it works

The recognizer is in CortexCore and has no AppKit, so it is tested with `make test` and iOS could use it. The capture and the indexing are in the app. See [ARCHITECTURE.md](../ARCHITECTURE.md) for the module system.

| File | Role |
| --- | --- |
| `CortexCore/Sources/CortexCore/TextRecognition/TextRecognizer.swift` | `TextRecognizing` (the protocol the app's tests fake) and `TextRecognizer`, which reads images through Vision's `RecognizeTextRequest` (accurate level, language correction on). With no language chosen it detects the language, with the system's preferred languages as hints; a hint like "en-DE" is matched to the first language Vision lists with the same language code. |
| `RecognizedLines.swift` | A pure function from word boxes (in pixels, origin bottom left) to text. Top to bottom; a word joins the line whose newest word it overlaps vertically by at least half; left to right within a line, a gap wider than two line heights becomes a tab, anything else a space; lines are joined with `\n`. Tested with made-up boxes. |
| `DocumentText.swift` | Turns `RecognizeDocumentsRequest` results into text: paragraphs in Vision's order, each table as tab-separated rows where it starts, and with *join lines* the lines of a paragraph joined (dropping the hyphen of a broken word). |
| `RecognizeTextAction.swift` | The *Recognize Text* quick action (macOS only), ID `image.recognize-text`. |
| `Cortex/Modules/TextRecognition/TextRecognitionModule.swift` | The `CortexModule`: manifest (id `text-recognition`, symbol `text.viewfinder`, no trigger, permission `.screenRecording`, off by default, order 57), hotkey, status menu item, options, and the capture. Conforms to `CommandContributing` and `ActionContributing`. |
| `TextRecognitionSettings.swift` | The three options over UserDefaults. |
| `ScreenCapture.swift` | `ScreenCapturing` (a protocol, so tests need no UI) and `SystemScreenCapture`. |
| `TextRecognitionCommand.swift` | `$ocr`, ID `command.ocr`. It resolves to a handoff whose `run` starts the capture, so no progress card shows while you select and Esc gives no "failed" notification. |
| `Cortex/Modules/Clipboard/ImageTextIndexer.swift` | The background indexer (see [The indexer](#the-indexer)). |
| `Cortex/Host/Support/ScreenRecordingPermission.swift` | The permission check and request. |

**Tiles.** Vision scales an image down until its longer side fits its model, so a whole screenshot loses its small text (on a 5K screen nearly all text under 20 pixels). An image larger than 1200 pixels on either side is therefore read in overlapping 1200 pixel tiles (300 pixels of overlap). Each tile keeps the words, with Vision's per-word boxes, whose centre lies in its own part of the image, so a line that crosses a seam comes back whole and nothing is read twice. An image with an EXIF orientation other than up (a photo) is read whole, with that orientation.

**Documents.** `RecognizeDocumentsRequest` (macOS 26) knows columns, paragraphs and tables, but cannot be tiled, because a paragraph or table would be cut. The capture and the quick action use it for images that fit one tile (at most 1200 pixels on both sides, nearly every capture); a larger one goes through the tiles. The index uses the line-based reading, which does not need it.

**The capture.** `TextRecognitionModule.capture()` closes the palette if it is open, checks the permission, asks `ScreenCapturing` for a PNG (nil after Esc), reads it with `recognizeCapture(_:joinLines:)`, and trims the result. The text is delivered with `closeAndDeliver(.text(text), .copyOnly, recording: .record(sensitive: …), restoringPasteboard: false, after: nil)` like the Color Picker does, so it becomes a clip from Cortex, with or without the Clipboard module on. The module does not name the Clipboard module; it asks `ClipboardAPI.detectsSensitiveText` whether to run the detector.

## Who owns what

| | Image clips | Screen capture |
| --- | --- | --- |
| Module | Clipboard (it owns `ClipStore` and the full-text index) | Text Recognition (`text-recognition`) |
| Starts | By itself, in the background | ⌃⌥⌘T, *Capture Text* in the status menu, `$ocr` |
| Writes | `recognizedText` of existing clips | A new text clip |
| Permission | None | Screen Recording |
| Default | On | Off |

Both use one recognizer in CortexCore. Neither module names the other: Clipboard calls the recognizer directly, and the capture records its result like any other copy from Cortex. So the history stays searchable with Text Recognition off, and a capture lands in the history with the Clipboard module off.

## The indexer

`ImageTextIndexer` in `Cortex/Modules/Clipboard/` is an actor owned by `ClipboardService`.

- It reads one clip at a time at background priority, newest first, in pages of 50 (`ClipStore.unrecognizedImageIDs(limit:)`). After each page it calls `onChange`, so the palette reloads once per 50 clips during a backfill, not once per clip.
- It loads only the image (`ClipStore.imageData(id:)`), recognises it, and writes with `ClipStore.setRecognizedText(_:id:markSensitive:indexSensitive:)`. That updates only `recognizedText`, `searchText` and `isSensitive` with SQL, so it does not touch the columns the sync triggers watch. A clip deleted meanwhile changes nothing.
- It is woken after the startup purge (the backfill, and after recording starts), after each recorded copy, after Sync applied remote clips, after a Pastebot import, and when *Search text in images* is turned on. A wake while it is draining makes it look again when the queue seems empty.
- The state is the `NULL` in the column, so stopping and starting again continues where it stopped. A clip it cannot read or decode gets `""` and is not tried again. A failed write ends the drain until the next wake, so the same clip does not come back forever.
- Turning the option off stops it after the clip being read. Stopping the service stops it too.
- Cost on a recent Mac, once the model is loaded: one tile takes 70 to 125 ms, a tiled 2880 × 1800 screenshot about 0.4 s and a 5K one about 0.9 s. A backfill of 2,000 screenshots is 15 to 30 minutes of one core at background priority. The first request of a process can occasionally take much longer while Vision prepares its model.

## In the palette

- **Search:** the query goes through the same full-text index as other clips, which now has the text. Every word has to match the start of a word. Nothing else changed.
- **Preview:** below the image, a *Text in image* section with the recognised text, hidden while the text is `""` or `NULL`. A sensitive clip is masked as a whole until ⌥ is held.
- **⇧⏎ (paste as text):** on an image clip with text, `Paster` writes the text instead of the image. `ClipItem.textForPlainPaste` is the recognised text for an image that has some, otherwise the plain text. The hint reads *Paste text*.
- **⌘E (save as snippet):** uses the same text.
- **List rows:** unchanged.
- When the list is reloaded, the selected clip's detail is reloaded too, so text read for the clip you are looking at appears.

## The quick action

*Recognize Text* (`image.recognize-text`) accepts image input (a copied image, an image clip) and image files (`FileKind.image`), and gives text. It works with ⌘K on an image clip, on the Finder selection, on files dropped onto Cortex, from `>` and in Shortcuts. It reads like a capture, with the module's language and *Join the lines of a paragraph* settings. Several files give their texts one after the other with a blank line between them. A file that is not an image Cortex can read is an error naming the file; no text at all is the error *No text found*. It is contributed by Text Recognition through `ActionContributing`, so it is there only while that module is on.

## Tests

- `CortexCore/Tests/CortexCoreTests/TextRecognition/`: `TextRecognizerTests` and `CaptureRecognitionTests` (images drawn with Core Graphics in the test, English and German lines with umlauts, small text on a large image, a line across tiles, tables and columns, so no binary fixtures), `RecognizedLinesTests` (made-up boxes: two columns, a slanted line, an empty image) and `RecognizeTextActionTests`.
- `CortexCore/Tests/CortexCoreTests/Clipboard/ClipStoreTests.swift`: `searchText` with recognised text, the sensitive rule, `reindexSensitive`, `unrecognizedImageIDs`, `setRecognizedText`. `Sync/SyncSchemaTests.swift` checks that recognised text adds no `syncRecord` and that flagging a clip does.
- `CortexTests/Modules/Clipboard/`: `ImageTextIndexerTests` (a fake recognizer: newest first, the option off and on, a clip deleted while it is read, stop and start), `ClipboardScopeTests` (⇧⏎ and the hints), `ClipboardSettingsTests`. `CortexTests/Host/PasterTests.swift` covers pasting the text of an image.
- `CortexTests/Modules/TextRecognition/TextRecognitionTests.swift`: the capture with a fake `ScreenCapturing` (text copied and recorded, Esc, no text found, a second press, no permission, sensitive text flagged), the settings keys, the module in the status menu and its lifecycle.
- Manual: [MANUAL_TESTS.md](../MANUAL_TESTS.md) M27: the backfill over a real history, the preview in light and dark mode, capturing on a Retina and an external display, window mode, German text, the permission flow from scratch, and whether macOS asks again.
