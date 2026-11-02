# Architecture

Cortex is a small host and a set of modules. The host provides the palette panel, the settings window, the status item and the shared services (database, pasting, Keychain, notifications). Every feature is a module that plugs in through one protocol: clipboard history, snippets, reading list, knowledge base, quick actions, commands, AI, emoji, SF Symbols, calculator, colour picker, text recognition, scrolling and sync.

This is the reference for how that works and for the names that must not change. To add a module, see [ADDING_A_MODULE.md](ADDING_A_MODULE.md). To add a quick action, see [ADDING_ACTIONS.md](ADDING_ACTIONS.md). The sync protocol is in [SYNC.md](SYNC.md).

Modules are a code-structure idea only: no Swift packages, no frameworks, no dynamic loading. Everything is in the `Cortex` target and in the `CortexCore` package. A module is one folder plus one type that conforms to `CortexModule`, listed once in `Cortex/App/ModuleList.swift`.

## Modules

Each module has a page of its own: its trigger and keys, its settings, what it stores.

| Module | ID | Trigger | Page |
| --- | --- | --- | --- |
| Clipboard | `clipboard` | none (the default) | [modules/CLIPBOARD.md](modules/CLIPBOARD.md) |
| Snippets | `snippets` | `;` | [modules/SNIPPETS.md](modules/SNIPPETS.md) |
| Reading List | `reading-list` | `+` | [modules/READING_LIST.md](modules/READING_LIST.md) |
| Knowledge | `knowledge` | `?`, and `!` for to-dos | [modules/KNOWLEDGE.md](modules/KNOWLEDGE.md) |
| Quick Actions | `actions` | `>` | [modules/ACTIONS.md](modules/ACTIONS.md) |
| Commands | `commands` | `$` | [modules/COMMANDS.md](modules/COMMANDS.md) |
| AI | `ai` | none | [modules/AI.md](modules/AI.md) |
| Emoji | `emoji` | `:` | [modules/EMOJI.md](modules/EMOJI.md) |
| Calculator | `calculator` | `=` | [modules/CALCULATOR.md](modules/CALCULATOR.md) |
| SF Symbols | `symbols` | `::` | [modules/SYMBOLS.md](modules/SYMBOLS.md) |
| Color Picker | `color-picker` | none (a hotkey) | [modules/COLOR_PICKER.md](modules/COLOR_PICKER.md) |
| Text Recognition | `text-recognition` | none (a hotkey) | [modules/TEXT_RECOGNITION.md](modules/TEXT_RECOGNITION.md) |
| Scrolling | `scrolling` | none | [modules/SCROLLING.md](modules/SCROLLING.md) |
| Sync | `sync` | none | [modules/SYNC.md](modules/SYNC.md) |

## Repository layout

```
Cortex/
├── App/            AppDelegate, ModuleList, MainMenu, LaunchAtLogin, AccessibilityPermission
├── Host/
│   ├── Modules/    CortexModule, ModuleManifest, ModuleContext, ModuleHost, ModuleOption,
│   │               ModuleDefaults, ModuleSecrets, ModuleHotkey, ModuleTask
│   ├── Palette/    PanelController, PalettePanel, PaletteModel (the router), PaletteView, PaletteScope,
│   │               PaletteHost, PaletteOverlay, PaletteRouting, PaletteKeyMap, KeyCombo, KeyHintsBar,
│   │               PaletteLanding, PanelPlacement, PaletteTheme, PaletteSettings, Shortcuts
│   ├── Components/ ResultList, PaletteList, PaletteRow, ResultGrid, PaletteGrid, PaletteSplitLayout,
│   │               PaletteGridLayout, DetailStrip, PaletteEmptyState, TextPreview,
│   │               ActionOptionControl, SuggestingTextField
│   ├── Pasting/    Paster, PasteService, PasteboardActivity, PasteboardReader
│   ├── StatusMenu/ StatusItemController, StatusMenuItem, StatusMenuSection, ProgressRing
│   ├── Settings/   SettingsWindowController, SettingsView, GeneralSettingsView, ModuleSettingsPage,
│   │               ModuleOptionsForm, SecretOptionRow, ShortcutRecorder, PaletteStylePicker
│   ├── Onboarding/ OnboardingWindowController
│   └── Support/    Notifier, DirectoryWatcher, ScreenRecordingPermission, Beep, UsageRanking+Defaults
├── Modules/        one folder per module (see ADDING_A_MODULE.md for the file names inside)
└── AppIcon.icon/

CortexCore/Sources/CortexCore/
├── Foundation/     AppDatabase, AppPaths, DatabaseKey, KeychainStore, Log, UsageRanking
├── Clipboard/  Snippets/  Actions/  Commands/  AI/  Emoji/  Calculator/  Color/
├── ReadingList/  Knowledge/  TextRecognition/
└── Sync/           engine, transport, schema, keys, SyncEntityHandler
```

`CortexCore` is one target. The iOS companion app (`CortexMobile/`, with its share extension `CortexShare/` and widget extension `CortexWidgets/`; [plans/IOS.md](../plans/IOS.md)) uses it and has no modules, so it holds the platform-independent half of each module: the models, the maths, the parsers, the sync handlers next to what they sync. Tests mirror the folders: `CortexTests/Host/`, `CortexTests/Modules/<Name>/`, `CortexCore/Tests/CortexCoreTests/<Name>/`.

The rule that holds this together: `Host/` and `App/` name no type from `Modules/`. Only `App/ModuleList.swift` does. See "Modules talking to each other" for how it is enforced.

## The module protocol

```swift
@MainActor
protocol CortexModule: AnyObject {
    static var manifest: ModuleManifest { get }
    init(context: ModuleContext)

    var hotkeys: [ModuleHotkey] { get }          // default: []
    var options: [ModuleOption] { get }          // default: []
    var settingsView: AnyView? { get }           // default: nil
    var settingsPanes: [SettingsPane] { get }    // default: []

    var palette: (any PaletteScope)? { get }     // default: nil
    func palette(_ subscope: ModuleID) -> (any PaletteScope)?   // default: nil
    func acceptsDroppedFiles(_ urls: [URL]) -> Bool             // default: false

    func statusMenuItems() -> [StatusMenuItem]   // default: []
    var statusIcon: StatusIcon? { get }          // default: nil

    func start() async                           // default: nothing
    func stop()                                  // default: nothing
}
```

Everything but `manifest` and `init` has a default in a protocol extension, so a module implements only what it uses. Scrolling, for example, implements the manifest, `init`, `options`, `settingsView`, `start` and `stop`.

- `init(context:)` runs once at launch for every module, enabled or not. It has no side effects: no event taps, timers, watchers or hotkeys. A module that needs the database but got `nil` creates no service.
- `start()` runs when the module becomes active, at launch or when it is switched on in Settings. It starts listeners, taps, watchers and timers. `context.palette` may be used from here on.
- `stop()` runs when the module stops being active. It stops everything `start` began and drops what the palette loaded. Stored data is kept. Starting again must not double anything up.

## The manifest

`ModuleManifest` is everything the host needs to know about a module without starting it. It has a memberwise `init` with defaults, so only `id`, `name`, `summary`, `symbol` and `order` are always spelled out.

| Field | Meaning |
| --- | --- |
| `id` | A `ModuleID`: lowercase letters, digits and hyphens, starting with a letter. Stable forever: the enabled flag, scoped settings and secrets are stored under it. |
| `name`, `summary`, `symbol` | The name, one sentence and SF Symbol for the module's page in Settings. |
| `trigger` | `.default` (shown when the query has no trigger; exactly one module, Clipboard), `.prefix("=")` (the query starts with it), or `nil` (not in the palette). |
| `placeholder` | The module's part of the search field's placeholder: "snippets" becomes "; snippets". |
| `subscopes` | Further scopes under triggers of their own. Each is a `PaletteSubscope` (route ID, trigger, placeholder). The ID is distinct from every module's ID. Knowledge has `!` with the ID `todos`. The module returns the scope from `palette(_:)`. |
| `enabledByDefault` | `true` unless the module does background work the user did not ask for (an event tap, a server, a paid API). |
| `legacyEnabledKey` | A switch the feature had before modules, read as the enabled flag until `module.<id>.enabled` is first set. Scrolling uses `scrollReversal`, Sync uses `syncEnabled`. |
| `requirements` | `.database` (cannot run without it) or `.module(id)` (another module has to be active: Commands and AI need `actions`). |
| `permissions` | `.accessibility`, `.finderAutomation`, `.screenRecording`. Onboarding and Settings → General list only what active modules ask for. |
| `order` | Position in Settings, the placeholder and the status menu. Also the order in which modules are asked for status items and icons. |

Triggers in use: `;` `+` `?` `!` `>` `$` `:` `::` `=`. `\` at the start of a query is not a trigger but an escape (see "Trigger resolution").

## The registry and manifest validation

```swift
// Cortex/App/ModuleList.swift: the only place in App/ or Host/ that names a module.
enum ModuleList {
    static let all: [any CortexModule.Type] = [
        ClipboardModule.self, SnippetsModule.self, /* … */ SyncModule.self,
    ]
}
```

The order of `all` is the start order. A module that another one requires comes first. It is not the display order: that is `order` in the manifest.

`ModuleHost` (`Host/Modules/ModuleHost.swift`) takes the list and does the following at launch:

1. Validates the manifests with `ModuleManifest.problems(in:)`, a pure function. It reports a malformed ID, a duplicate ID, an empty or duplicate trigger (a subscope's trigger counts too), a subscope ID that clashes with a module ID or another subscope, a requirement on itself or on an unknown module, and anything other than exactly one `.default` module. Each problem is logged as a fault in the `modules` category. Debug builds stop at an `assert`. Release builds go on, and Settings → General lists the problems under "Modules".
2. Reads each module's switch (see "Enabling and disabling modules").
3. Creates every module with its own `ModuleContext`.
4. Starts the active modules one after the other, in list order. `ModuleHost.start()` is `async`, so `AppDelegate` runs it in a `Task`.

## Enabling and disabling modules

A module is active while it is enabled and its requirements are met: the database could be opened (for `.database`), and every required module is active, transitively. Only active modules are started, get their hotkeys registered, appear in the palette and the status menu, and are found by `context.api(_:)`.

The switch is stored as `module.<id>.enabled` (`ModuleHost.enabledKey`). While it was never set, `legacyEnabledKey` decides, then `enabledByDefault`.

`ModuleHost.setEnabled(_:_:)` stores the switch, recomputes the active set at once and returns a task that reconciles after the previous switch has taken effect:

- Running modules that are no longer active stop, in reverse list order, so a module stops before the ones it depends on. Their hotkeys are disabled.
- Active modules that are not running start, in list order. Their hotkeys are registered the first time, and enabled again after that.
- Handlers added with `onChange(_:)` run. The panel uses one to rebuild its routes, which closes the palette if the set of triggers changed.

No relaunch is needed. Quick switches coalesce: off and on again before the first took effect does nothing. A switch before `start()` only decides what starts.

`canEnable(_:)` is false for a module that requires the database when there is none: Settings shows its switch off and greyed. `unavailableReason(_:)` gives the text for an unmet requirement ("Needs the database", "Needs Quick Actions to be on").

The rule behind all of it: a module that is switched off does no work. No event tap, no watcher, no timer, no hotkey, no palette trigger. Its data stays in the database and its files stay on disk.

## The context

`ModuleContext` is what a module may use from the host. It is handed to `init`, so a module never reaches for `AppDelegate`.

| Member | What it is |
| --- | --- |
| `id` | The module's `ModuleID`. |
| `database` | `AppDatabase?`: nil if it could not be opened. |
| `defaults` | `ModuleDefaults`: UserDefaults, keys `<id>.<name>` or legacy keys (see "Stored values"). |
| `secrets` | `ModuleSecrets`: the Keychain, accounts `<id>.<name>` or legacy accounts (see "Secrets"). |
| `accessibility` | `AccessibilityPermission`: whether the permission is granted. |
| `palette` | `any PaletteHost`: open, close, overlays, deliver. Only from `start()` on: the panel is created after the modules, and a precondition says so. |
| `pasting` | `PasteService`: pasteboard writes and ⌘V (see "Pasting"). |
| `pasteboard` | `PasteboardActivity`: "Cortex is borrowing the pasteboard". |
| `notifier` | `Notifier`: user notifications. |
| `log` | A `Logger` with `Log.logger("<id>")` as its category. |
| `api(_:)` | Another module's API, or nil while that module is off or unavailable (see "Modules talking to each other"). |
| `apis(_:)` | Every active module that provides a type, in list order. |
| `whileWanted(_:start:stop:)` | Runs `start` while `wanted` returns a value (or `true`), calls `stop` when it does not, follows every change of the observable settings `wanted` reads, and retries when Accessibility is granted. Returns a `ModuleTask`. |
| `requestAccessibility()` | Opens onboarding at the Accessibility step. |

`whileWanted` is how an event tap is tied to a setting: Scrolling's tap and the snippet keyword tap both use it. `start` is called again on every change while the value is wanted, so it must accept being called while running. Cancel the returned `ModuleTask` in `stop()`.

`ModuleServices` is the bundle `AppDelegate` builds once (database, defaults, secrets store, accessibility, pasting, pasteboard activity, notifier, `palette`, `requestAccessibility`) and hands to `ModuleHost`. Tests build their own.

## The palette contract

The palette is one panel with a search field, a pane and a key hints bar. Any number of modules put a scope into it.

**The host owns** the panel window and its placement, showing and hiding, the search field and its focus, trigger resolution, the `\` escape, the key hints bar, key dispatch, Esc, closing on screen lock and sleep, drops onto the palette, and the theme (classic or glass).

**A module owns, through its scope,** what the query means, its results and selection, its view, what ⏎ and its relatives do, and its extra keys and their hints.

`PaletteModel` is a router. It holds the query, the active module, the overlay and the hints, and sends keys to the active scope or the overlay. Each module with a trigger and a scope becomes a `PaletteRoute` (ID, trigger, placeholder, scope). `ModuleHost.paletteRoutes` lists the active ones in manifest order, each followed by its subscopes.

When the palette hides, the host calls `clear()` on every scope that was searched since it was shown. The same happens when the screen locks, the Mac sleeps, the displays sleep or the session resigns. No loaded content stays in memory while the palette is hidden.

When the default module (Clipboard) is off or unavailable, an empty query shows `PaletteLanding`, a small host view that lists the enabled triggers, so the palette still leads to snippets, emoji and the rest. With no module in the palette at all it says so.

## Trigger resolution

`PaletteRouting.resolve(_:in:)` is a pure function. In order:

1. A query that starts with `\` goes to the default module with the backslash removed: `\;sig` searches the clipboard history for `;sig`.
2. Otherwise the active module with the longest matching `prefix` wins and gets the query without it. `::` beats `:`.
3. Otherwise the default module gets the whole query.

If the default module is off and no trigger matches, there is no route and the landing view shows.

The placeholder is built by `PaletteRouting.placeholder(for:)` from the active routes in order, for example "Search clipboard · ;snippets · +reading · ?notes · !todos · >actions · $cmd · :emoji · =calc · ::symbols". Each module's `placeholder` is a one-word name, short enough that the whole line fits; the field shows it in a smaller font than the query. A route with no `placeholder` is left out.

On every edit that changes the route, the host calls `didLeave()` on the old scope, then `search(_:)` on the new one with the text after the trigger. A scope sees `search` on every edit while it is active, and once when it becomes active.

## The scope protocol

`PaletteScope` has no associated types, so the host keeps `any PaletteScope`. Each module keeps its item types, generics and state inside its own scope.

```swift
@MainActor
protocol PaletteScope: AnyObject {
    func search(_ text: String)                  // the query without the trigger
    func didLeave()                              // default: nothing
    func clear()

    var body: AnyView { get }
    var navigation: PaletteNavigation { get }    // default: .list
    func move(_ step: PaletteStep)

    func activate(_ activation: PaletteActivation, target: PaletteTarget) -> Bool
    var activationHints: [PaletteHint] { get }

    var keys: [PaletteKey] { get }               // default: []
    func modifiersChanged(_ flags: NSEvent.ModifierFlags)   // default: nothing
    func cancel() -> Bool                        // default: false
}
```

- `search(_:)` gets the query without the trigger (or without the escaping backslash).
- `didLeave()`: the user switched to another scope. Loaded content may stay, because the scope can come back before the palette hides. This is how a clip handed to `>` with ⌘K survives leaving `>` and coming back.
- `clear()`: the palette was hidden. Drop loaded content.
- `body` fills the pane between the search field and the hints bar. Return a view that holds the scope, so it observes it, built from the shared layouts (see "Shared palette components").
- `navigation` is `.list` (↑↓ move, ←→ stay with the search field) or `.grid(columns:)` (←→ move too, and the hints bar adds "←→↑↓ Move"). `move(_:)` gets a `PaletteStep`: `.vertical(±1)` or `.sideways(±1)`.
- `activate(_:target:)` handles ⏎, ⇧⏎, ⌥⏎ and ⌥⇧⏎ on the selection (`PaletteActivation`: `.primary`, `.shift`, `.option`, `.optionShift`), ⌘1–9 and ⌘⇧1–9 on a position (`PaletteTarget.position(n)`, 0-based), and a double click. It returns `false` if there is nothing to do; the key then goes to the search field. By convention ⌥ means copy only, never paste (`PaletteActivation.isCopy`).
- `activationHints` are the hints for the activations the scope supports, in hint order. `PaletteHint` has helpers: `PaletteHint(.primary, "Paste")`, `.positions("Run")`, `.move`, `.escape("Back")`.
- `keys` are everything else (⌘P, ⌘⌫, ⌘E, ⌘K, ⇥). They are matched before the search field sees the key. A `PaletteKey` has a `KeyCombo`, an optional hint (nil: works but is not shown) and a `perform` closure. `perform` returning `false` lets the key through to the field after all. A nil `perform` is a hint only (⌥ Reveal, or ⇥ that a form's fields handle themselves).
- `modifiersChanged(_:)` sees ⌥ pressed and released (Clipboard reveals sensitive clips while ⌥ is held).
- `cancel()` is called on Esc. Return `true` if the scope used it to step back inside itself (Quick Actions closes its options field), `false` to let the palette close.

Key dispatch: `PaletteKeyMap` does the key-code work and turns an event into `.move`, `.activate` or `.combo`. The digit row is read by key code, because with ⇧ held the character for "2" is "@" or `"` depending on the layout. Arrow keys count only with no real modifiers. ⌘⏎ is offered to `keys` first; if no key takes it, it activates like ⏎. Esc is handled by the panel: an overlay first, then `cancel()`, then the palette closes.

The hints bar shows `activationHints`, then the hints of `keys`, then the grid hint if the scope is a grid. An overlay replaces them with its own and adds "esc Back" or "esc Close".

## Overlays

An overlay takes over the pane for a moment: the snippet fill-in form, a command's form. The search field is disabled, the overlay has its own keys, and Esc leaves it first. Any scope presents one with `PaletteHost.present(_:)`.

```swift
struct PaletteOverlay {
    let body: AnyView
    let activationHints: [PaletteHint]
    var currentHints: (@MainActor () -> [PaletteHint])?  // used instead of activationHints when set: hints that follow what the overlay shows
    var keys: [PaletteKey] = []
    let activate: @MainActor (PaletteActivation) -> Void
    let escape: Escape                           // .dismiss or .closePalette
    var move: (@MainActor (PaletteStep) -> Bool)?        // arrow keys, before the focused field
    var dropFiles: (@MainActor ([URL]) -> Bool)?         // files dropped while the overlay shows
    var dismissed: (@MainActor () -> Void)?              // the overlay is gone (Esc, or the model removed it)
}
```

- `escape`: `.dismiss` goes back to the scope; `.closePalette` closes the palette (the overlay was opened just for itself, as by snippet keyword expansion).
- `move` lets the overlay take the arrow keys before the focused field, for a field with a list of suggestions (`SuggestingTextField` keeps the state). Return `false` to let the field have them.
- `dropFiles` lets a path field take files dropped onto the palette. Returning `false` hands the drop to the modules as usual.
- `currentHints` lets the hints change while the overlay shows (a command's form says what ⏎ will do). `dismissed` tells the scope the overlay is gone: Esc went back to it, or the model took the overlay away (another module opened, the palette was shown again or hidden), once either way.
- An overlay is dropped when the palette is shown again and when it hides.

## Opening a scope from elsewhere

The host only knows module IDs. A module that should be opened with input does it through its own API, so no untyped payload passes through the host:

```swift
// ActionsModule, implementing ActionsAPI
func showActions(on input: ResolvedActionInput?) {
    if let input { scope.handIn(input) }         // before opening: `>` would read the clipboard
    context.palette.open(Self.manifest.id)       // shows the panel and sets the query to ">"
}
```

`PaletteHost.open(_:)` shows the panel with the query set to the module's trigger. If that scope is already showing, it searches again. `open(_:searching:)` adds text after the trigger (the calculator's ⇥ puts a result back into the field). `toggle(_:)` is `open`, or `close` if that scope is already showing: this is what the quick actions hotkey does. Subscope IDs work the same way: `open("todos")`.

Files dropped onto the palette or the menu bar icon go through `acceptsDroppedFiles(_:)`: the first active module that returns `true` gets them (`ModuleHost.dropFiles(_:)`). Quick Actions takes them and opens `>` on them.

## Settings and options

The settings window is a sidebar: **General** (host), the pages active modules add with `settingsPanes` (Knowledge's **Projects**), then one page per module in `order`. Inactive modules are greyed in the sidebar; their panes are not listed.

- **General** has the palette shortcut, the palette style, position reset, launch at login, permissions (Accessibility and Finder automation, only those an active module asks for), storage (database path, cipher version, applied migrations), and any manifest problems.
- **A module's page** is generated by `ModuleSettingsPage`: a header with symbol, name, summary, trigger line and an **Enabled** switch; then a Shortcuts section with the module's `hotkeys` as recorders (the `help` text as caption); then its `options`; then its `settingsView`. A module that cannot run shows why, with the switch off and disabled. While a module is not active everything below the header is greyed but stays visible, so it can be set before switching the module on.

Most settings are simple and declared as `ModuleOption`s. Options bind to the module's own `@Observable` settings class, so persistence stays there.

```swift
struct ModuleOption: Identifiable {
    enum Kind {
        case toggle(Binding<Bool>)
        case integer(Binding<Int>, range: ClosedRange<Int>, unit: String?)
        case choice(Binding<String>, [(value: String, title: String)])
        case text(Binding<String>, prompt: String?)
        case secret(ModuleSecretKey)
        case folder(URL)                         // the path, and a button that opens the folder
        case button(String, role: ButtonRole?, action: () -> Void)
    }
    let id: String                               // unique within the module
    let title: String
    let help: String?                            // a caption below
    let kind: Kind
    var isEnabled: () -> Bool                    // false greys it out
}
```

Anything with a flow of its own stays a custom view in `settingsView`: imports, ignored apps, sync set-up, the action file list. It returns `Section`s, which the page's grouped `Form` lays out. Option IDs are unique within a module; `ModuleListTests` checks this.

Sync's "What to sync" section is generated from `SyncContribution`s (see "Modules talking to each other"): one switch per contribution of an active module, then that contribution's options.

## Stored values

All preferences are in `UserDefaults`, reached through `context.defaults`, a `ModuleDefaults`.

- The enabled flag is `module.<id>.enabled`.
- New keys are stored as `<id>.<name>`: `defaults.set(4, for: "precision")` writes `calculator.precision` in the Calculator module.
- Keys that existed before modules keep their names. `.legacy("retentionDays")` is stored under exactly that name. A settings class may also read its own keys from `defaults.store`, the underlying `UserDefaults`. "Stored keys and names that must not change" lists them all.
- `bool` and `integer` return `nil` while unset, unlike `UserDefaults.bool(forKey:)`, so a default can be told from a stored `false`.
- Scoped keys are a hyphenated module ID plus a name, so `reading-list.listRead` and `color-picker.format` are real keys.

Larger values (usage counts, remembered options) are JSON in a `Data` value under one key.

## Secrets

Secrets are declared like options and stored in the Keychain through `KeychainStore.app`, never in UserDefaults or the database.

```swift
struct ModuleSecretKey: Hashable, Sendable {
    let account: String      // "<id>.<name>", or a legacy account
    let title: String        // "API key"
}
```

`context.secrets.key("token", title: "API token")` makes the account `<id>.token`. A `.secret` option shows a secure field whose prompt says "Saved" or "Not set", with Save and Remove buttons. The value is never shown back; a refusal by the Keychain is shown in red. A module reads the value with `context.secrets.string(for:)`. `isSet`, `set` and `remove` are there for custom views.

Sync's token and sync key keep their legacy accounts and a set-up flow of their own, since setting them up is more than typing a value. They use `context.secrets.store` directly. The database key is also in the Keychain; see the list below.

Keychain items use the service name `dev.jonaszell.cortex`. `KeychainStore.app` also reads items stored under an older service name from before the app was renamed, and moves them over on first read.

## Hotkeys

```swift
struct ModuleHotkey {
    let name: KeyboardShortcuts.Name    // declared in the module's Module.swift file
    let title: String                   // "Open quick actions:"
    let help: String?
    let action: @MainActor () -> Void
}
```

A module returns its hotkeys from `hotkeys`. The host registers them with `KeyboardShortcuts` the first time the module starts, wraps the action so a press only reaches the module while it is active, and switches them with `KeyboardShortcuts.disable` and `enable` after that (the package cannot remove a single handler). Settings shows a recorder for each on the module's page.

The `KeyboardShortcuts.Name` is stored (under its string), so it never changes. It is declared in the module's `<Name>Module.swift` with an optional default. `togglePalette` is the host's own and is registered by `AppDelegate`; its recorder is on the General page.

## What the host provides

- `PaletteHost`: what a scope or module can do with the panel.
- Pasting: `PasteService`, `PasteboardActivity` and `Paster`.
- Shared palette components: the lists, grids, rows and layouts scopes are built from.
- The status item: the menu and icon, built from the modules' contributions.
- Other host services: notifications, directory watching, permissions, onboarding.

## PaletteHost

`PanelController` implements `PaletteHost`. A scope gets it through a closure (`palette: () -> any PaletteHost`) rather than as a value, because `context.palette` only exists from `start()` on. Tests pass a `FakePaletteHost` (`CortexTests/Host/`).

```swift
@MainActor
protocol PaletteHost: AnyObject {
    var isVisible: Bool { get }
    var activeModule: ModuleID? { get }              // the module whose scope is showing
    var previousApp: NSRunningApplication? { get }   // frontmost when the palette opened; pastes go there

    func show()                                      // empty query
    func open(_ id: ModuleID)
    func open(_ id: ModuleID, searching text: String)
    func toggle(_ id: ModuleID)
    func close()
    func present(_ overlay: PaletteOverlay)
    func focusSearch()                               // back to the field after an option field had focus

    func closeAndDeliver(_ action: PasteAction, _ deliver: @escaping @MainActor (NSRunningApplication?) async -> Bool)
    func closeAndDeliver(_ content: PasteContent, _ action: PasteAction, recording: Paster.Recording,
                         restoringPasteboard: Bool, after: (@MainActor (Bool) -> Void)?)

    func onShow(_ handler: @escaping () -> Void)     // called on every show (Sync checks whether it is stale)
}
```

`closeAndDeliver` is the one way out of the palette with a result. It closes the panel, then pastes or copies into `previousApp`, and asks for Accessibility (through onboarding) if a paste failed for want of it. It has two forms:

- With ready `PasteContent`: text, a PNG image or a clip. `recording` says whether the clipboard history keeps what Cortex writes (`.skip`, the default, or `.record(sensitive:)` for an action's result). `restoringPasteboard` puts the previous clipboard back afterwards; `after` learns whether the content was delivered.
- With a closure that delivers into the target app itself, for content that has to be computed once the palette is gone: a clip's detail is loaded, a snippet rendered, an action run. The closure returns `false` if a paste was wanted but did not happen.

## Pasting

`Host/Pasting/` is the one path for everything Cortex puts on the pasteboard or pastes. Snippets, Emoji, Symbols, Clipboard and the delivery of quick action results all use it, so none of them needs the Clipboard module.

- `PasteContent`: `.text(String)`, `.image(Data)` (PNG), `.clip(ClipDetail)` (a history entry with all its representations).
- `PasteAction`: `.paste(Paster.Mode)` (`.rich` or `.plainText`) or `.copyOnly`.
- `PasteService.deliver(...)` writes the content and, for `.paste`, posts ⌘V into the target app. It returns `false` when a paste was wanted but did not happen (no Accessibility permission, or the target did not come back to the front); the content is then only copied.
- With `restoringPasteboard`, text and images only borrow the pasteboard: the previous contents are saved, the content is lent, and the old contents are put back once the target has read it (not after a fixed delay, so a slow app does not paste the restored clipboard). Borrowed content is never recorded in the history. If the target never reads it and the saved clipboard was sensitive, it is not put back. Emoji, symbols, keyword expansion and selection replacement use this, so they leave neither a trace in the history nor a changed clipboard.
- `Paster` writes to the pasteboard and posts the keys. It marks what Cortex writes with its own pasteboard type (`dev.jonaszell.cortex.own`), so the clipboard monitor does not record Cortex's own pastes as new copies, and tags the events it posts so the keyword expander's tap can tell them from typing. A sensitive clip is marked concealed, stays on this Mac and is cleared after a short time.
- `PasteboardActivity` is "Cortex is borrowing the pasteboard". `SelectionReader` calls `context.pasteboard.borrow { … }` to copy the selected text in another app, and the Clipboard module's `PasteboardMonitor` skips changes while it is borrowed. That is how Quick Actions use the pasteboard without naming the Clipboard module.
- `PasteboardReader` turns a pasteboard into a `ClipSnapshot` (the representations worth keeping, the plain text, whether it is sensitive, the source app). The Clipboard module records it; Quick Actions take it as input.

## Shared palette components

`Host/Components/` holds what scopes build their `body` from. Modules use these and never touch the theme directly.

| Component | What it does |
| --- | --- |
| `ResultList<Item, ID>` | `@Observable` state of a list: `items`, `selectedID`, `hasLoaded`. `load(query:_:)` runs an async search and drops the results of a search that was cancelled; `replace(with:query:)` takes results computed synchronously. Loading the same query again keeps the selection while the item still exists and moves it to the neighbour of an item that went away; a new query selects the first result. `move(by:)`, `item(at:)`, `select(_:)`, a `didSelect` hook. |
| `PaletteList` | Draws a `ResultList`: scrolls to the selection, click selects, double click activates, the first nine rows get their ⌘1–9 number, empty and loading states. Rows are drawn by the caller. |
| `PaletteRow` | A row: symbol, title, subtitle, trailing badge (a snippet's keyword), shortcut number, selected colours. |
| `ResultGrid<Item>` | The state of a grid in titled sections, with arrow-key movement. No UI, so it can be tested. |
| `PaletteGrid` | Draws a `ResultGrid`: the selection stays in view, cells are drawn by the caller. |
| `PaletteSplitLayout` | A 440 pt list on the left, a divider in the classic style, a preview card on the right. |
| `PaletteGridLayout` | A grid over the full width with a detail strip below it. |
| `DetailStrip` | The selected item large, with title, caption and a trailing accessory (the skin tone chip). |
| `PaletteEmptyState` | Title, symbol and description for an empty list or grid. |
| `TextPreview` | Monospaced, selectable, scrollable text, cut to the first screens of very long text. |
| `ActionOptionControl` | The control for one action option: a segmented choice, a number field or a short text field. |
| `SuggestingTextField` | A text field with a list of suggestions; `SuggestingFieldState` holds what was typed and which suggestion is highlighted. |

A list is `ResultList` with `PaletteList` and `PaletteRow` inside a `PaletteSplitLayout` with a preview (Snippets). A grid is `ResultGrid` with `PaletteGrid` inside a `PaletteGridLayout` with a `DetailStrip` (Emoji, SF Symbols).

## Status item

`StatusItemController` builds the menu from the host's fixed items and the active modules' contributions:

1. Open Cortex, Settings…
2. For each active module with items, in `order`, a separator and its `statusMenuItems()`.
3. Grant Accessibility Access… (hidden once granted, or when no active module needs it), Quit Cortex.

```swift
struct StatusMenuItem {
    let title: String
    var state: NSControl.StateValue = .off     // a checkmark
    var isEnabled = true
    var image: String?                         // SF Symbol
    var shortcut: KeyboardShortcuts.Name?
    var toolTip: String?
    let action: (@MainActor () -> Void)?       // nil: a line to read ("Synced 3 min ago")
}

struct StatusIcon {
    let image: NSImage
    let accessibilityLabel: String
    let priority: Int
}
```

`StatusMenuItem.line(_:)` makes a line to read. The menu does not auto-enable its items, so a module's `isEnabled: false` holds.

The items are read inside `withObservationTracking` whenever the menu is about to open, and again while it is open when anything observable they read changes, so a checkmark, the sync line or a running job's progress is always current. `StatusMenuSection` updates items in place where the shape allows, so the highlighted item stays highlighted while a job reports progress.

The menu bar icon is Cortex's own unless an active module asks for another through `statusIcon`. The highest `priority` wins, the earlier module in `order` on a tie. The progress ring of running quick actions has priority 10; Clipboard's pause icon has priority 0.

Files dragged onto the icon go to `ModuleHost.dropFiles(_:)`, like drops on the palette. The icon highlights for any file drag; with Quick Actions off the drop is refused.

## Other host services

- `Notifier` posts user notifications for any module. A notification that lists files reveals them in Finder when clicked. It does nothing in the unit tests' host.
- `DirectoryWatcher` (FSEvents) calls back on the main thread when anything in a folder changes, including files edited in place. Quick Actions use it for the action files, Sync for its watched folders.
- `AccessibilityPermission` tracks the Accessibility permission and polls for the grant after `startPolling()`. `ScreenRecordingPermission` does the same job for Screen Recording (Text Recognition). Finder automation is asked for by macOS itself the first time Cortex reads the Finder selection.
- Onboarding opens at launch only while an active module asks for Accessibility, and when a paste fails for want of it.
- `Beep` plays the system sound for a key that does nothing; it is silent in the tests.
- `UsageRanking` (CortexCore) counts how often items are picked, to rank them; `UsageRanking+Defaults` stores the counts as JSON in UserDefaults.
- `NSApp.servicesProvider` and the App Intents dependency belong to Quick Actions. The provider is set in `start()` and removed in `stop()`. App Intents cannot be unregistered, so the dependency is added once per process in `init`, and the intents fail with "Quick Actions are switched off in Cortex Settings" while the module is off.

## Modules talking to each other

Modules do not reach into each other's internals. A module that offers something to others declares it in one file, `<Name>API.swift`: a protocol plus the value types it uses. The module conforms to the protocol, and others look it up through the context:

```swift
// Modules/Snippets/SnippetsAPI.swift
@MainActor protocol SnippetsAPI: AnyObject {
    func editSnippet(_ request: SnippetEditRequest)
}

// Modules/Clipboard/ClipboardScope.swift, in the scope's keys
guard let snippets = context.api(SnippetsAPI.self) else { return true }
snippets.editSnippet(.new(body: text))
```

`context.api(_:)` returns nil while the providing module is off or unavailable. Code that depends on it hides what needs it (a hint, a menu item) instead of failing. Clipboard's "Save as snippet" and "Actions" hints show only while Snippets and Quick Actions are active.

**The rule: a module may name another module's types only if they are declared in that module's `<Name>API.swift`.**

`scripts/check-modules.sh`, run first by `make test-app`, enforces it:

1. Every folder in `Cortex/Modules/` has its `<Name>Module.swift`.
2. `Host/` and `App/` name no type declared under `Modules/` (`App/ModuleList.swift` is the exception).
3. A module's files name no type declared in another module's files, except the ones in that module's `<Name>API.swift`.

Types are the top-level, non-private declarations (`class`, `struct`, `enum`, `protocol`, `actor`, `typealias`); comments are ignored. The check is textual: it looks for the type name as a whole word. It lists each crossing and exits non-zero.

The APIs in use:

| API | Provided by | Used by | For |
| --- | --- | --- | --- |
| `SnippetsAPI.editSnippet(_:)` | Snippets | Clipboard, Quick Actions | Opening the snippet editor: ⌘E and ⌘N on clips, "Create Snippet" and `.snippet` results. `SnippetEditRequest` is declared in the same file. |
| `ActionsAPI` | Quick Actions | Clipboard, Commands | Clipboard's ⌘K opens `>` on a clip (`showActions(on:)`). Commands runs its commands through `previewAsync`, `run`, `options`, `setOptions`, `usage` and the user's command files. `ResolvedActionInput`, `ActionPreview` and `ActionDelivery` are declared in the same file. |
| `ClipboardAPI` | Clipboard | Snippets, Commands, Text Recognition | `recentTexts(upTo:)` for `{clipboard offset=n}` (offset 0 reads the pasteboard directly and needs no module); `recentTexts(limit:)` for the suggestions of a command's form; `detectsSensitiveText`, so a captured secret is flagged as the history flags a copied one. |
| `AIAPI` | AI | Knowledge | `vendor`, `textModel` and `send`: a request with the user's API key, counted in AI's usage. |
| `SyncContributing` | Clipboard, Snippets, Reading List, Knowledge, Quick Actions | Sync | The collections each module syncs (below). |
| `ActionContributing` | AI, Text Recognition, Knowledge | Quick Actions | Their quick actions in `>` and Shortcuts, asked for on every listing. |
| `CommandContributing` | AI, Color Picker, Text Recognition, Knowledge | Commands | Their `$` commands, asked for on every listing. |

`ActionContributing` and `CommandContributing` are asked for on every listing, so the actions and commands of a module that is switched off disappear, and the module that lists them names no other module. IDs and triggers of contributed actions must not clash with the built-ins'.

**Sync** collects contributions instead of knowing the other modules:

```swift
@MainActor protocol SyncContributing: AnyObject {
    var syncContributions: [SyncContribution] { get }
}

struct SyncContribution {
    let collection: SyncCollection           // the wire format's collection (CortexCore)
    let title: String                        // "Clipboard history", for the switch in Settings → Sync
    let toggleKey: String                    // where that switch is stored ("syncClips"); on until switched off
    var options: [ModuleOption]              // sensitive clips, size cap
    let makeHandler: @MainActor () -> any SyncEntityHandler
    var needsRestart: (_ old: SyncFilterValues, _ new: SyncFilterValues) -> Bool
    var watchedFolder: URL?                  // for records without pending rows (action files)
    var waitUntilReady: @MainActor () async -> Void
    var didApplyRemoteChanges: @MainActor () -> Void
}
```

Sync asks `context.apis(SyncContributing.self)` whenever it needs the list, so a switched-off module's records are neither sent nor applied. `needsRestart` says whether changed option values let in records the old ones kept back (sensitive clips allowed, a larger size cap): the collection's rows are then offered again. After a cycle that wrote remote data, every active contribution's `didApplyRemoteChanges` runs, so the palette and the keyword table reload.

A new kind of synced record also needs a `SyncCollection` case, a payload and change tracking (`SyncSchema`) in CortexCore. See [SYNC.md](SYNC.md).

## Actions and commands

Quick actions and commands are the same thing underneath and two modules on top.

**`QuickAction`** (CortexCore, `Actions/QuickAction.swift`) is one thing the user can run on an input: `id`, `title`, `symbol`, `keywords`, `isInstant`, `options`, `isRemote`, `hasSensitiveResult`, `accepts(_:)`, `matches(_:)`, `plan(for:)` and `run(_:context:)`. `ActionInput` is `.none`, `.text`, `.image` or `.files`. `ActionOutput` says what the app does with the result (paste it, copy it, notify, reveal in Finder, open the snippet editor, ask for confirmation). Running, previews, confirmations, jobs, usage counts and delivery are shared. [ADDING_ACTIONS.md](ADDING_ACTIONS.md) covers writing one.

**`Command`** (CortexCore, `Commands/Command.swift`) is what the user types after `$`: an `id`, a `name` (the word after `$`), a `title`, a `summary`, an `argument` (a `CommandArgument`: text, prompt, number, path or choice, with optional suggestions), `options`, and `resolve(_:)`, which returns a `CommandOutcome` (a value to paste, something to open, a question to ask, a background job or a hand-over). It is not a `QuickAction`: `CommandAction` adapts a command and its outcome to one, so running, confirmations, jobs, usage counts and delivery stay shared. Its `accepts` is derived from the argument, and its `matches` is false by default, so `>` never offers it.

The two modules differ in where the input comes from:

| | `>` Quick Actions (`actions`) | `$` Commands (`commands`) |
| --- | --- | --- |
| Input | What the palette finds when it opens (the Finder selection over Finder, otherwise the clipboard), or what is handed in: ⌘K on a clip, files dropped on the palette or the icon, the selected text (the act-on-selection hotkey), Services. | What is typed after the command's name, or filled into its form. Never read from context. |
| Typed text | Only searches titles and keywords. | A word that is exactly a command's name makes the rest its argument: `$port 3000`. Otherwise the whole text searches. |
| Empty query | The actions that accept the current input, by usage. | Every command, by usage. |
| ⇥ | Moves to the selected action's options. | Opens the command's form (an overlay) with the typed argument filled in. |
| Preview | Instant actions preview at once; the rest show their plan. | The typed argument is previewed after a 150 ms pause, so `$port 3000` is looked up once rather than for 3, 30, 300 and 3000. |

Guarantees the user can rely on: an action always works on the input its pane shows, and nothing typed after `>` is its input; a command never runs on anything that was not typed or chosen in its form (context appears only as a suggestion, taken with a keystroke).

Commands requires Quick Actions and runs everything through `ActionsAPI`, so previews, confirmations, jobs, usage counts and delivery are the same. A command can opt in to `>` with `matches` for input unmistakably meant for it (Kill Process on Port is offered for a copied port number); it then runs on that input like any action.

Parsing is in CortexCore as pure values with their own tests: `CommandQuery` for `$`, and `ActionCatalog.list(_:query:for:)` with an `ActionListing` for `>`, which lists only the actions whose `matches` and `accepts` fit the input. Typed input is coerced by `ActionInput.typed(_:)`: one or more existing paths (absolute or starting with `~/`, shell-style quotes) become `.files`, anything else `.text`. Typed input is never sensitive.

**User files.** One folder, `~/.config/cortex/actions/` (or `$XDG_CONFIG_HOME/cortex/actions`), one TOML format, documented in the README under "Quick actions" and "`$` commands". A file with `accepts` and no `trigger` is a `>` action. A file with a `trigger` and no `accepts` is a `$` command. A file with both is listed in both. The parser reports problems (unknown keys, a duplicate or reserved trigger, a placeholder the accepted inputs cannot fill) in Settings → Quick Actions. A user file's action ID is `user.<file name without extension>`, so renaming a file resets its usage and remembered options.

**Settings.** Quick Actions has one page: its two hotkeys, the folder, the user's files, problems, and the tools the built-in file actions need. Commands has a page that lists the commands with their triggers.

## Stored keys and names that must not change

Users, other Macs and other code depend on these. Change one and a setting, a shortcut, a secret or a synced record is lost. A new setting adds a key; it never renames one. When you add a module, add its keys here.

There is no single test that lists them. `ModuleListTests` checks the manifests and option IDs, and each settings class has tests for its own keys.

### UserDefaults keys

| Owner | Keys |
| --- | --- |
| Host | `module.<id>.enabled` for every module; `paletteStyle`; `palettePosition` |
| Clipboard | `retentionDays`, `retentionMaxItems`, `sensitiveRetentionDays`, `indexSensitiveText`, `detectSensitiveText`, `recognizeImageText`, `pastePlainByDefault`, `ignoredBundleIDs`, `isRecordingPaused`, and the two sync filters `syncSensitiveClips` and `syncMaxClipMB` |
| Snippets | `snippetKeywordExpansion` |
| Reading List | `reading-list.listRead`, `reading-list.deleteReadAfterDays` |
| Knowledge | `knowledge.keepHistory`, `knowledge.linkSkills`, `knowledge.folder` |
| Quick Actions | `quickActionUsage`, `quickActionOptions` |
| AI | `ai.vendor`, `ai.openai.textModel`, `ai.openai.imageModel`, `ai.usage` |
| Emoji | `emojiSkinTone`, `emojiUsage` |
| SF Symbols | `symbolUsage` |
| Calculator | `calculator.digits`, `calculator.decimalSeparator` (raw values of `CalculatorDecimalSeparator`), `calculator.keepRecents`, `calculator.recents` |
| Color Picker | `color-picker.format` (raw values of `ColorFormat`), `color-picker.uppercaseHex`, `color-picker.notify` |
| Text Recognition | `text-recognition.joinLines`, `text-recognition.notify`, `text-recognition.language` |
| Scrolling | `scrollReversal` (read as the module's switch until `module.scrolling.enabled` is set), `scrollReverseVertical`, `scrollReverseHorizontal`, `scrollReverseTrackpad`, `scrollReverseMouse`, `scrollWheelStepSize` |
| Sync | `syncEnabled` (read as the module's switch until `module.sync.enabled` is set), `syncServerURL`, and the per-collection switches `syncClips`, `syncSnippets`, `syncReadingList`, `syncKnowledge`, `syncActions` |

Commands has no stored settings of its own: its usage and remembered options are Quick Actions', under the command IDs.

### Keychain

Service `dev.jonaszell.cortex`, accounts:

- `database-key`: the key of the encrypted database. Lose it and the database is unreadable; the app offers to move the database aside and never deletes it.
- `sync-key` and `sync-token`: the sync key and the server token.
- `ai.openai-api-key`: the OpenAI API key. The account is `<id>.<vendor>-api-key`, so another vendor gets its own.

### Keyboard shortcut names

`KeyboardShortcuts` stores recorded shortcuts under these names.

| Name | Owner | Default |
| --- | --- | --- |
| `togglePalette` | Host | ⌘⇧V |
| `quickActions` | Quick Actions | ⌃⌥⌘A |
| `actOnSelection` | Quick Actions | ⌃⌥⌘S |
| `pickColor` | Color Picker | ⌃⌥⌘C |
| `captureText` | Text Recognition | ⌃⌥⌘T |
| `knowledgeCapture` | Knowledge | none |

### Module IDs and routes

`clipboard`, `snippets`, `reading-list`, `knowledge`, `actions`, `commands`, `ai`, `emoji`, `calculator`, `symbols`, `color-picker`, `text-recognition`, `scrolling`, `sync`, and the subscope ID `todos`. Everything stored per module is scoped by them.

### Sync

The collections `clip`, `snippet`, `action`, `reading`, `knowledge` and `meta`, and their payloads (see [SYNC.md](SYNC.md)). In the database's `metadata` table: `knowledgeSyncFolder` and the `sync…` keys (`syncDeviceID`, `syncCursor`, `syncEpoch`, `syncLastSuccess`, `syncConfirmedKey`, `syncUnopened`, `syncCollections`).

### Action and option IDs

Usage counts and remembered options are stored under action and option IDs. Do not rename them.

- Built-in actions are prefixed by what they are: `text.`, `generate.`, `file.`, `snippet.` (for example `text.json.pretty`, `generate.uuid`, `file.image.webp`, `snippet.create`), and `image.recognize-text`.
- Commands start with `command.`: `command.kill`, `command.port`, `command.diskspace`, `command.memuse`, `command.cpuuse`, `command.gpuuse`, `command.open`, `command.code`, `command.term`, `command.clip`, `command.sound`, `command.uuid`, `command.token`, `command.color` (Color Picker) and `command.ocr` (Text Recognition).
- AI actions and commands are `ai.<kind>`: `ai.proofread`, `ai.summarize`, `ai.ask`, `ai.image`.
- User files are `user.<file name without extension>`.

### Database migrations

Names and order, because GRDB applies them by name and they have shipped: `v1_metadata`, `v2_clips`, `v3_snippets`, `v4_sync`, `v5_sync_synced`, `v6_sync_capped`, `v7_sync_authenticated`, `v8_reading-list_items`, `v9_clipboard_recognized-text`. A module that needs a table adds a migration to `AppDatabase` after the existing ones, named `v<n>_<moduleID>_<what>`. Tables exist whether the module is on or not; switching it off never deletes data.

### Triggers and keys

The triggers `;` `+` `?` `!` `>` `$` `:` `::` `=` and the `\` escape. ⌘1–9 by key code. Esc leaving an overlay before closing the palette. ⌥ for copy only and for Clipboard's reveal. ⇥ for the skin tone in Emoji, for the options in `>` and for the form in `$`.

### User files

Every existing file in `~/.config/cortex/actions/` keeps working the same way, including commands that run only on typed arguments.

### Behaviour

- Loaded content is dropped when the palette hides, the screen locks or the Mac sleeps: the host calls `clear()` on every scope used since the palette opened.
- Picked emoji, symbols, keyword expansions and selection replacements stay out of the clipboard history and put the clipboard back.
- Nothing runs from a module that is switched off: no event tap, watcher, timer or hotkey.
