# SF Symbols

The SF Symbols module searches the symbols that this Mac has and pastes a symbol's name (`star.fill`, for `Image(systemName:)` in Xcode) or a picture of it (for Keynote, Figma or Slack). Type `::` in the palette to get a grid of symbols.

## Using it

Type `::` in the palette. Without a query the grid shows a *Frequently used* row once you have used some, then *All symbols* in the order SF Symbols lists them. Below the grid, the selected symbol is shown with its name in monospace, the macOS version it needs, and its search words.

Typing searches names and the system's own search words. Examples: `::star`, `::arrow.up`, `::mail` (finds `envelope`, a keyword), `::lock open`. Every word has to match. Results are ordered: an exact name first, then names that start with the query (shorter first, so `star` comes before `star.fill` and `star.circle.fill`), then whole parts of a name, then keywords, then any part of a name. The dots can be left out: `::personcircle` finds `person.circle`. Ties go to the symbol you use more, then to the SF Symbols order.

| Key | Does |
| --- | --- |
| ← → ↑ ↓ | Move through the grid, like the emoji grid. |
| ⏎ | Pastes the symbol's name as text. |
| ⇧⏎ | Pastes a picture of the symbol: a black PNG, 256 points high, with a transparent background. A multicolor symbol becomes a black silhouette. |
| ⌥⏎ | Copies the name. |
| ⌥⇧⏎ | Copies the picture. |
| ⌘1 to ⌘9, ⌘⇧1 to ⌘⇧9 | Pastes the symbol at that position, counted from the start of the grid, as name or as picture (with ⇧). |
| Click | Selects. A double click pastes the name. |
| ⇥ | Does nothing here, so it does not leave the search field. |

Pasting writes the name or the picture to the pasteboard, posts ⌘V into the app and, once the app has read it, puts the previous clipboard content back. A paste is not recorded in the clipboard history. A copy with ⌥ replaces the clipboard and, like any copy, is recorded in the history. Pasting needs Accessibility; without it ⏎ only copies.

Typing a second `:` after the first switches the grid from emoji ([EMOJI.md](EMOJI.md)) to symbols; deleting it switches back.

The list is the one of this Mac. It comes from the system's own symbol files, leaves out symbols newer than the installed macOS (they would be empty cells), and leaves out the localised copies (`.ar`, `.zh`, `.rtl` and others) of a symbol that exists without the suffix. If a later macOS moves those files, the grid says "No symbol data" instead of showing anything.

## Settings

Settings → SF Symbols has only the module's Enabled switch (on by default). There are no other options and no hotkey.

## Data and privacy

The module has no database tables, nothing syncs (see [SYNC.md](../SYNC.md)) and nothing leaves the Mac. It stores one value in UserDefaults on this Mac: `symbolUsage`, JSON with a score and a last-used date for up to 120 symbol names, counted apart from emoji. Each paste or copy adds a point, and points halve every 30 days. It feeds the *Frequently used* row and breaks ties in search (`UsageRanking` in CortexCore).

The symbol list is read, read-only, from `/System/Library/CoreServices/CoreGlyphs.bundle/Contents/Resources/`: `symbol_order.plist` (the names in order), `symbol_search.plist` (search words), and `name_availability.plist` (which macOS release introduced each symbol). These files belong to the OS and are not an API, so `SymbolCatalog.system()` reads them defensively and returns an empty catalog, with a log message, if one is missing or has another shape. A symbol without search words of its own takes those of the longest shorter name that has some (`heart.circle.fill` uses `heart`'s). The catalog is built once per launch.

## How it works

| File | Role |
| --- | --- |
| `Cortex/Modules/Symbols/SymbolsModule.swift` | The `CortexModule` (id `symbols`, trigger `::`, order 50, asks for Accessibility). No options. |
| `SymbolsScope.swift` | The `PaletteScope`: a 14-column `ResultGrid`, `sections(in:query:usage:)`, the four activation hints (name or picture, paste or copy), and `choose`. Search runs off the main actor. |
| `SymbolCatalog.swift` | `SFSymbol` and `SymbolCatalog`: reads `CoreGlyphs.bundle`, filters by OS version and localised copies, and ranks matches. The initialiser takes plain dictionaries, so tests can build a catalog without the system files. |
| `SymbolImage.swift` | Draws a symbol into a bitmap, paints it black, and returns PNG data. `nil` for an unknown name. |
| `SymbolsSettings.swift` | Usage in UserDefaults. |
| `Views/SymbolsView.swift` | The grid cells (`Image(systemName:)`), the empty states and the detail strip. |

The grid and the delivery of text or images (`closeAndDeliver`, `PasteContent.text` and `.image`, `restoringPasteboard`) are host code shared with Emoji; see [ARCHITECTURE.md](../ARCHITECTURE.md). `UsageRanking` is in CortexCore, so both modules share it. SF Symbols offers no API to other modules.

## Tests

- `CortexTests/Modules/Symbols/SymbolTests.swift`: leaving out localised copies and too-new symbols, the order, ranking (exact name, prefixes, parts, dots left out, keywords and inherited keywords), usage as a tie-break, reading the system files and an empty catalog when they are missing, the PNG (transparent, black ink, no picture for an unknown name), the scope (listing and searching this Mac's symbols, ⏎ pastes the name, ⇧⏎ the picture, the empty-catalog message) and stored usage. The usage ranking itself is tested with the emoji in `CortexCore/Tests/CortexCoreTests/Emoji/EmojiTests.swift`.
- Manual: [MANUAL_TESTS.md](../MANUAL_TESTS.md) M22 (Xcode and TextEdit for names, Keynote or Figma for pictures, clipboard restore, the frequently used row, switching between `:` and `::`).
