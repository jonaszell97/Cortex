# Calculator

Type `=` in the palette to calculate and convert units as you type: `=1920/1080`, `=sqrt(2) * pi`, `=3 in to cm`, `=20 °C to F`. The result is the first row and ⏎ pastes it. Everything is computed on this Mac, offline, by a parser of Cortex's own (not `NSExpression`, which accepts function calls and key paths and raises exceptions Swift cannot catch).

## Using it

Type `=` in the palette, then the calculation. It is evaluated on every keystroke, with no pause. The placeholder of the empty palette lists `= calculate`. There is no hotkey and no menu item.

| Typed | Rows | Pane |
| --- | --- | --- |
| `=` | Your recent calculations, newest first, each with what it comes to | The selected calculation and its result |
| `=1920/1080` | `1.777777778`, `1.7777777777777777` | `1920 ÷ 1080`, the result large, "Exactly …" when it is rounded |
| `=3 in to cm` | `7.62 cm`, `7.62` | `3 inches → centimetres` |
| `=5 ft` | `1.524 m`, `152.4 cm`, `60 in` | `5 feet` |
| `=1/0` | none | "Division by zero", in red |
| `=3 kg to cm` | none | "Can't convert mass to length", in red |
| `=3 +` | none | Nothing; the list shows examples (the input is unfinished, not wrong) |

The rows:

- **Result.** The number in your system's number format (`2,073,600`, or `2.073.600` with a German format), rounded to 10 significant digits by default.
- **Plain number, for code.** The same with a `.` as decimal point, no thousands separators and full precision (`1.7777777777777777`). Left out when it equals the first row.
- **A conversion** (`=3 in to cm`) has three rows: the value with its unit, the value without it, and the plain number.
- **A unit alone** (`=5 ft`) lists the value in other units: up to two units of each other system (metric, imperial, binary), then up to two of its own, each the largest common unit in which the value is still at least 1. A temperature lists every other scale.

| Key | Does |
| --- | --- |
| ⏎ | Pastes the selected row into the app the palette was opened over. On a recent calculation: puts it back into the field. |
| ⌥⏎ | Copies the selected row instead. |
| ⌘1 to ⌘9 | Pastes the row in that position. |
| ⇥ | Puts the selected result back into the field, exact and with its unit (`=7.62 cm`), to keep calculating or convert it again. |
| ⌘⌫ | On an empty `=`, forgets the selected recent calculation. Elsewhere it deletes text as usual. |

A pasted or copied result is recorded as a clip in the history, like a quick action's result, and the calculation is added to the recent list. Pasting needs Accessibility, like every paste. Typed input is never sensitive. ⏎ with no result beeps.

A bare query without `=` stays a clipboard search: the Clipboard module owns the default scope, and a calculator row there would turn searches like `2024-10` into arithmetic. To search the clipboard history for text that starts with `=`, put a backslash in front: `\=5`.

### The maths

- **Numbers:** `42`, `3.5`, `.5`, `1e6`, `0x1F`, `0b101`, and `_` or spaces between digits (`1_000_000`; `3 4` is 34). Your system's decimal separator is accepted too, so `3,5` works with a German format. Thousands separators are not: with a German format `1,000` is 1.
- **Operators**, from weakest to strongest: `+` `−`; `*` `/` `×` `·` `÷`; unary `−` and `+`; `^` or `**` (right-associative: `2^3^2` is `2^9`; `−2^2` is `−4`); postfix `%` (divides by 100, so `15% * 80` is 12) and postfix `°` (degrees to radians). `x` is not multiplication, and there is no implicit multiplication (`2pi`).
- **Functions** (one argument, in parentheses): `sqrt`, `abs`, `round`, `floor`, `ceil`, `ln`, `log` (base 10), `sin`, `cos`, `tan` (radians: `sin(30°)` for degrees). `sin`, `cos` and `tan` are exact at multiples of π/2 (`sin(pi)` is 0, `tan(pi/2)` is undefined).
- **Constants:** `pi`, `π`, `e`. Names are not case-sensitive.
- **Parentheses** still open at the end are closed for you (`=(1+2` is 3). Nesting deeper than 100 levels is an error.
- Numbers are `Double`. Infinity and NaN are errors. `0.1+0.2` shows `0.3` and has `0.30000000000000004` as its plain row.

### Units

`<calculation> <unit> [to | as | in | → | -> <unit>]`. The calculation is a plain number and the unit comes after it: `=(1920/1080) m to ft`. Units do not take part in arithmetic, so adding quantities (`5 ft + 3 in`) is not supported.

`in` is both inches and "convert to". It converts only when the text before it already ends in a unit and a unit follows it, so `3 in to cm`, `3 in in cm` and `3 m in ft` all work.

Kinds: length, mass, volume (US measures), area, temperature, time, speed, data sizes, energy, pressure and angles, by symbol or name in English or German. Symbols are case-sensitive (`MB` is megabytes, `Mb` megabits, `C` Celsius), names are not (`Meter`, `metres`, `zoll`). `KB` is 1000 bytes and `KiB` 1024. Lower-case `mb` and `gb` are bytes; bits need `Mb` or `Mbit`. `Pfund` is left out (500 g in German use, not the 453.6 g of `lb`), and so is `grad` (degrees in German, gradians in English; gradians are `gon`). The factors are exact by definition, not Foundation's `Dimension`s, which are rounded to about six digits. A conversion is rounded to 15 significant digits, so `3 in` is `7.62 cm` and not `7.619999999999999`.

### Errors

Wrong input shows in red in the pane and the empty list: "Division by zero", "Unknown unit: flurbs", "Can't convert mass to length", "Unknown name: foo", "Write sqrt(…)", "The result is too large", "The result is undefined" (`sqrt(-1)`, `ln(0)`, `tan(pi/2)`), "Too many nested parentheses". Unfinished input (`3 +`, `sqrt(`, `3 m to c`, `3 ki`) shows nothing, so typing does not flash errors.

## Settings

Settings → Calculator has the module's Enabled switch (on by default) and:

| Option | Default | Meaning |
| --- | --- | --- |
| Significant digits | 10 | Of the result row, 1 to 15. The plain number below it is exact. |
| Result format | System | How the result row writes decimals: the system's number format with its grouping (`1,234.5`), or a plain point without grouping (`1234.5`). The plain row always uses a point, and what you type may use the system's separator either way. |
| Keep recent calculations | on | Listed after `=` with nothing typed. Only on this Mac. Switching it off forgets them. |
| Recent calculations | | *Clear* removes them. Greyed out when there are none. |

## Data and privacy

The module has no database table, no files and no network access.

- **Settings and recents** are in UserDefaults on this Mac: `calculator.digits`, `calculator.decimalSeparator`, `calculator.keepRecents` and `calculator.recents` (an array of the last 20 calculations as typed, trimmed). They are evaluated again when listed, so they follow the current settings. They never leave the Mac and are not synced. The module switch is `module.calculator.enabled`.
- **Results** that you paste or copy become clips in the clipboard database, not marked sensitive. They sync like any clip when clip sync is on ([CLIPBOARD.md](CLIPBOARD.md), [SYNC.md](../SYNC.md)). Anything else you type after `=` is not stored beyond the recents.
- Switching the module off clears its list and keeps the recents.

## How it works

The maths has no AppKit and lives in `CortexCore/Sources/CortexCore/Calculator/`; the module is in `Cortex/Modules/Calculator/`.

| File | Role |
| --- | --- |
| `CalcLexer.swift` | Text to tokens: numbers (hex, binary, exponents, separators), names, operators. |
| `CalcParser.swift`, `CalcExpression.swift` | Recursive descent with precedence into a `CalcExpression` tree, which can also print itself for the pane (`1920 ÷ 1080`). Tells unfinished input from wrong input. |
| `CalcEvaluator.swift`, `CalcError.swift` | Tree to a value, checked at each step, or a `CalcError` with the message the pane shows. |
| `CalcQuery.swift` | Splits off the unit and the conversion target (the `in` rule, `to`/`as`/`→`), then parses the rest. `evaluate()` gives a `CalcResult`; `text` is how the query was read. |
| `UnitCatalog.swift`, `CalcUnit.swift` | The units: a factor to the base unit of the kind (and an offset for temperatures), names, system and whether a unit is common. Lookup by symbol or word, the longest name first (`km/h` before `h`), and `equivalents(of:in:)` for `=5 ft`. |
| `CalcFormatter.swift` | `display` (digits, locale, scientific notation outside 1e-6 to 1e15) and `plain` (shortest text that reads back). |
| `Modules/Calculator/CalculatorModule.swift` | The `CortexModule` (id `calculator`, trigger `=`, order 45, asks for Accessibility). The Settings options. |
| `Modules/Calculator/CalculatorScope.swift` | The `=` scope: rows (`CalculatorRow`), recents, activation and keys. |
| `Modules/Calculator/CalculatorSettings.swift` | The settings and recents over `ModuleDefaults`. |
| `Modules/Calculator/Views/CalculatorViews.swift` | The list rows and the pane. |

`CalculatorScope.search` parses and evaluates the trimmed text with `CalcQuery`; an error other than `.unfinished` is kept for the pane. The scope uses two host calls (see [ARCHITECTURE.md](../ARCHITECTURE.md)): `closeAndDeliver` with `.record(sensitive: false)` to paste or copy a row, and `PaletteHost.open(_:searching:)` to reopen the scope with text in the field, for ⇥ and for ⏎ on a recent calculation. The system's decimal separator is read from the locale and passed to the lexer. To add a unit, add a `CalcUnit` to the table of its kind in `UnitCatalog` with an exact factor; `UnitTests` checks conversions, names and the factors Foundation rounds.

## Not supported

- Bare queries without `=`.
- Arithmetic on quantities: `5 ft + 3 in to cm`, `60 km / 1.5 h`.
- Currency (it would need exchange rates from the network), time zones and dates.
- Variables, `ans`, and a calculation history that syncs.

## Tests

- `CortexCore/Tests/CortexCoreTests/Calculator/`: `CalculatorTests` (lexer, precedence and associativity, unfinished versus wrong input, functions, formatting and rounding) and `UnitTests` (conversions of every kind, the `in` rule, German names, decimal and binary data sizes, the exact factors, `equivalents`).
- `CortexTests/Modules/Calculator/CalculatorScopeTests.swift`: the rows (a calculation, grouping, German numbers, the point format, digits, conversions, a quantity in other units, errors against unfinished input), the keys (⏎, ⌥⏎, ⌘1–9, ⇥, ⌘⌫, the hints), the recents (newest first, moving to the top, the cap of 20, switching them off, clearing) and the stored keys. `ModuleLifecycleTests.calculatorDropsItsResults` checks that switching the module off empties the list and removes the `=` route.
- Manual: [MANUAL_TESTS.md](../MANUAL_TESTS.md) M28 (pasting into TextEdit and other apps, the German number format, settings, switching the module off).
