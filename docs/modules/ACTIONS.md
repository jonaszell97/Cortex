# Quick actions

The Quick Actions module runs small jobs on something you already have: the text on the clipboard, a clip, the files selected in Finder, files dropped onto Cortex, or the text selected in any app. Format JSON, Uppercase, Convert Image to JPEG and Merge PDFs are built in. Your own actions are TOML files in `~/.config/cortex/actions/`. The same actions are in the Services menu and in Shortcuts. The module also runs the `$` commands for the [Commands module](COMMANDS.md).

## Using it

Ways in, each with its own input:

| Way in | Input |
| --- | --- |
| `>` in the palette | The Finder selection if Finder was in front when the palette opened, otherwise the clipboard. |
| ⌘K on a clip in the clipboard list | That clip (the pane says "Selected clip"). Works on a sensitive clip too, but nothing is sent anywhere then (see [AI.md](AI.md)). |
| Quick actions hotkey, default ⌃⌥⌘A, or *Quick Actions* in the status menu | Opens `>`: over Finder the selected files, elsewhere the clipboard. |
| Selection hotkey, default ⌃⌥⌘S | The text selected in the front app (see below). |
| Files dropped on the palette or the menu bar icon | Those files ("Dropped"). |
| Finder's context menu → Quick Actions or Services → *Open in Cortex* | The selected files or text ("From Services"). |
| Shortcuts: *Transform Text with Cortex* and *Run Cortex Action on Files* | The text or files the shortcut passes in. |

What is typed after `>` only searches: every word has to match the action's title or keywords. Without a query the list shows the actions that accept the input, most used first, then in catalog order. To run something on text you type, use [`$` commands](COMMANDS.md). A copied port number or path is the one exception: `>` also offers Kill Process on Port and Open in Finder for those (see "What `>` loses" in COMMANDS.md).

| Key in `>` | Does |
| --- | --- |
| ⏎, ⇧⏎ | Runs the selected action and pastes a text or image result into the app the palette was opened over. |
| ⌥⏎ | Runs it and only copies the result. |
| ⌘1 to ⌘9 | Runs the action in that row. |
| ⇥ | Moves into the action's options, when it has any. ⇧⇥ goes back. |

A text or image result becomes a new clip in the history, masked if the input was sensitive. Results that are files are written next to the originals and never over them (a clipboard image or text has no folder, so its results go to `~/Downloads`); a notification reveals them in Finder. An action that only reports something posts a notification. A result that takes more than 5 seconds, or whose target app is no longer in front when it is ready, is only copied, with a notification.

Instant actions (text transformations, QR Code) are previewed: the pane shows the result before you press ⏎, and ⏎ uses exactly that result. Other actions say "Runs in the background", or show the command they will run. File actions run as background jobs. A job that takes longer than a second shows a card in the top-right corner with a progress bar and a cancel button, and the menu bar icon turns into a progress ring. The status menu lists running jobs, and choosing one cancels it. A notification follows when it ends.

**Options.** Some actions have options, shown below the preview. "Pad" pads every line to a length with a character, on the left or the right. The values are remembered per action and also used from Shortcuts.

**Acting on the selection.** Select text in any app and press the selection hotkey. Cortex copies the selection with ⌘C, puts the clipboard back at once, and opens `>` on the text; the pane says "Selection". ⏎ replaces the selection with the result, ⌥⏎ copies the result instead. Neither the temporary copy nor the result is added to the history, and the clipboard is as it was afterwards. It needs Accessibility, like pasting, and does not work in apps that cannot copy the selection (some password fields). If nothing is selected, a notification says so. Pressing the hotkey with the palette open closes it.

### The built-in actions

| Kind | Actions |
| --- | --- |
| Text | Format JSON, Minify JSON, Base64 Encode, Base64 Decode, URL Encode, URL Decode, Trim Whitespace, Single Line, Uppercase, Lowercase, Title Case, To Snake Case, To Camel Case, To Pascal Case, To Kebab Case, To Constant Case (any input case, also with spaces; per line), Count Words (a notification), Strip Formatting, Markdown Table from TSV, Pad (options), QR Code (an image) |
| Generators | Generate UUID, Current ISO Date. They need no input and are also listed for text. |
| Hand-offs | *Create Snippet* opens the snippet editor on a new snippet with the text as its body (only while Snippets is on). *Save as Command* saves the text as a shell command you run with `$`: ⏎ asks for its name, then shows the command, how it is typed and the file it goes into, and saves only once you confirm. A name that is not one word, or that a command already has, is asked for again with the reason. A `$ ` prompt copied with the command is left out. Not offered in Shortcuts. |
| Images | Convert Image to JPEG, PNG, HEIC and WebP, Resize Image to 1600 px and to 800 px, Compress Image (JPEG 70 %). They also take an image on the clipboard. |
| Video and audio | Convert Video to MP4, Convert Video to GIF, Extract Audio |
| PDF and archives | Compress PDF, Merge PDFs (two or more), Compress to ZIP (a file or folder becomes `<name>.zip`, several become `Archive.zip`) |
| From other modules | With AI on: Proofread and Summarize ([AI.md](AI.md)). With Knowledge on: Save as Note and Add as To-Do ([KNOWLEDGE.md](KNOWLEDGE.md)). With Text Recognition on: Recognize Text ([TEXT_RECOGNITION.md](TEXT_RECOGNITION.md)). |

Images use `sips` and ZIP uses `zip`, both part of macOS. Video, audio and WebP need `brew install ffmpeg imagemagick`; Settings → Quick Actions shows which tools were found.

## Settings

Settings → Quick Actions has the module's Enabled switch (on by default) and:

| Option | Default | Meaning |
| --- | --- | --- |
| Open quick actions | ⌃⌥⌘A | Hotkey. Opens `>` on the Finder selection or the clipboard. |
| Act on the selection | ⌃⌥⌘S | Hotkey. Copies the selected text, opens `>` on it, and lets ⏎ replace the selection. |
| Folder | `~/.config/cortex/actions` | Where the action files are (`$XDG_CONFIG_HOME/cortex/actions` when that is set). A button opens it in Finder. The folder is created when the module starts. |
| Your actions | | The files that loaded, with the file name, and in red the files with problems and what is wrong with them. Files with a `trigger` also show how they are typed after `$`. |
| Tools | | Whether `ffmpeg`, `magick`, `sips` and `zip` were found, and `brew install` hints for the missing ones. |

The module asks for Accessibility (pasting, the selection hotkey) and for permission to control Finder (reading the Finder selection; macOS asks the first time). Which of your files sync is set on the Sync page (see Data and privacy).

## Your own actions

An action file is a TOML file in the folder. It is reloaded whenever the folder changes, without a restart. A file that does not parse is skipped and listed with its problem under *Your actions*; the other files still load.

```toml
# ~/.config/cortex/actions/shrink-video.toml
name = "Shrink Video to 720p"
accepts = ["files"]                  # any of: text, image, files, none
extensions = ["mov", "mp4"]          # optional: only offered for these files
command = "ffmpeg -nostdin -i {input} -vf scale=-2:720 {output}"
output_extension = "mp4"             # optional: extension of {output} (default: the input's)
output_suffix = "-720p"              # optional: clip.mov → clip-720p.mp4
# output = "files"                   # files, text or none; default: files if the command uses {output},
                                     # standard output for text input, otherwise just a notification
# symbol = "film"                    # optional SF Symbol
# keywords = ["small", "compress"]   # optional search words
```

| Key | Meaning |
| --- | --- |
| `name` | The title. Required. |
| `accepts` | What the action takes: `text`, `image`, `files`, `none`. A file with `accepts` is a `>` action. |
| `command` or `url` | Exactly one. A command runs with `/bin/zsh -c`, in the folder of the file it runs on (a scratch folder for text, your home folder when there is no input), with Homebrew on the `PATH`. A `url` is opened in the default browser or app, with `{argument}` filled in and percent-encoded; it needs `accepts` with only `text` and `none`, and previews instantly. |
| `extensions` | Lowercase file extensions the action is offered for. All files must match. |
| `output` | `files` (the `{output}` files), `text` (standard output, pasted) or `none` (a notification). Default: `files` if the command uses `{output}`, `text` for text input, otherwise `none`. |
| `output_extension`, `output_suffix` | For `files`: the extension of `{output}` and a suffix added to the input's name. Results are never written over an existing file. |
| `symbol`, `keywords` | An SF Symbol (default `link` for a URL, `terminal` for a command) and more search words. |
| `confirm` | `true` asks in an alert before running or opening. The palette previews the question. |
| `trigger`, `example`, `argument`, `matches` | Make the file a `$` command; see "Your own commands" in [COMMANDS.md](COMMANDS.md). |

Placeholders in a command:

- `{input}` is the file. For text input it is a file holding the text, and the text is also on standard input and in `{argument}` and `$1`. For an image on the clipboard it is a temporary file.
- `{inputs}` is all files at once; the command then runs once instead of once per file.
- `{output}` is where to write the result.
- `{argument}` is the text. The same value is `$1`.

Placeholders are filled through environment variables: `{input}` runs as `"$CORTEX_INPUT"`, and likewise `$CORTEX_OUTPUT`, `$CORTEX_ARGUMENT`. A file name or text can contain anything, quotes and `$(…)` included, and stays one word. Write placeholders bare (`cp {input} {output}`) or inside double quotes (`"Result: {argument}"`). Inside single quotes the shell cannot fill them in, which is reported as a problem. Other mistakes are reported too: an unknown key, a placeholder the accepted inputs cannot fill (`{argument}` without text, `{input}` in a URL), and `output = "files"` without `{output}`.

A command runs in the background like a file action, with the progress card and cancel button if it takes more than a second. A non-zero exit is reported with the end of its standard error. Text that comes back with a trailing line break loses it.

A URL action:

```toml
# ~/.config/cortex/actions/search-ddg.toml
name = "Search DuckDuckGo"
accepts = ["text"]
url = "https://duckduckgo.com/?q={argument}"
```

Files with a `trigger` are `$` commands, and a file with both `trigger` and `accepts` is both. `matches` then decides when `>` offers the file for clipboard text. To save a command without writing the file by hand, select it (or copy it) and run *Save as Command*; it writes `<name>.toml` with the command's first line as `name`. An agent can write one through the MCP server's `create_action` ([KNOWLEDGE.md](KNOWLEDGE.md#the-mcp-server)).

Adding an action in Swift, for work that needs PDFKit, a preview or an app window: [ADDING_ACTIONS.md](../ADDING_ACTIONS.md).

## Data and privacy

The module has no database table of its own.

| What | Where |
| --- | --- |
| Action files | `~/.config/cortex/actions/*.toml` (or under `$XDG_CONFIG_HOME`). Plain files you can edit, back up and put under git. |
| Usage counts | UserDefaults key `quickActionUsage` (JSON, by action ID), used to rank the list. |
| Remembered option values | UserDefaults key `quickActionOptions` (JSON, by action ID and option ID). |
| Hotkeys | UserDefaults, written by the KeyboardShortcuts package under the names `quickActions` and `actOnSelection`. |
| Scratch files | A temporary folder `cortex-action-<UUID>` for each run, deleted afterwards. |
| Results | Text and image results become clips in the clipboard database ([CLIPBOARD.md](CLIPBOARD.md)). File results are the files next to the originals. |

Usage counts and option values stay on the Mac and never sync. Switching the module off keeps all of it; it stops watching the folder, cancels running jobs and stops handling the Services entry. The Shortcuts actions stay registered, since App Intents cannot be removed, and say that Quick Actions are switched off.

**Sync.** The `*.toml` files at the top level of the folder sync, encrypted, when sync is on and *Your quick actions* is on in the Sync page (on by default; the UserDefaults key is `syncActions`). See [SYNC.md](../SYNC.md). Files over 64 KB or not UTF-8 stay local. When both Macs change a file, the newer one is kept and the other is saved in `.conflicts/` inside the folder; a file deleted on the other Mac moves there too. The tools and scripts your actions call, subfolders, usage counts and option values do not sync.

**What leaves the Mac.** The built-in actions work locally and send nothing. The exceptions are the ones you write and the AI actions:

- A `command` runs whatever you put in it, with the input as an environment variable, standard input or file. What it does with the network is up to the command.
- A `url` action opens a web page with the argument in the address, in your default browser. Nothing is sent until you press ⏎ (the pane shows the address first).
- Proofread and Summarize send text to the AI vendor only when you run them; see [AI.md](AI.md).

**Sensitive input.** A clip marked sensitive (a password manager's copy, or text that looks like a token) can still be used with actions, and the results are recorded as sensitive too. Actions that send their input to a service (`isRemote`) are not listed for it, and `ActionsService.run` refuses it however it was started. The selection hotkey borrows the pasteboard for a moment; the history does not record it, and a result that replaces the selection is not recorded either.

## How it works

The logic that needs no AppKit is in `CortexCore/Sources/CortexCore/Actions/`; the app side is in `Cortex/Modules/Actions/`. `ActionsAPI.swift` is the only file of the module whose types other modules may name (see [ARCHITECTURE.md](../ARCHITECTURE.md) for how modules use each other's APIs).

| File | Role |
| --- | --- |
| `Actions/QuickAction.swift` | The `QuickAction` protocol, `ActionInput` (none, text, image, files), `ActionOutput` (text, report, image, files, done, snippet, saveCommand, confirm, open, reveal, handled), `ActionConfirmation`, `ActionContext`, `QuickActionError`. |
| `Actions/ActionCatalog.swift`, `ActionListing.swift` | `builtIns`, ranking by query and usage, and `ActionListing` (`.context` for what the palette found, `.handedIn` for a clip, drop, selection or Service). `ActionInput.typed` turns typed text into files or text for commands. `>` lists the built-in commands as `CommandAction`s (`Commands/CommandAction.swift`; see [COMMANDS.md](COMMANDS.md)) and offers those whose `matches` fits. |
| `Actions/TextActions.swift`, `FileActions.swift` | `TextAction` (pure, instant, previewed) and `FileAction` (macOS only, background job, results next to the source via `FileStep.produce`). `ProcessRunner`, `OutputPath` and `FFmpegProgress` support them. |
| `Actions/UserActionDefinition.swift`, `UserAction.swift`, `TOML.swift` | The TOML subset, the file format and its checks, `UserAction`, `ShellCommand` (the placeholder rules) and `UserActionLibrary.load`, which returns `actions`, `commands` and `problems`.
| `Actions/UserActionFile.swift` | A new action file from its keys, checked as it will load and never over another file; the MCP server's `create_action` writes it. |
| `Actions/ActionFileSync.swift` | The sync handler for the folder. |
| `Modules/Actions/ActionsModule.swift` | The `CortexModule` (id `actions`, trigger `>`, order 30). Hotkeys, status menu items and icon, dropped files, the Services provider, `ActionsAPI`, `SyncContributing`. |
| `Modules/Actions/ActionsService.swift` | Owns the catalog (built-ins, `ActionContributing` modules' actions, your files), watches the folder, usage counts, option values, previews, running jobs and delivering results. `ActionJob` is one running job. |
| `Modules/Actions/ActionsScope.swift`, `Views/` | The `>` scope: the list, the context or handed-in input, the preview task, options, the keys. |
| `Modules/Actions/ActionsAPI.swift` | `ActionsAPI` (what other modules use), `ActionPreview`, `CommandResolution`, `ActionDelivery`, `ReportPresenting`, `ActionContributing`, `ResolvedActionInput`. |
| `Modules/Actions/SelectionReader.swift`, `ActionInputs.swift` | Copying the selection and putting the clipboard back; reading the pasteboard and Finder selection (Apple Events) as action input. |
| `Modules/Actions/ServicesProvider.swift`, `QuickActionIntents.swift` | The *Open in Cortex* Service (declared under `NSServices` in `Config/Cortex-Info.plist`) and the two App Intents. |
| `Modules/Actions/ProgressCardController.swift` | The progress card panel. It shows after a one-second delay, so quick jobs never flash it. |

**Choosing input.** `ActionsModule.resolveInput` reads the Finder selection when Finder is the previous app, else the pasteboard (`ResolvedActionInput.pasteboard`, which also sets `isSensitive`). `ActionsScope` keeps that as `context` until the palette hides. `handIn` replaces it for ⌘K, drops, Services and the selection hotkey, and the scope then lists with `.handedIn`. The scope never reads what is typed as input.

**Running.** `ActionsService.run` records the use, takes the preview if it is for the same input and options, otherwise executes. Instant actions deliver at once. Everything else becomes an `ActionJob`, and the action's `run` executes off the main actor with its own temporary directory. `deliver` switches on the `ActionOutput` (the table in [ADDING_ACTIONS.md](../ADDING_ACTIONS.md) lists what each does). `.confirm` shows an alert, and a confirmed step runs as a job under the action's name.

**Other modules.** A module that adds actions conforms to `ActionContributing` (AI, Knowledge, Text Recognition); the service asks on every listing, so a module that is off adds nothing and Quick Actions names none. `Create Snippet` goes through `SnippetsAPI`. The Clipboard module's ⌘K calls `ActionsAPI.showActions(on:)`. Commands uses `resolve`, `run`, `options`, `setOptions`, `usage`, `userCommands`, `onUserFilesChanged` and `commandPane`.

**Shortcuts.** `ActionsService.shortcutActions` is every action that is not a command (`CommandAction`), without *Save as Command*. The text intent offers the actions that take text, the file intent the `FileAction`s and your files that accept files. `runForIntent` runs an action with the remembered options and returns its result instead of pasting it. A `.confirm` result fails there.

## Tests

- `CortexCore/Tests/CortexCoreTests/Actions/`: `TextActionTests`, `FileActionTests`, `UserActionTests` (the file format, placeholders, quoting, the problems), `UserActionFileTests` (files written from their keys), `ActionListingTests`, `SyncActionTests` (the folder sync) and `DocsActionFileTests`, which loads the TOML examples from this page and [COMMANDS.md](COMMANDS.md) and checks that they load and behave as described.
- `CortexTests/Modules/Actions/`: `ActionsScopeTests` (listing, ranking, previews, options, delivery, keys) and `ActionProgressTests` (jobs, the card, the status menu). `ModuleLifecycleTests` covers switching modules on and off.
- Manual: [MANUAL_TESTS.md](../MANUAL_TESTS.md) M18 (quick actions in real apps, Finder, Services, Shortcuts, the selection hotkey), M19 (sync).
