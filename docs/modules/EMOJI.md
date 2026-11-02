# Emoji

The Emoji module finds an emoji by name, keyword or shortcode and pastes it into the app you are in. Type `:` in the palette to get a grid of emoji. Pasting an emoji does not change your clipboard.

## Using it

Type `:` in the palette. Without a query the grid shows a *Frequently used* row (one row of up to 14) once you have used some, then every category: Smileys & Emotion, People & Body, Animals & Nature, Food & Drink, Travel & Places, Activities, Objects, Symbols and Flags. Below the grid, the selected emoji is shown large with its name, up to two shortcodes (`:thumbs_up:`) and its code points.

Typing searches names, keywords and shortcodes. Examples: `:thumbs`, `:thumbsup:`, `:+1`, `:fire`, or, with German among your system languages, `:daumen`. Every word has to match. Case, accents, spaces, underscores and a colon at either end do not matter: `:redheart` finds "red heart". Results are ordered by how well the match is: an exact shortcode or name first, then a name or shortcode that starts with the word, then a word inside the name, then keywords, then any part of a name. Ties go to the emoji you use more, then to Unicode order.

The search covers English plus the languages of your macOS language list that the data has (English and German are included). The name below the grid is shown in the first of those languages that has one.

| Key | Does |
| --- | --- |
| ← → ↑ ↓ | Move through the grid. → at the end of a row continues in the next row, ↓ at the end of a category goes to the next one. |
| ⏎ | Pastes the selected emoji into the app you came from, and closes the palette. |
| ⌥⏎ | Copies it instead. |
| ⌘1 to ⌘9 | Pastes the emoji at that position, counted from the start of the grid. |
| ⇥ | Cycles the skin tone: none (yellow), then the five tones, then none again. |
| Click | Selects. A double click pastes. |

The skin tone applies to every emoji that has the five tone variants, in the grid and when pasting. Emoji without variants (and those with two people, which have none in the data) stay as they are.

Pasting writes the emoji to the pasteboard, posts ⌘V into the app and, once the app has read it, puts the previous clipboard content back. It is not recorded in the clipboard history. Copying with ⌥⏎ is different: the emoji replaces the clipboard and, like any copy, is recorded in the history. Pasting needs Accessibility; without it ⏎ only copies.

A query that starts with a backslash searches the clipboard history instead (`\:smile`), for text that happens to start with `:`.

## Settings

Settings → Emoji (with the module's Enabled switch, on by default):

| Option | Default | Meaning |
| --- | --- | --- |
| Skin tone | Default (yellow hand) | The tone used for emoji that have variants. ⇥ in the palette changes the same setting. |

There is no hotkey and no status menu item.

## Data and privacy

The module has no database tables and nothing of yours leaves the Mac. It stores two things in UserDefaults, on this Mac only (settings and usage are not synced; see [SYNC.md](../SYNC.md)):

- `emojiSkinTone`: the chosen tone (0 for none).
- `emojiUsage`: JSON with a score and a last-used date for up to 120 emoji. Each use adds a point; points halve every 30 days, so what you use lately ranks above what you used a lot long ago. A paste and a copy both count. It feeds the *Frequently used* row and breaks ties in search (`UsageRanking` in CortexCore).

The emoji data is a bundled file, `CortexCore/Sources/CortexCore/Emoji/emoji.json`, read once per launch. No network access is used at run time.

### Updating the emoji data

The names, keywords and skin tones come from [Emojibase](https://emojibase.dev) (MIT; the names and keywords are from Unicode CLDR), plus the CLDR and GitHub shortcodes. The file is generated and committed. To update it for a newer Emoji version:

```bash
scripts/generate-emoji-data.py            # the version set in the script
scripts/generate-emoji-data.py 17.0.0     # or an emojibase-data version
```

The script downloads the English and German data from the `emojibase-data` package on jsDelivr, so it needs network access and Python 3. It drops the group of components and regional indicators, folds the skin tone variants into their base emoji (only emoji with all five single-person variants get tones), merges the two shortcode lists and writes the file sorted by group and Unicode order. Then raise `EmojiCatalog.maxVersion` to the newest Emoji version this macOS can draw: entries with a newer version are left out of the picker so they do not show as boxes. To add a language, add its code to `LANGUAGES` in the script; the catalog uses the languages listed in the file.

## How it works

| File | Role |
| --- | --- |
| `Cortex/Modules/Emoji/EmojiModule.swift` | The `CortexModule` (id `emoji`, trigger `:`, order 40, asks for Accessibility). One option, the skin tone. |
| `EmojiScope.swift` | The `PaletteScope`: a `ResultGrid` of 14 columns, `sections(in:query:languages:usage:)` (frequently used and categories, or one section of matches), the ⇥ key, and `choose`, which delivers the text through the host with `restoringPasteboard: true`. Search runs off the main actor. |
| `EmojiSettings.swift` | The skin tone and usage in UserDefaults. |
| `Views/EmojiView.swift` | The grid cells and the detail strip. |
| `CortexCore/Sources/CortexCore/Emoji/Emoji.swift` | `Emoji`, `EmojiGroup`, `EmojiSkinTone`. |
| `EmojiCatalog.swift` | Loads `emoji.json`, filters by `maxVersion`, folds the search index up front (so a search per keystroke is cheap) and scores matches. It reuses `SnippetSearch.fold`. |
| `scripts/generate-emoji-data.py` | Generates `emoji.json`. |

The grid layout (`ResultGrid`, `PaletteGrid`, `PaletteGridLayout`, `DetailStrip`) and the delivery of text (`closeAndDeliver`, `PasteService`) are host code shared with SF Symbols; see [ARCHITECTURE.md](../ARCHITECTURE.md). The `:` trigger and the longer `::` of [SYMBOLS.md](SYMBOLS.md) are told apart by the host (the longest prefix wins). Emoji offers no API to other modules.

## Tests

- `CortexCore/Tests/CortexCoreTests/Emoji/EmojiTests.swift`: the bundled data, ordering, search by name, keyword and shortcode, spaces and underscores, German and other languages, ranking, skin tones and their cycle, code points, the version filter, and usage scores and their decay.
- `CortexTests/Modules/Emoji/EmojiScopeTests.swift`: the categories and the frequently used row, search sections, grid movement across rows and categories, pasting in the skin tone, copying, ⌘ digits, ⇥, and stored settings.
- Manual: [MANUAL_TESTS.md](../MANUAL_TESTS.md) M21 (pasting into real apps, clipboard restore, frequently used row after a relaunch, without Accessibility).
