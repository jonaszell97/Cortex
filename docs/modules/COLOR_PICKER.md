# Color Picker

The Color Picker module shows the system's eyedropper so you can click a pixel anywhere on screen and have its colour copied, as `#1A2B3C` by default. The picked value becomes a clip, so the clipboard history is also the history of picked colours. The clipboard list shows any text clip that is nothing but a colour with a swatch, whether you picked it or copied it from a design tool or a stylesheet.

## Using it

Three ways to start the eyedropper:

- The hotkey, ⌃⌥⌘C by default.
- *Pick Color* in the status menu.
- `$color` in the palette (Commands module): the row is *Pick Color*, and ⏎ closes the palette and shows the eyedropper at once, with no progress card.

Click a pixel and its colour is copied, with a notification that says what was copied ("Copied #1A2B3C"). Esc leaves the clipboard as it was and posts nothing. A second press of the hotkey while the eyedropper shows does nothing. If the palette is open when you start, it closes first.

The colour is copied, never pasted, whichever way you started: you pick it from the app you will paste into, so ⏎ and ⌥⏎ in `$color` do the same. The value is recorded as a clip, newest in the history, with the swatch in its row.

**Values are sRGB.** That is what Figma, CSS and Digital Color Meter's "Display in sRGB" show. The eyedropper sees the display's colours (Display P3 on recent Macs) and Cortex converts them; colours outside sRGB are clamped to it.

**Swatches in the clipboard list.** A text clip that is nothing but a colour shows a swatch instead of the text icon, over a checkerboard when it is transparent. Its preview shows a large swatch with the colour as Hex, RGB, HSL and SwiftUI, to select and copy. What counts as a colour:

- Hex with a `#`: three, four, six or eight digits (`#1A2B3C`, `#fff`, `#1A2B3C80`).
- Hex without a `#`: only six or eight digits that mix letters and numbers (`1a2b3c80`). `123456` and `facade` stay text.
- `rgb(…)` and `rgba(…)` in the comma syntax (`rgb(26, 43, 60)`) or the space syntax (`rgb(26 43 60 / 50%)`); channels as 0 to 255 or percentages.
- `hsl(…)` and `hsla(…)`, with the hue in degrees (`210` or `210deg`) and percentages.
- Nothing longer than 64 bytes, and nothing with other text around it: `color: #ff8800` stays text.

A masked sensitive clip shows no swatch. Swatches are a feature of the clipboard list and work whether or not the Color Picker module is on.

No permission is needed: the eyedropper is drawn by macOS, so Cortex never records the screen.

## Settings

Settings → Color Picker has the module's Enabled switch (on by default) and:

| Option | Default | Meaning |
| --- | --- | --- |
| Pick color | ⌃⌥⌘C | Hotkey. Shows the eyedropper. |
| Copy as | Hex | Hex (`#1A2B3C`, `#1A2B3C80` with transparency), hex without `#` (`1A2B3C`), CSS `rgb()` (`rgb(26, 43, 60)`, `rgba(…, 0.5)`), CSS `hsl()` (`hsl(210, 40%, 17%)`) or SwiftUI `Color` (`Color(red: 0.102, green: 0.169, blue: 0.235)`, with `opacity:` when transparent). |
| Uppercase hex | on | `#1A2B3C` rather than `#1a2b3c`. Greyed out unless *Copy as* is one of the hex formats. |
| Show a notification after picking | on | The "Copied …" notification. |

There is no palette trigger of its own; `$color` is a command of the Commands module.

## Data and privacy

The module has no database table and no files. The three options are in UserDefaults as `color-picker.format`, `color-picker.uppercaseHex` and `color-picker.notify`, and the hotkey is stored by the KeyboardShortcuts package under the name `pickColor`. The module switch is `module.color-picker.enabled`. None of it syncs.

A picked colour is a text clip in the clipboard database, not marked sensitive, so it syncs like any clip when clip sync is on ([CLIPBOARD.md](CLIPBOARD.md), [SYNC.md](../SYNC.md)). The module reads only the one pixel you click, through `NSColorSampler`; nothing is captured, stored or sent, and it does not use Screen Recording. Switching the module off removes the hotkey, the status menu item and `$color`; the clips and swatches stay.

## How it works

| File | Role |
| --- | --- |
| `CortexCore/.../Color/ColorValue.swift` | A colour in sRGB (components 0 to 1, clamped), with 0 to 255 and HSL views. |
| `CortexCore/.../Color/ColorFormat.swift` | The five ways to write a colour (`string(for:uppercaseHex:)`). Its raw values are stored settings and must not change. |
| `CortexCore/.../Color/ColorParser.swift` | The strict reader behind the swatches: text that is nothing but a colour, or nil. |
| `Modules/ColorPicker/ColorPickerModule.swift` | The `CortexModule` (id `color-picker`, no trigger, order 55). The hotkey, the Settings options, the status menu item and `pick()`, which closes the palette, asks the sampler, formats the value with the settings, hands it to `closeAndDeliver(.text(value), .copyOnly, recording: .record(sensitive: false), …)` and posts the notification. Conforms to `CommandContributing`. |
| `Modules/ColorPicker/ColorSampler.swift` | `ColorSampling` (a protocol, so tests hand in a fake) and `SystemColorSampler`, which runs `NSColorSampler` and converts the colour to sRGB. |
| `Modules/ColorPicker/ColorPickerSettings.swift` | The three options over `ModuleDefaults`. |
| `Modules/ColorPicker/ColorPickerCommand.swift` | `$color` as a `Command`: it resolves to a handoff whose `run` starts the pick, so nothing is pasted, no result is shown and no progress card appears. |
| `Modules/Clipboard/Views/ColorSwatch.swift`, `ClipRowView.swift`, `ClipPreviewView.swift` | The swatch, and where the Clipboard module calls `ColorParser` for its rows and preview. |

The module contributes `$color` through `CommandContributing` while it is on ([COMMANDS.md](COMMANDS.md)). It uses the host's `closeAndDeliver` and notifier ([ARCHITECTURE.md](../ARCHITECTURE.md)); it names no other module. The Clipboard module's swatches use only `CortexCore`, so they need no API from this one. To add a format, add a case to `ColorFormat` with its `title` and `string(for:uppercaseHex:)`, and a test in `ColorFormatTests`.

## Tests

- `CortexCore/Tests/CortexCoreTests/Color/ColorTests.swift`: `ColorParserTests` (what is and is not a colour, from lists of examples) and `ColorFormatTests` (every format, with transparency, greys and primaries, clamping out-of-gamut components).
- `CortexTests/Modules/ColorPicker/ColorPickerTests.swift`: a pick copies the colour as a new clip, Esc leaves the clipboard alone, the palette closes first, the chosen format is used, a second press while picking does nothing, `$color` starts a pick, and the settings are stored under the module ID. `ModuleLifecycleTests.colorCommandFollowsTheColorPickerSwitch` checks that `$color` follows the switch.
- Manual: [MANUAL_TESTS.md](../MANUAL_TESTS.md) M26 (the real eyedropper, a Display P3 pixel against Digital Color Meter, swatches for copied colours, `$color`, switching the module off).
