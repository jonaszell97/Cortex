# Adding a built-in quick action

If a shell command can do it, a TOML file in `~/.config/cortex/actions/` (see the README) needs no code and no rebuild. Build an action into the app when it needs Swift (PDFKit, CoreImage), should be previewed in the palette, or has to make the app do something (open a window).

New source files need no `make project`: the source folders are synced. Built-in actions live in the Quick Actions module: their logic in `CortexCore/Sources/CortexCore/Actions/`, the app side in `Cortex/Modules/Actions/` (the module, `ActionsService`, `ActionsScope`, `Views/`). A feature that is not an action, with its own trigger or settings page, is a module of its own ([ADDING_A_MODULE.md](ADDING_A_MODULE.md)).

## 1. Pick the kind

| Kind | Where | For |
| --- | --- | --- |
| `TextAction` | `CortexCore/.../Actions/TextActions.swift`, add to `TextAction.all` | Fast, pure work on text. Instant: the palette previews the result and ⏎ uses exactly that preview. `accepts: .text` needs non-empty text; `.anything` also runs with no input (generators). |
| `FileAction` | `CortexCore/.../Actions/FileActions.swift`, add to `FileAction.all` (macOS only) | Work on files. Runs as a background job with progress and cancel, writes results next to the sources with `FileStep.produce` (never over a file). Shell tools go through `ProcessRunner`; add tools the user installs to `ActionsService.tools` so Settings → Quick Actions shows whether they were found. |
| Your own `QuickAction` type | Add it to `ActionCatalog.builtIns` | Anything else. The app recognises some kinds by type: only `TextAction`s are previewed (`ActionsService.preview`), and only `FileAction`s and file-taking `UserAction`s are offered in the Shortcuts file intent (`FileActionOptions` in `QuickActionIntents.swift`). Extend those checks if your type should take part. |

An action that sends its input to an online service sets `isRemote` (the AI actions): it is never instant, the palette does not list it for sensitive input, and `ActionsService.run` refuses sensitive input whatever the way in. Actions that belong to another module (with its own settings or API key) are not built-ins: that module offers them through `ActionContributing` (`ActionsAPI.swift`), and they are listed after the built-ins.

## 2. Name it

- `id`: stable forever, since usage counts are stored under it in UserDefaults. Prefix it by what it is: `text.`, `generate.`, `file.`, `snippet.`. `TextActionTests.idsAreUnique` checks for duplicates.
- `title`, `symbol` (an SF Symbol) and `keywords`: search matches every typed word against the title words and keywords.
- Position in its list: with no query and no usage, the palette lists actions in catalog order. `ActionsScopeTests` expects "Format JSON" first for text and exactly the generators for no input, so add new text actions after the existing transforms.

## 3. Options, if it needs settings

An action that needs settings (how long, which side) lists them in `options`: `ActionOption`s with an `id`, a `title`, a `kind` (`.text(maxLength:)`, `.number(range)` or `.choice`) and a `defaultValue`. The palette shows them below the action's preview, previews again on every change, and remembers the values per action in UserDefaults (`ActionsService.setOptions`); Shortcuts runs use the remembered values too. A run gets them in `context.options`; a `TextAction` takes them through the `init` with `options:`, whose transform gets the values as its second argument. "Pad" is the example (`PadOptions` in `TextActions.swift`).

Values are strings as typed, so read them with `ActionOptionValues.integer(_:)` and `character(_:)`, which throw a `QuickActionError` naming the option when a value does not fit: the preview shows it until the user fixes it. Option IDs are stored like action IDs, so do not rename them.

## 4. Pick the output

What `run` returns decides what the app does with it (`ActionsService.deliver`):

| `ActionOutput` | Palette | Shortcuts ("Transform Text" / "Run … on Files") |
| --- | --- | --- |
| `.text`, `.image` | ⏎ pastes it, ⌥⏎ copies it; either way it becomes a clip, sensitive if the input was or the action sets `hasSensitiveResult` (`$token`). A result that took over 5 s, or whose target app lost focus, is only copied, with a notification. | Text is returned; images fail the text intent |
| `.files` | Notification that reveals them in Finder | Returned (results of data-only inputs moved to Downloads) |
| `.done(message)` | Notification with the message | The message is returned |
| `.snippet(body)` | Opens the snippet editor on a new snippet with that body | Same, and the body is returned |
| `.saveCommand(command)` | Asks for a name in an alert (again, with the reason, while it cannot be saved), then delivers `CommandFile.confirmation`, which writes the `$` command file | Not offered (`shortcutActions` leaves out "Save as Command") |
| `.reveal(url)` | Shows it in Finder: a folder opens in a window, anything else is selected in its folder (`$open`). An instant action previews the path | Shown in Finder too; the path is returned (text) or an empty result (files) |
| `.handled` | Nothing: the action delivered its result itself (`$color` starts the eyedropper, which copies the colour). Return it at once, so no progress card shows | An empty result |
| `.confirm(confirmation)` | An alert with its title, message and confirming button (destructive, the default); confirmed, its `perform` runs and that output is delivered like this one would have been. An instant action previews the question. | Not supported (fails) |

Throw `QuickActionError("…")` for failures the user should read: the palette preview shows it in red, a run shows it as a notification.

## 5. When the app has to do something

Core cannot reach AppKit or the app's services, so an action that should, say, open a window returns a value that tells the app what to do. "Create Snippet" is the example:

1. Add a case to `ActionOutput` (`QuickAction.swift`), here `.snippet(String)`.
2. Handle it in every `switch` over the output; the compiler lists them:
   - `ActionsService.deliver` (do it) and `write` (nothing to put on the pasteboard)
   - `ActionPreviewView.result` in `ActionViews.swift` (what the palette shows before ⏎, for instant actions)
   - `TransformTextIntent.perform` and `RunFileActionIntent.perform` in `QuickActionIntents.swift`
3. If it needs a service the app may not have (the snippet editor exists only when the Snippets module is active), give `ActionsService` a closure for it through the other module's API (`context.api(SnippetsAPI.self)`), set it in `ActionsModule.init`, and leave the action out of `allActions` while that module is off (see `editSnippet`, `canEditSnippets` and `TextAction.createSnippetID`). `allActions` feeds the palette and Shortcuts (`shortcutActions`), so the action disappears from both.

## 6. Test and document it

- Core: the transformation in `TextActionTests` or `FileActionTests` (`make test`).
- App (`CortexTests/Modules/Actions/`): palette behaviour in `ActionsScopeTests`, jobs and progress in `ActionProgressTests` (`make test-app`).
- What tests cannot see (pasting, windows, notifications, Shortcuts) gets a step in check M18 of [MANUAL_TESTS.md](MANUAL_TESTS.md).
- [The built-in actions](modules/ACTIONS.md#the-built-in-actions) in the Quick actions page, and the README's Quick actions section if the action behaves differently from the usual paste/copy/notify.

# Adding a command

A command is typed after `$` with its input: `$port 3000` ([COMMANDS.md](modules/COMMANDS.md)). It never runs on the clipboard or a selection; what is not typed comes from its form, where context is only ever a suggestion. It is not a `QuickAction`: it *resolves* to an outcome that says what ⏎ does, and Quick Actions carries the outcome out (`CommandAction`), so the confirmations, jobs, usage counts and delivering of the output are the same as above.

If opening a URL or running a shell command does it, a TOML file with a `trigger` in `~/.config/cortex/actions/` needs no code (`UserCommand`, see the README). Build it in when it needs Swift, should look things up before ⏎ (like `$port`), or decides what to ask based on what it finds.

## 1. The protocol

Write a `Command` in `CortexCore/Sources/CortexCore/Commands/` and add it to `CommandCatalog.builtIns`, after the existing ones. `PortCommand.swift` is the example for a command with an argument, `MemoryUsageCommand.swift` for one without.

- `id` starts with `command.` and is stable forever (usage counts and remembered options are stored under it).
- `name` is the word after `$`: lowercase, no spaces, unique among every command (built-ins, other modules' through `CommandContributing`, user files). `CommandCatalog.problems` reports a user file whose trigger is a built-in's name, so a new built-in name can turn an existing file into a problem: mention it in the README. The name also counts as a search word, and typed exactly it ranks first.
- `title`, `symbol` and `keywords` are the row's and search's, as for an action. `summary` is one sentence for the pane and the form: "Ends what listens on a port."
- `argument` is the main input, or nil for a command that takes nothing (`$mem` runs on ⏎ at once). `title` labels the form's field, `placeholder` is shown in the row (`$port 3000`) and the empty field, `isRequired` says whether ⏎ may run without it.
- `accepts` and `matches` have defaults derived from the argument: text for a text argument, files for a path, `.none` when it is optional or absent; never offered in `>`. Override `matches` only for context that is unmistakably meant for the command (`PortCommand.matches`: a copied port number); `>` then offers it on that input like any action.
- `options` are the form's other fields, remembered per command when it runs from the form and handed to `resolve` in `invocation.options`. `AICommand`'s Model is the example.
- `isRemote` is true for a command that sends its input to an online service: it never runs on sensitive input.
- `resolve(_ invocation:)` is the one function that does the work (section 4). It gets `invocation.input`, `invocation.options` and, for a command with `runsOnHosts`, `invocation.machine`.

## 2. The argument kinds

| `CommandArgument.Kind` | The form's field | What `resolve` gets in `invocation.input` |
| --- | --- | --- |
| `.text` | One line | `.text`, trimmed |
| `.prompt` | Several lines; ⇧⏎ breaks a line | `.text`, trimmed |
| `.number(range)` | One line; ⏎ only runs on a whole number in the range | `.text` with the number. Typed after the name, any text arrives: check it in `resolve` too and throw a `QuickActionError` saying what is wrong (the pane shows it) |
| `.path` | One line for existing files or folders (`~/` allowed, quoted with spaces); a file dropped on the palette fills it | `.files` |
| `.choice(CommandChoices)` | A list to pick from, loaded when the form opens; typing filters it | `.text` with the choice's value from the form. Typed after the name, the text as typed: match it in `resolve` with `CommandChoices.match` (title or value, ignoring case, else the only title that starts with it) and throw when nothing matches (`DiskSpaceCommand`). `CommandChoices(allowsPaths: true)` takes an existing file or folder too, as typed text, and a dropped file fills the field (`CodeCommand`) |

Do not reject input in `accepts` beyond its kind: accept any text and let `resolve` say what is wrong.

## 3. Suggestions

`argument.suggestions` says what the form lists under the field (`CommandSuggestions`). A suggestion is only ever put into the field by ↓ or a click; nothing runs on one that was not picked.

- `.none`: nothing (`$kill`: a process name from the clipboard would be a surprise).
- `.clips(matching: pattern)`: the pasteboard, then recent text clips, whose trimmed text matches the regular expression; at most five, newest first. Sensitive clips are never suggested. For a number argument the number in the clip is suggested (`:3000` as `3000`).
- `.clipboardText`: the pasteboard's text as one entry (`$ask`, `$img`).
- `.choices`: the argument's own choices; a `.choice` argument always lists them.

## 4. Resolving

`resolve` returns what ⏎ will do, as one of five outcomes (`CommandOutcome`); pick the one that says what happens, and the palette gets the pane, the hints, the confirmation, the progress and the delivery from it:

| Outcome | When | ⏎ | Examples |
| --- | --- | --- | --- |
| `.value(.text(…))`, `.secret`, `.report`, `.image` | The command has a result to paste | Pastes exactly what the pane shows, ⌥⏎ copies it. `.secret` is recorded as a sensitive clip (`$token`) | `$uuid`, `$token` |
| `.value(.report(ActionReport(text:content:)), refresh: .seconds(2))` | A result better drawn than read | The same; `refresh` says how often it is resolved again while it is shown, without a loading state | `$mem`, `$cpu`, `$gpu` (`refresh`), `$disk` (none) |
| `.open(.url / .reveal / .openWith / .play)` | It opens or plays something | Does it; ⌥⏎ copies the link or path. The hint says what: set `verb` on the command for a better name than the target's ("Open in VS Code") | `$code`, `$open`, `$term`, `$sound` |
| `.act(ActionConfirmation)` | It changes something that cannot be undone | The alert, then `perform`. Check again in `perform` that the target is still the one shown | `$port`, `$kill` |
| `.job(plan:, run:)` | It is slow or contacts a service | Starts a background job with the progress card; `run(context)` returns an `ActionOutput` that is delivered as an action's is. `plan` says what it will do | `$clip`, `$ask`, `$note` |
| `.handoff(description:, run:)` | It hands over to something that delivers the result itself | Runs `run`; nothing is pasted. Set `verb` ("Pick Colour") for the hint | `$color`, `$ocr` |

**Resolving is cheap and changes nothing.** The palette calls `resolve` while the command is selected (after 150 ms for typed input, off the main actor, so `resolve` may call `ProcessRunner`), and ⏎ carries out exactly the outcome it showed. So a lookup that is quick is fine in `resolve`: `$port` runs `lsof`, `$code` reads `projects.toml`. Anything slow or with an effect goes inside the outcome: a download in a job's `run` (`$clip` parses and describes the cut in `resolve`), a request to an AI vendor in a job's `run` (never in `resolve`: selecting `$ask` must send nothing), ending a process in `perform`. Throw a `QuickActionError` for what is wrong with the input (the pane shows it in red), and `QuickActionError.notice(…)` for nothing to do (`Nothing is listening on port 3000`): the pane shows it plainly, not in red, and from `>` it is a notification with that sentence. Either way ⏎ beeps. The hints bar says what ⏎ and ⌥⏎ do from the outcome (`CommandOutcome.keys(of:)`: an act reads "Kill…" from its `confirmTitle`), so choose the confirming button's words with that in mind.

Listing and ending processes is in `ProcessTools` and `Docker`; short text tables to paste are `ReportTable`. For a report the app conforms the command to `ReportPresenting` to draw the pane from the content (`$disk` from its `VolumeSpace`, `$mem` from its `MemorySnapshot`, `$cpu` from its `CPUSnapshot`, `$gpu` from its `GPUSnapshot`, in `Modules/Commands/Views`); without a conformance the pane shows the text. All four take a host from `~/.ssh/config` too (`SSHHosts`: its aliases, `run` for a script with `sh` over ssh that never prompts, and `sections` for output marked with `@@ name` lines, so one script can serve macOS and Linux); take the `MachineShell` as an init parameter so tests can answer for the host. Commands are not offered in Shortcuts.

A command that belongs to another module (with its own settings or API key) is not a built-in: that module conforms to `CommandContributing` (`Cortex/Modules/Commands/CommandsAPI.swift`) and lists it in `contributedCommands`, asked on every listing (`AIModule`).

## 5. Test and document it

- Core (`make test`): the command in `CortexCore/Tests/CortexCoreTests/Commands/` (`CommandTests`, `DiskSpaceTests`, `MemoryUsageTests` are examples). Test `resolve` for the outcome (`command.resolve(.text("3000"))`), and add the command to the table in `CommandOutcomeTests.everyBuiltInResolvesToItsKind`. Keep what reads the system behind a parameter or a pure function (`DiskSpaceCommand(volumes:)`, `VMStatistics(vmStat:)`) so tests can feed samples; do not assert this Mac's numbers. `BuiltInCommandTests.idsAndNamesAreUnique` lists the names.
- App (`make test-app`): the list, typed arguments and resolutions in `CommandsScopeTests`, the form in `CommandFormTests`, both in `CortexTests/Modules/Commands/`.
- What tests cannot see (alerts, notifications, pasting) gets a step in check M23 of [MANUAL_TESTS.md](MANUAL_TESTS.md).
- The README's "`$` commands" table.
