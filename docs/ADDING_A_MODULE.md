# Adding a module

Every feature of Cortex is a module: one folder in the app, one type that conforms to `CortexModule`, listed once in `App/ModuleList.swift`. The host gives it a page in Settings with an on/off switch, a palette trigger if it wants one, a group in the status menu, hotkeys, and the shared services (database, pasting, Keychain). [ARCHITECTURE.md](ARCHITECTURE.md) explains the design; this is the checklist.

A built-in quick action is not a module: it goes into the Quick Actions module ([ADDING_ACTIONS.md](ADDING_ACTIONS.md)). So does a TOML action file, which needs no code at all.

The example throughout is the Calculator, simplified: `=2*(3+4)` in the palette shows the result, ⏎ pastes it. The real module is in `Cortex/Modules/Calculator/`, its maths in `CortexCore/Sources/CortexCore/Calculator/`.

New files need no `make project`: the source and test folders are synced.

## 1. The folder

`Cortex/Modules/<Name>/`, the name in UpperCamelCase. The file names are fixed, so every module reads the same way:

| File | When | Contents |
| --- | --- | --- |
| `<Name>Module.swift` | always | The `CortexModule` type: manifest, options, hotkeys and their `KeyboardShortcuts.Name`s, status menu items, `start`/`stop`. Its doc comment describes the module (no README files in source folders: synced folders would copy them into the app bundle). |
| `<Name>API.swift` | if other modules use it | The protocol and value types other modules may name (§5). |
| `<Name>Scope.swift` | if it is in the palette | The `PaletteScope` (§3). |
| `<Name>Service.swift` | for long-lived logic | Stores, monitors, taps, watchers. |
| `<Name>Settings.swift` | if it has settings | An `@Observable` class over UserDefaults (§4). |
| `<Name>SettingsView.swift` | if options are not enough | Extra sections for its Settings page. |
| `Views/` | as needed | Its SwiftUI views. |

Platform-independent logic (anything iOS could use, anything worth testing without AppKit) goes into `CortexCore/Sources/CortexCore/<Name>/`, tested in `CortexCore/Tests/CortexCoreTests/<Name>/` with `make test`. A module that needs a table adds a migration to `AppDatabase`, named `v<n>_<moduleID>_<what>`, after the existing ones (they have shipped; GRDB applies them by name). Tables exist whether the module is on or not, and switching it off never deletes data.

## 2. The module type

```swift
// Cortex/Modules/Calculator/CalculatorModule.swift
import SwiftUI

/// `=` in the palette: evaluates arithmetic as you type, ⏎ pastes the result.
@MainActor
final class CalculatorModule: CortexModule {
    static let manifest = ModuleManifest(
        id: "calculator", name: "Calculator", summary: "Evaluates arithmetic in the palette.",
        symbol: "plus.forwardslash.minus", trigger: .prefix("="), placeholder: "calculate",
        permissions: [.accessibility], order: 45)

    private let settings: CalculatorSettings
    private let scope: CalculatorScope

    /// No side effects here: no taps, timers, watchers or hotkeys.
    init(context: ModuleContext) {
        settings = CalculatorSettings(defaults: context.defaults)
        scope = CalculatorScope(settings: settings) { [context] in context.palette }
    }

    var palette: (any PaletteScope)? { scope }

    func stop() {
        scope.clear()
    }
}
```

Then add `CalculatorModule.self` to `ModuleList.all`, in the order the modules should start (a module that another one requires starts first).

**The manifest.** Only `id`, `name`, `summary`, `symbol` and `order` are always spelled out.

- `id`: lowercase letters, digits and hyphens. **Stable forever**: the switch (`module.<id>.enabled`), scoped settings and secrets are stored under it.
- `trigger`: `.prefix("=")` for a palette scope, nil for a background module (Scrolling, Sync). `.default` is Clipboard's (no trigger). The longest prefix wins, so `::` beats `:`; `\` at the start of a query escapes a trigger. Triggers in use: `;` `+` `?` `!` `>` `$` `:` `::` `=`. Two modules with the same trigger are a manifest problem: Debug builds stop, Release lists it under Settings → General.
- `placeholder`: the module's part of the search field's placeholder ("= calculate").
- `subscopes`: further scopes under triggers of their own, each with a route ID distinct from every module's (Knowledge has `?` for the knowledge base and the subscope `todos` under `!`). The module returns their scopes from `palette(_:)`; `PaletteHost.open("todos")` opens one.
- `enabledByDefault`: false for anything that does work in the background the user did not ask for (an event tap, a server).
- `requirements`: `.database` if it cannot run without it; `.module(id)` if it needs another module to be on (AI needs `actions`). Settings shows the switch off and says why while a requirement is not met.
- `permissions`: `.accessibility` for pasting or event taps, `.finderAutomation` for the Finder selection, `.screenRecording` for capturing the screen. Settings → General → Permissions lists only what active modules ask for; onboarding asks only for Accessibility. A module that needs Screen Recording is off by default, so nobody is asked for it before they want the feature.
- `order`: the position in Settings, the placeholder and the status menu. The existing modules use 10 to 70 in steps of 10, Reading List 25 to sit after Snippets, Knowledge 27 after it, Commands 32 and AI 35 to sit after Quick Actions, Calculator 45 between Emoji and SF Symbols, Color Picker 55 between SF Symbols and Scrolling, Text Recognition 57 after it.

**What a module may implement** (everything but the manifest and `init` has a default):

| Member | For |
| --- | --- |
| `palette` | Its `PaletteScope`, under the manifest's trigger. |
| `palette(_:)` | The scope of each of the manifest's `subscopes`. |
| `options` | Simple settings drawn on its page (§4). |
| `settingsView` | `Section`s below the options, for what options cannot express. |
| `settingsPanes` | Pages of their own in the Settings sidebar, under General, while the module is active (a `SettingsPane`: ID, title, symbol and a view, usually a grouped `Form`). |
| `hotkeys` | `ModuleHotkey`s: registered while the module is on, recorders on its page. |
| `statusMenuItems()` | Its group in the status menu, asked for whenever the menu opens and again while it is open when anything observable it read changes. |
| `statusIcon` | A menu bar icon while something is going on; the highest `priority` wins (the progress ring is 10, the pause icon 0). |
| `acceptsDroppedFiles(_:)` | Files dropped on the palette or the menu bar icon; return true if taken. |
| `start()` | The module was switched on (at launch or in Settings): start listeners, taps, watchers, timers. `context.palette` may be used from here on. |
| `stop()` | It was switched off: stop everything `start` began and drop what the palette loaded. Stored data stays. Starting again must not double anything up. |

Something that should run only while a setting asks for it and Accessibility is granted goes through `context.whileWanted` (see `ScrollingModule.start`): it starts and stops with the setting and retries when Accessibility is granted. Cancel the returned `ModuleTask` in `stop()`.

**The context** is all a module gets from the host: `database` (nil if it could not be opened), `defaults`, `secrets`, `accessibility`, `pasting`, `pasteboard` (borrowing it without recording), `notifier`, `log`, `palette`, `api(_:)` and `apis(_:)` (§5), `whileWanted` and `requestAccessibility()`. A module never reaches for `AppDelegate`.

## 3. The palette scope

The host owns the panel, the search field, trigger resolution, key dispatch, Esc and the hints bar. The scope owns what the query means, the results and their selection, the view, and what ⏎ and its own keys do.

```swift
// Cortex/Modules/Calculator/CalculatorScope.swift
@MainActor
@Observable
final class CalculatorScope: PaletteScope {
    private(set) var result: String?
    @ObservationIgnored private let settings: CalculatorSettings
    @ObservationIgnored private let palette: @MainActor () -> any PaletteHost

    init(settings: CalculatorSettings, palette: @escaping @MainActor () -> any PaletteHost) {
        self.settings = settings
        self.palette = palette
    }

    /// The query without the trigger, on every edit.
    func search(_ text: String) { result = Calculator.evaluate(text, precision: settings.precision) }
    /// The palette hid: nothing loaded may stay in memory.
    func clear() { result = nil }

    var body: AnyView { AnyView(CalculatorView(scope: self)) }
    func move(_ step: PaletteStep) {}

    func activate(_ activation: PaletteActivation, target: PaletteTarget) -> Bool {
        guard let result else { return false }
        palette().closeAndDeliver(
            .text(result), activation.isCopy ? .copyOnly : .paste(.plainText), restoringPasteboard: false, after: nil)
        return true
    }

    var activationHints: [PaletteHint] { [PaletteHint(.primary, "Paste"), PaletteHint(.option, "Copy")] }
}
```

- The scope takes a closure for the palette rather than the context: `context.palette` exists only from `start()` on, and tests hand in a `FakePaletteHost`.
- Build the view from the shared components in `Cortex/Host/Components/`, never from the theme directly: a list is `ResultList` (state and selection) with `PaletteList` and `PaletteRow` in a `PaletteSplitLayout` with a preview (Snippets); a grid is `ResultGrid` with `PaletteGrid` in a `PaletteGridLayout` with a `DetailStrip` (Emoji, Symbols). `PaletteEmptyState` and `TextPreview` cover the rest.
- `navigation` is `.list` (↑↓) by default or `.grid(columns:)` (←→ too). `keys` are further keys with hints (`PaletteKey(.command("e"), hint: "Edit") { … }`); `cancel()` lets Esc step back inside the scope; `modifiersChanged` sees ⌥; `didLeave()` is called when the user switches to another scope.
- Forms and confirmations over the list are overlays: `palette().present(PaletteOverlay(…))` (the snippet fill-in form).
- Delivering: `closeAndDeliver` closes the palette and pastes into the app it was opened over, or copies, and asks for Accessibility if pasting failed for want of it. `restoringPasteboard: true` keeps the result out of the clipboard history and puts the clipboard back (emoji, symbols). For content that has to be computed in the target app, the other form takes a closure.
- The module reloads its own scope when its data changes; a scope that has not searched since the palette hid ignores that.

## 4. Settings

The module's page is generated: header with the Enabled switch, its hotkeys, its `options`, then its `settingsView`. Everything below the header is greyed out while the module is off.

```swift
// Cortex/Modules/Calculator/CalculatorSettings.swift
@MainActor
@Observable
final class CalculatorSettings {
    @ObservationIgnored private let defaults: ModuleDefaults
    var precision: Int { didSet { defaults.set(precision, for: "precision") } }   // "calculator.precision"

    init(defaults: ModuleDefaults) {
        self.defaults = defaults
        precision = defaults.integer("precision") ?? 4
    }
}

// In CalculatorModule:
var options: [ModuleOption] {
    [ModuleOption(id: "precision", title: "Decimal places", kind: .integer(Bindable(settings).precision, range: 0...12, unit: nil))]
}
```

- Option kinds: `.toggle`, `.integer`, `.choice`, `.text`, `.secret` (Keychain, through `context.secrets.key("token", title: "API token")`, account `<id>.token`), `.folder` and `.button`. Option IDs are unique within the module (`ModuleListTests` checks); `isEnabled` greys one out.
- New keys go through `context.defaults` and are stored as `<id>.<name>`. Never rename a stored key; a setting that existed before modules keeps its name with `.legacy("name")` or by reading `defaults.store` directly, and is added to the list in [Stored keys and names that must not change](ARCHITECTURE.md#stored-keys-and-names-that-must-not-change).
- A hotkey is a `KeyboardShortcuts.Name` declared in `<Name>Module.swift` (its name is stored, so it never changes) and a `ModuleHotkey(.name, title: "…:", help: "…") { … }`. The host registers it the first time the module starts and only lets presses through while the module is on.

## 5. Talking to other modules

A module may name another module's types only if they are declared in that module's `<Name>API.swift`. Offer something with a protocol there, conform the module to it, and let others look it up:

```swift
// Cortex/Modules/Calculator/CalculatorAPI.swift
@MainActor protocol CalculatorAPI: AnyObject {
    func evaluate(_ expression: String) -> String?
}

// Somewhere in another module:
context.api(CalculatorAPI.self)?.evaluate("2+2")
```

`api(_:)` is nil while the providing module is off, so hide what depends on it (a hint, a menu item) rather than failing. `apis(_:)` returns every active module that provides a type, in list order.

Existing APIs: `ClipboardAPI` (older clips for snippets), `SnippetsAPI` (open the editor), `ActionsAPI` (open `>` on an input), Quick Actions' `ActionContributing`, through which a module adds its own `QuickAction`s to `>` and Shortcuts while it is on (AI), and Sync's `SyncContributing`: a module whose data should travel between Macs returns `SyncContribution`s (collection, its switch under Settings → Sync → What to sync, options, a handler per cycle, what to reload after remote changes). That also needs a `SyncCollection` case, a payload and change tracking (`SyncSchema`) in CortexCore; see [Handling per data type](SYNC.md#handling-per-data-type) in SYNC.md and the Snippets module.

`scripts/check-modules.sh`, run by `make test-app`, fails when a module folder has no `<Name>Module.swift`, when `App/` or `Host/` name a module's type (only `ModuleList` may), or when a module names another's types outside its `API.swift`.

## 6. Tests

- `CortexTests/Modules/<Name>/`: the scope, built without a `ModuleHost` (settings over a throwaway `UserDefaults(suiteName:)`, `FakePaletteHost` for the palette, `makeTestDatabase()` if it needs data). `EmojiScopeTests` and `SnippetsScopeTests` are the examples.
- `CortexTests/Modules/ModuleLifecycleTests.swift`: on, off and on again leaves no tap, timer, watcher or loaded content behind, and starts nothing twice.
- `ModuleListTests` and `ModuleHostTests` already cover every listed module's manifest, option IDs and permissions: run them.
- Core logic in `CortexCore/Tests/CortexCoreTests/<Name>/` (`make test`).
- `make test-app` runs the boundary check first, then the app tests.

## 7. Manual check and docs

- Add a check to [MANUAL_TESTS.md](MANUAL_TESTS.md) for what tests cannot see: pasting into real apps, event taps, windows, notifications, the look of the scope. Name the module in the list of what to run after a change.
- Give it its own page, `docs/modules/<NAME>.md`, with the same headings as the existing ones (Using it, Settings, Data and privacy, How it works, Tests): the trigger and keys and what its settings do go there. Add a row for it to the module table in [docs/README.md](README.md).
- Give it a short section in the main [README](../README.md): a screenshot, two or three sentences and a link to its page. The screenshot is a scene in `CortexTests/Screenshots/ReadmeScreenshots.swift` ([DEVELOPMENT.md](DEVELOPMENT.md#screenshots)).
- Add its stored keys and hotkey names to the list in [Stored keys and names that must not change](ARCHITECTURE.md#stored-keys-and-names-that-must-not-change), the things that must not change.
