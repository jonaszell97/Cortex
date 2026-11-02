# Commands

The Commands module is `$` in the palette. A command runs on what you type after its name (`$port 3000`, `$kill node`, `$ask why is the sky blue`) or fill into its form. It never runs on the clipboard, a clip or a selection: those only ever appear as suggestions that you take with a key. A command does not run itself: it *resolves* to an outcome that says what ⏎ does (paste a value, open something, ask before acting, start a background job, hand over), and the Quick Actions module carries that out, so a command has the same confirmations, background jobs, usage counts and delivery as the [`>` actions](ACTIONS.md). The module is thin: a catalog, a scope, a form and a settings page. It runs commands through the Quick Actions module, so it needs that module on.

## Using it

Type `$` in the palette. There is no hotkey and no menu item. `$` alone lists every command, the most used first; each row shows how it is typed (`$port 3000`, the example dimmed) with the command's title below. Once you type an argument after a command's name, its row shows that instead of the example (`$code mathical`, not `$code cortex`), and a host typed with `@` stays in it (`$disk /mnt/usb @pi`). The pane shows what the selected command takes and, once it is resolved on what you typed, what ⏎ will do (the value, what opens, what is affected, the plan of a background job) under a header with the command as typed. The hints bar names what ⏎ and ⌥⏎ do for it: "Paste", "Open in VS Code", "Kill…", "Start" (see "The hints" and "The pane").

The text after `$` is split at the first space. When the first word is exactly a command's name (ignoring case and accents), that command comes first and the rest is its input: `$port 3000`. Otherwise the whole text searches names, titles and keywords: `$po` and `$memory` find commands, `$kil node` finds nothing.

A command that runs on hosts (`$kill`, `$port`, `$mem`, `$cpu`, `$gpu`, `$disk`) also takes a host from `~/.ssh/config`: a word `@pi` anywhere after its name, as in `$mem @pi`, `$port 3000 @pi` or `$disk /mnt/usb @pi`. See "Hosts".

| Key | Does |
| --- | --- |
| ⏎, ⇧⏎ | Carries out the selected command's outcome if it has what it needs, otherwise opens its form. A text or image value is pasted into the app the palette was opened over; the hints bar says what it is for the selected command. |
| ⌥⏎ | The second step, where the hints bar shows one: copies a value, copies the link or path of something that would open, starts a job and copies its text result. It beeps where there is none (a question to confirm, a hand-over, a command that did not resolve). Pressed before the pane has resolved (within the pause after typing, or while it looks), it waits for the result and then does the same, so a copy never carries out a kill or starts the eyedropper. |
| ⌘1 to ⌘9 | The same as ⏎ for the command in that row. |
| ⇥ | Opens the form of the selected command, with what you typed after its name filled in. The hint reads "Fill in", "Host" for a command that takes no argument but runs on hosts, or "Options" for one that takes neither. Only commands with an argument, a host or options have it. |
| ⌘E | Opens the typed command's settings file in VS Code: "Edit projects.toml" for `$code`, `terminal.toml` for `$term`, `sounds.toml` for `$sound`. Shown only once the command's name is typed (see "Settings files"). |
| Esc | Closes the palette. In a form it goes back to the list (see "The form"). |

The result of ⏎ or ⌥⏎ on a value is a new clip in the history; results that are not text or images (a notification, Finder, a link, the eyedropper) are not, and ⌥⏎ on a link or path makes the link or path a clip. Typed input is resolved after a short pause, so `$port 3000` is looked up once rather than for every digit. If the command cannot resolve (`$port abc`), the pane says why in red and ⏎ beeps. If there is only nothing to do (nothing listens on the port), the pane says so plainly, not in red, and ⏎ beeps too (see "Nothing to do"). A command that takes nothing, or whose argument is optional (`$uuid`, `$mem`, `$disk`), is resolved at once and runs on ⏎. What ⏎ does is exactly the outcome the pane shows: the UUID shown is the one pasted.

A command may ask first. `$port` and `$kill` show what they found in the pane; ⏎ then shows an alert (⏎ kills, Esc cancels). A background job (`$clip`, `$ask`, a shell command file) shows its plan in the pane and, once started, the progress card with the command as typed (`$deploy staging`).

## The hints

The hints bar says what ⏎ and ⌥⏎ do for the selected command's current outcome, in the list and in the form (`CommandOutcome.keys(of:)`):

| Outcome | ⏎ | ⌥⏎ |
| --- | --- | --- |
| Value | Paste | Copy |
| Open | A specific verb: "Open in VS Code" (`$code`), "Open in Terminal" (`$term`: the terminal app's name), "Show in Finder" (`$open`), "Play" (`$sound`), "Open" for a link (`$gh`, a file with a `url`) | "Copy link" (a link) or "Copy path" (Finder, an app, a sound): the link or path is copied as text, a clip like any other, instead of opening |
| Act | The confirming button and "…", because it asks first: "Kill…", "Stop Container…", "Kill 2 Processes…" | – |
| Job | Start | Start and copy (a job's text result is only copied, as before) |
| Handoff | The command's own verb: "Pick Colour" (`$color`), "Capture Text" (`$ocr`) | – |

The verb comes from `Command.verb` where the command names it (`$code`, `$color`, `$ocr`), otherwise from the outcome (`OpenTarget.verb`). The list's hints are those of the selected command's resolution for what is typed now; until it is there, when it failed or is a notice, or while the command still needs its form (⏎ opens it), they are the generic "Run and paste" and "Run and copy", and the form's are "Run" and "Run and copy". ⌘1–⌘9 keep "Run". Where no ⌥⏎ hint is shown with an outcome (an act, a handoff), ⌥⏎ beeps and does nothing.

## The pane

One layout for every outcome. A header line shows the command as typed in monospace (`$port 3000 @pi`, built like the row: the typed argument and hosts, without the dimmed example; `CommandsScope.typed`) and, for a command that ran on a host, a small tag "on pi". A divider follows, then the body for the kind of outcome:

- a value: the text, the report's view or the image;
- open: what opens, with its icon, or the link;
- act: the question and what is affected;
- a job: the plan;
- a handoff: what happens next.

Loading ("Loading Memory Usage on pi…"), the error (red, with a cross) and the notice (secondary, with an info symbol) use the same place. The form keeps its fields and shows the same body under them, without the header, since the fields show what was typed.

While a new argument is typed, the previous result of the same command on the same machine stays until the new one is there, but it is not passed off as the new one: the body is dimmed and a small progress indicator shows in the corner of the pane, for as long as the input, options or machine it was resolved for differ from the current ones. The header already shows what was typed, so it is the body that is marked as pending. ⏎ still resolves again if it is pressed before the new result is there. A result for another machine is dropped at once.

## Live refresh

A value outcome may carry `refresh` (`$mem`, `$cpu` and `$gpu`: 2 seconds). While the selected command's shown outcome is such a value, the command is resolved again that long after the previous resolve finished, never two at once, and the new value replaces the old one without a loading state. ⏎ and ⌥⏎ use the value shown at that moment. If a refresh fails, the last good value stays and a small line under it says "Couldn't refresh: <reason>"; the next refresh tries again and the line goes when one works.

It stops when the selection, the typed text, the host or the form's fields change (a new resolve starts and may refresh again), when the form is opened (it refreshes its own value, and the list carries on when it is left with Esc), when you leave `$` and when the palette hides. `CommandRefresh` does it for the scope and for each form; its `interval` replaces the value's own, which the tests make short.

## Nothing to do

A command that finds nothing to do ends its `resolve` with `QuickActionError.notice(…)` instead of a plain error: `$port 3000` with nothing listening, `$kill` matching none of your processes, `$kill loginwindow`, a port held by a container runtime that is left alone (also on a host). The pane draws it plainly with an info symbol, not red, and ⏎ beeps as for any resolve that failed. Run from `>` (a copied port), a notice is posted as an ordinary notification with its sentence, as before; a plain error is a "failed" notification.

## The commands

Built in:

| Command | Does |
| --- | --- |
| `$port 3000` | Shows what listens on a port and, once confirmed, ends it. TCP listeners and UDP sockets bound to the port count, never clients connected to it. The process gets SIGTERM, and SIGKILL if it is still running after 3 seconds. Only your own processes are found (`lsof` runs without root). A port published by a container is held by the container runtime on the Mac (Docker Desktop, OrbStack, Colima, Rancher Desktop and Podman are recognised); killing that would stop every container, so Cortex looks the container up with `docker ps` and offers `docker stop`. If it finds none, the runtime is left alone and the pane says why. `$port 3000 @pi` does the same on a host (see "Hosts"). Also offered in `>` for a copied port number, always on this Mac. |
| `$kill node` | Ends your processes by name or PID, after the same kind of confirmation listing each of them. An exact name wins (`$kill node` leaves `nodemon` alone); otherwise every name containing the text is found. More words narrow by command line (`$kill node server.js`). `$kill 4242` is a PID, `$kill :3000` is `$port 3000`. `loginwindow`, `launchd` and `systemd` are never offered (they log you out), nor is `sshd` (ending it over `@host` can lock you out of the host), nor whatever runs as PID 1, however it is called (`init`, `systemd`, `launchd`). `$kill node @pi` ends the SSH user's `node` processes on a host, and `$kill :3000 @pi` is `$port 3000 @pi`. |
| `$disk Macintosh HD` | How full a volume is: total, used with a percentage, free, and purgeable space. The volume is a mounted one, by name or mount point (`$disk /`); without one it is the startup volume. The form lists them, the startup volume first. `$disk @pi` reads a host from `~/.ssh/config`: its root file system, or with an absolute path the file system that path is on (`$disk /mnt/usb @pi`). On a host the argument is a path, not checked against this Mac's volumes. |
| `$mem` | Memory use: physical memory, app memory, wired, compressed, cached files, swap, memory pressure, and the ten largest processes. `$mem @pi` reads a host over SSH. |
| `$cpu` | CPU use sampled over a second: overall, per core, load average and the ten busiest processes. `$cpu @pi` reads a host. |
| `$gpu` | GPU use and the processes using it, from the IOKit registry on a Mac. `$gpu @pi` reads a macOS host, or a Linux host's NVIDIA (`nvidia-smi`) or AMD (`amdgpu`) cards. |
| `$open ~/Downloads` | Shows a file or folder in Finder: a folder opens in a window, anything else is selected in its folder. The path is absolute or starts with `~/`; quote it or paste it as copied. The form suggests copied paths. Also offered in `>` for a copied path or file. |
| `$code cortex` | Opens a project in VS Code by its short name, on this Mac or over SSH. A name may be cut short while only one project starts with it (`$code wish`). A path instead opens that file or folder (`$code ~/.zshrc`). ⌘E opens `projects.toml`. See "`$code` projects" below. |
| `$term cortex` | Opens a new terminal window in a folder by its short name, matched like `$code`'s projects, or by its path (`$term ~/Downloads`; a file's path opens its folder). A folder with a `host` opens an SSH session there. `$term` alone opens one in your home folder. ⌘E opens `terminal.toml`. See "`$term` folders" below. |
| `$clip https://youtu.be/… 1:23 4 airhorn` | Saves a part of a YouTube video as an MP4 for `$sound`: the link, where the clip starts and how many seconds it lasts, then a name. See "`$clip` and `$sound`" below. |
| `$sound airhorn` | Plays a sound by its name: a clip saved with `$clip`, or one named in `sounds.toml`. Names may be cut short like `$code`'s. ⌘E opens `sounds.toml`. |
| `$uuid` | A new random UUID in uppercase, shown at once. ⏎ pastes the one shown and leaves it on the clipboard. |
| `$token 32` | A random token from the system's secure random generator: 32 characters unless you type another length (8 to 512). The form's Format option picks letters and digits (the default), hex, or URL-safe (letters, digits, `-` and `_`). The result is a sensitive clip (masked in the history, cleared from the clipboard after 90 seconds). |

`$mem`, `$cpu`, `$gpu` and `$disk` draw their result in the pane (bars, rings, a process list) and paste a short monospaced table.

**Hosts.** These six take `@host` (a command with `runsOnHosts`). The aliases that count are the `Host` entries of `~/.ssh/config` that name one host, leaving out `*` patterns and git hosting (`github.com`, `gitlab.com`, `bitbucket.org`, `ssh.dev.azure.com`). The word may be cut short while only one alias starts with it (`@rasp`), in any case. Anything else is the preview's error, listing the aliases (`“@nas” is not a host in ~/.ssh/config. Hosts: raspberrypi, linode`), and so is a bare `@` and more than one host (`One host at a time: @pi and @nas`); ⏎ beeps. The text you type never becomes an `ssh` option. For any other command `@word` is just part of the argument (`$token 32 @pi`), and the old forms `$mem pi` and `$disk pi:/mnt/usb` are gone: a bare word after `$disk` is a volume again, and `$mem pi` is not accepted since the command takes no argument. The row and the progress card keep the host (`$mem @pi`), and the pane says "Loading Memory Usage on pi…" while it connects; the reports name the host themselves.

**`$port` and `$kill` on a host.** Everything runs as a POSIX `sh` script on the machine and is read by the same code for this Mac and a host, so the preview and the alert match either way. Only the user's own processes are looked at and ended, and nothing runs with `sudo`. The user is `id -u`; `uname -s` tells a Mac from Linux; the processes are `ps -A -o pid=,uid=,comm=` filtered by that user, with `ps -ww -o pid=,command=` for the command lines. The listeners on a port are `lsof -nP +c 0 -iTCP:N -sTCP:LISTEN -iUDP:N` on a Mac and `ss -Hlntup 'sport = :N'` on Linux (`lsof` when `ss` is missing); only the user's own sockets show a process. A Mac, or a host, whose port is held by a container runtime is asked for the container with `docker ps --filter publish=N`, and only containers whose Ports column publishes host port N are kept (`publish=` also matches a container's own port, so `-p 8080:80` is the container for `$port 8080`, not for `$port 80`; a published range such as `3000-3005->3000-3005` includes its ports); a Linux host is always asked (if `docker` is there), because `docker-proxy` runs as root and is invisible without `sudo`. Ending is one script: for each PID it checks that the process still runs under the name it had when it was looked up (a PID may have been reused since), sends SIGTERM, waits up to 3 seconds, sends SIGKILL to those still running under that name, and prints which ended, which needed SIGKILL and which could not be signalled. `docker stop --time 3` runs on the same machine. Cortex's own process is left out on this Mac only. Nothing found is said with the host (`Nothing is listening on port 3000 on pi (only your own processes are checked)`, `None of your processes on pi is called “node”`); a host without `ps`, `lsof` or `ss`, or running neither macOS nor Linux, is the preview's error. The alert names the host (`Kill node on pi?`, `Stop container web on pi?`, `Free port 3000 on pi?`, `Kill 3 processes on pi (port 3000)?`) and the notification too (`Ended node (PID 4242) on pi (port 3000)`); on this Mac the titles are as before.

From other modules, while they are on:

| Command | Module | Does |
| --- | --- | --- |
| `$ask …`, `$img …` | AI | Ask a question, generate a picture ([AI.md](AI.md)). |
| `$note …`, `$todo …`, `$tidy` | Knowledge, with AI on | File a text as a note or to-do, sort the inbox ([KNOWLEDGE.md](KNOWLEDGE.md)). |
| `$color` | Color Picker | Shows the eyedropper and copies the colour you click ([COLOR_PICKER.md](COLOR_PICKER.md)). |
| `$ocr` | Text Recognition | Captures text from a screen region ([TEXT_RECOGNITION.md](TEXT_RECOGNITION.md)). |

And your own, from the TOML files of the Quick Actions folder (see "Your own commands").

**`$code` projects.** Every folder in `~/Developer` is a project named after the folder. For other names, other folders and projects over SSH, write `~/.config/cortex/projects.toml` (`$XDG_CONFIG_HOME/cortex/projects.toml` when that is set):

```toml
scan = ["~/Developer", "/Volumes/Work"]   # folders whose folders are projects; [] for none

[api]                                     # $code api
path = "~/Developer/myapp/myapp-api"        # a folder or a .code-workspace file

[pi]                                      # over SSH, with VS Code's Remote-SSH extension
host = "raspberrypi"                      # an alias from ~/.ssh/config, or user@host
path = "/home/pi/home-assistant"          # absolute on that host
```

The file's projects come first in the form, then the scanned folders by name; a name in the file wins over a folder's. The file is read whenever `$code` runs or its form opens, so changes count at once. ⌘E opens it (see "Settings files"). `$code` with nothing after it, ⏎, opens the form. A mistake in it is the preview's error, with the line. `$code` opens VS Code through a `vscode://` link, which the pane shows before ⏎, so the `code` shell command is not needed. A project opens in a new window, never in place of the one you have open; when a window already has it open, that window comes to the front. A single file opens in the window whose folder has it, else in the last one.

**`$term` folders.** Every folder in `~/Developer` opens by its name, as with `$code`. For other names and folders, or another terminal app, write `~/.config/cortex/terminal.toml` (`$XDG_CONFIG_HOME/cortex/terminal.toml` when that is set). It is `projects.toml`'s format, with folders on this Mac or on a host over SSH, and an `app`:

```toml
app = "Ghostty"                           # by name, or a path to the .app; default: Terminal
scan = ["~/Developer"]                    # folders whose folders open by name; [] for none

[dl]                                      # $term dl
path = "~/Downloads"                      # starting with / or ~/

[pi]                                      # $term pi
host = "raspberrypi"                      # an alias from ~/.ssh/config, or user@host
path = "/home/pi/home-assistant"          # absolute on that host
```

An app by name is looked for in `~/Applications`, `/Applications` (and its `Utilities`) and `/System/Applications` (and its `Utilities`). The folder is handed to the app as if dropped on its icon: Terminal opens a new window there, and another app opens a window or a tab as it is set up to. The pane names the folder and the app before ⏎. The file is read whenever `$term` runs or its form opens; a mistake in it, or an app that is not there, is the preview's error.

A folder with a `host` opens a new terminal window with `ssh -t host` that changes into the folder and starts the host's login shell. Cortex writes a small `.command` script for it (in the temporary folder, named for the host and folder) and hands that to the app instead of a folder, so the app has to open `.command` files in a new window, as Terminal and iTerm do; the pane names that script. The host needs key-based login or an agent: the session asks for a password in its window otherwise. Only `terminal.toml` folders can be on a host; a path typed after `$term` is always on this Mac.

**Settings files.** `projects.toml`, `terminal.toml` and `sounds.toml` are a command's settings file (`SettingsFileCommand`). While the command's name is typed (`$code`, `$code cor`, not `$co`), the hints bar shows ⌘E "Edit projects.toml", and the command's form has it too. ⌘E closes the palette and opens the file in VS Code through a `vscode://` link, first writing it with the defaults and examples commented out when there is none. The command itself never opens its file.

**`$clip` and `$sound`.** `$clip` takes a link (`https://` may be left out), the start and the duration, then an optional name: `$clip https://youtu.be/abc 1:23 4 airhorn`. Times are seconds (`83`, `83.5`, `83s`), `1:23` or `1:02:03`, or `1m23s`; a link copied with its time (`?t=83`) needs only the duration. A clip is at most 600 seconds. The pane shows what will be cut and where it goes; ⏎ runs it in the background with the progress card. yt-dlp downloads only that part of the video, at most 720p, cut at the exact frame, and ffmpeg makes it an H.264 and AAC MP4. Both have to be installed (`brew install yt-dlp ffmpeg`); when yt-dlp fails on YouTube, it usually needs updating (`brew upgrade yt-dlp`). The clip is saved as `<name>.mp4` in the sounds folder, named after the video when no name is typed, with a number added when the name is taken, and a notification shows it in Finder.

`$sound` plays any sound file in that folder by its name without the extension (MP4, M4A, MOV, MP3, WAV, AIFF, CAF, AAC), with the sound only. A name is matched like a `$code` project's, and the pane names the file before ⏎ plays it. Sounds started one after another play over each other. For other names, sounds elsewhere, or another folder, write `~/.config/cortex/sounds.toml` (`$XDG_CONFIG_HOME/cortex/sounds.toml` when that is set); ⌘E on `$sound` opens it in VS Code, writing it first with an example commented out:

```toml
folder = "~/Music/Sounds"                 # where $clip saves; default: sounds/ next to this file

[horn]                                    # $sound horn
path = "airhorn.mp4"                      # in the folder, or a path starting with / or ~/
```

The file's sounds come first in the form, then the folder's files by name; a name in the file wins over a file's. The file is read whenever `$sound` or `$clip` runs, so changes count at once. A mistake in it is `$sound`'s preview error, with the line, and makes `$clip` fail with it.

## Settings

Settings → Commands has the module's Enabled switch (on by default). It is off, with the reason shown, while Quick Actions is off. Below it is a cheat sheet: every command with how it is typed, its title, its symbol and where it comes from ("Built in", the name of the module that adds it, or the file name). There are no other options and no hotkeys. Problems with your command files are on the Quick Actions page, which owns the folder.

## Data and privacy

The module stores nothing of its own and has no database table.

- **Usage counts and remembered options** are in the Quick Actions module's UserDefaults keys `quickActionUsage` and `quickActionOptions`, under the command's ID (`command.port`, `ai.ask`, `user.<file>`). They stay on the Mac and never sync.
- **What you type** is not saved. The values in a form are kept in memory until the palette hides. The result of a command is a clip like any action's result (see [CLIPBOARD.md](CLIPBOARD.md)).
- **Suggestions** read the pasteboard once when a form opens, and the last 50 text clips of the history through the Clipboard module's API. The pasteboard is not used, and clips are left out, when they are sensitive (a password manager's copy, or text that looks like a token). Without the Clipboard module only the pasteboard is suggested.
- **Sync.** Commands themselves do not sync. Your command files are action files and sync with the others ([ACTIONS.md](ACTIONS.md), [SYNC.md](../SYNC.md)). `projects.toml`, `terminal.toml` and `sounds.toml` are only written by ⌘E when they are missing, and do not sync; neither do the clips.

What leaves the Mac, and when:

- `$disk`, `$mem`, `$cpu` and `$gpu` connect to a host from your `~/.ssh/config` only when you name it with `@host` or pick it in the form's Host field (which starts at This Mac, follows the query whenever the list opens the form, and is never remembered), and run a read-only shell script there: `df`, `ps`, `top`, `vm_stat`, `ioreg`, `nvidia-smi` and files under `/proc` and `/sys`. The command is `ssh -o BatchMode=yes -o ConnectTimeout=5 -T -- <host> sh -c '<script>'`, so it never asks for a password and gives up after 5 seconds without a connection. The script's output is read on the Mac; for `$mem` and `$cpu` it includes the host's processes, not only yours. A preview runs the same script as soon as the host is typed or picked, after the usual pause.
- `$ask`, `$img`, `$note`, `$todo` and `$tidy` send text to the AI vendor, only when you press ⏎ on them. What exactly is in [AI.md](AI.md).
- `$port` and `$kill` read your processes locally (`id`, `uname`, `ps`, `lsof`) and run `docker` for containers. `$port … @host` and `$kill … @host` run `id`, `uname`, `ps`, `lsof` or `ss`, `docker` and `kill` on that host, like the report commands over the same non-interactive SSH connection (one for the lookup, one to end), and end processes (and stop containers) only after the alert is confirmed, never with `sudo`. Nothing typed reaches the shell unquoted: the port is a number checked first, and the names of the processes to end were read from `ps` and are quoted. `$code` and URL commands only open a link; `$term` only opens a folder in the terminal app, or a script that runs `ssh` for a folder on a host.
- `$clip` runs `yt-dlp` with the link you typed, which downloads that part of the video from YouTube (or the site of the link), then `ffmpeg` on the Mac. Nothing else is sent. `$sound` only plays files on the Mac.
- A command file runs what you wrote in it. A `command` runs in your home folder with `/bin/zsh -c`.

## How it works

The protocol and the commands that need no AppKit are in `CortexCore/Sources/CortexCore/Commands/`; the app side is in `Cortex/Modules/Commands/`.

| File | Role |
| --- | --- |
| `Commands/Command.swift` | `Command` (a name, title, summary, argument, options, `runsOnHosts`, `verb` and `resolve`), `CommandArgument`, `CommandChoices`, `CommandSuggestions`. |
| `Commands/CommandOutcome.swift` | `CommandInvocation` (input, options, machine), `CommandOutcome` (`value`, `open`, `act`, `job`, `handoff`, with a `kind`), `CommandValue` and `OpenTarget` (with `verb`, `copyLabel` and `copyText`), and `CommandOutcome.keys(of:)`, the words for ⏎ and ⌥⏎. |
| `Commands/CommandAction.swift` | `CommandAction`, the adapter that runs a command as a `QuickAction` (see "Running through Actions"). |
| `Commands/Machine.swift` | `Machine` (`.local` or `.ssh(alias)`): its title, `named(by:in:)`, which checks the typed `@host` words against the aliases, and `run(_:)`, which runs a script with `sh` here or over SSH. `MachineShell` is that as a closure, so tests can answer for a host. |
| `Commands/CommandQuery.swift` | Splits the text after `$` into a word, an argument and, for a command that runs on hosts, its `@host` words. |
| `Commands/CommandCatalog.swift` | `builtIns` (macOS only), `rank(_:for:usage:)`, `problems(in:)` for duplicate names. |
| `Commands/CommandSuggestion.swift` | The suggestion lists (`.clips`, `.clipboardText`, `.choices`, `filter`) and `CommandArgument.input(from:choices:)`, which turns a field's text into the command's input or says what is wrong. |
| `Commands/KillCommand.swift`, `PortCommand.swift`, `Docker.swift`, `ProcessTools.swift` | `$kill`, `$port` and what they share: the scripts that list processes, find listeners (`lsof`, `ss`) and containers and end them on a machine, and the code that reads their output. Each takes a `MachineShell` and reads `CommandInvocation.machine`; the alerts perform on the machine they looked up. |
| `Commands/DiskSpaceCommand.swift`, `MemoryUsageCommand.swift`, `CPUUsageCommand.swift`, `GPUUsageCommand.swift`, `SSHHosts.swift`, `ReportTable.swift` | The report commands. `SSHHosts` reads the aliases, runs a script over SSH or locally (`Machine.run` picks one), and splits its output into `@@ name` sections. Each takes a `MachineShell` so tests can answer for the host, and reads `CommandInvocation.machine`; none matches aliases or words an unknown-host error itself. |
| `Commands/ClipCommand.swift`, `SoundCommand.swift`, `SoundLibrary.swift` | `$clip` (parsing what is typed, yt-dlp and ffmpeg), `$sound` and `sounds.toml` with its folder. A sound plays through `OpenTarget.play`, which the app hands to `SoundPlayer`. |
| `Commands/CommandSettings.swift` | `SettingsFileCommand` (a command with a settings file, which ⌘E opens) and `CommandSettings`: where the files are, reading one with its name and line in errors, writing the starter. |
| `Commands/FolderShortcuts.swift`, `CodeCommand.swift`, `CodeProjects.swift`, `TermCommand.swift`, `TerminalFolders.swift` | `$code` and `$term`. `FolderShortcuts` is the format they share (`scan` and `[name]` tables with a `path`, a `host` where allowed) and finding a shortcut or a path by what is typed. A terminal opens through `OpenTarget.openWith`, which the app hands to `NSWorkspace`. |
| `Commands/OpenCommand.swift`, `UUIDCommand.swift`, `TokenCommand.swift` | The other built-ins. |
| `Commands/UserCommand.swift`, `CommandFile.swift` | A command made from a TOML file, and the file that *Save as Command* writes. |
| `Modules/Commands/CommandsModule.swift` | The `CortexModule`: id `commands`, trigger `$`, order 32, requires `actions`. `static let prefix = "$"`. Collects the commands: built-ins, `CommandContributing` modules', then your files from `ActionsAPI`. |
| `Modules/Commands/CommandsAPI.swift` | `CommandContributing`. |
| `Modules/Commands/CommandsScope.swift`, `Views/CommandsView.swift`, `Views/CommandViews.swift` | The `$` scope (it also checks the typed `@host` and holds the `CommandResolution` of the selected command), the list and pane, the row (`$port 3000 @pi` in monospace) and the pane of a command that still needs its argument. |
| `Modules/Commands/CommandForm.swift`, `Views/CommandFormView.swift` | The form's state and view. |
| `Modules/Commands/CommandRefresh.swift` | `CommandRefresh`: resolves a shown value again every `refresh` and keeps the last good one when a lookup fails. |
| `Modules/Commands/CommandsSettingsView.swift` | The cheat sheet. |
| `Modules/Commands/Views/DiskSpaceView.swift`, `MemoryUsageView.swift`, `CPUUsageView.swift`, `GPUUsageView.swift`, `ReportViews.swift` | The panes of the report commands (`ReportPresenting`, which a command conforms to). |
| `Modules/Actions/ActionsAPI.swift`, `Views/ActionsView.swift` | What Commands may name of Quick Actions: `ActionsAPI` (`resolve`, `run`, `commandPane`), `CommandResolution`, `ReportPresenting`; and `CommandOutcomeView`, the pane drawn for an outcome (header, body, loading, error, notice). |

The module lists after Quick Actions and before AI in `Cortex/App/ModuleList.swift`. The palette's placeholder is built from the modules' triggers, so `$ commands` appears in it with no other change. The module names the Quick Actions module only through `ActionsAPI`, the Clipboard module through `ClipboardAPI` (see [ARCHITECTURE.md](../ARCHITECTURE.md)). The Host components `SuggestingTextField` and `ActionOptionControl` draw the form's fields, and `PaletteOverlay` (see below) is what puts it over the list.

## The two prefixes

| | `>` Quick actions | `$` Commands |
| --- | --- | --- |
| Input | What the palette finds (clipboard, Finder selection) or is handed (⌘K on a clip, a drop, Services, the selection hotkey). | What is typed after the name, or filled into the form. Never read from context. |
| Listed for an empty query | The actions that accept the current input. | Every command, by usage. |
| What ⏎ does | Runs the selected action on the input. | Carries out the command's outcome if everything required is filled in; otherwise opens the form. |
| Typical members | Format JSON, Uppercase, Convert to PNG, Proofread, Summarize | `$port 3000`, `$kill node`, `$ask …`, `$img …`, `$disk`, `$mem`, `$gh owner/repo`, `$deploy staging` |

Two guarantees follow:

- A `>` action always works on the input the pane shows. Nothing typed after `>` is ever its input.
- A `$` command never runs on anything that was not typed or chosen in its form. Context only ever appears as a suggestion, and a suggestion is taken with a keystroke.

A wrong clipboard in `>` gives a wrong result, visibly. In `$` nothing can run that was not typed or chosen.

## Decisions

- **A separate module with its own trigger.** The host gives each module one trigger and one scope, so `$` cannot live in the Actions module without changing the host contract for every module. Commands requires Actions, as AI does.
- **`>` gives up typed input.** Trigger words in `>` and an argument field made `>` read typed input, which is what `$` is for; with both, there would be two ways in. `>` keeps `matches`: a command may still appear there for context that is unmistakably meant for it (a copied port number), and then it runs on that input like any action.
- **Prompts are commands.** `$ask` and `$img` take a prompt, not a subject. Proofread and Summarize stay `>` actions, since their input is the text they work on. The `$ask` and `$img` forms suggest the clipboard text as the prompt, so asking about what was copied takes two keystrokes, never zero.
- **The typed text fills the main argument only.** The other settings of a command are options, set in the form and remembered per command. There is no flag syntax (`$img … --model`).
- **The host is not an argument.** `$mem pi` and `$disk pi:/mnt/usb` squeezed a host into the argument of each command, each with its own matching and errors. A host is where a command runs (`Machine`, in `CommandInvocation`), typed as `@pi` and checked once by the scope, so a command that runs on hosts only reads `invocation.machine`. It is not an option either: options are remembered per command, and a host from an earlier run must never be the one a later run goes to.
- **The form never pre-fills the main argument.** `$port` opens the form with the port field empty and `3000` listed under it when a recent clip looks like a port; ↓ ⏎ runs on it. An empty required field means ⏎ does nothing but mark the field.
- **The form is a palette overlay, not a window.** Like the snippet fill-in form, with the same panel and keys; a window would lose the keyboard flow and the previous app for pasting.
- **One TOML folder, one definition type.** A file with `trigger` is a command named by it, a file with `accepts` is an action, a file with both is listed in both.

## Reading the query

`CommandQuery` (a pure value in CortexCore) splits the text after `$` at the first whitespace into a `word` and, if anything follows, an `argument`. It is given the folded names of all commands (`SnippetSearch.fold`, as snippet keywords are). It has `isNamed` (the word is exactly a name) and `search` (what ranks the list: the word when it names a command, otherwise the whole text). `argument` is nil when only whitespace follows, so `$port ` is `$port`. It is also given which of those names run on hosts (`hostNames`). For those, every whitespace-separated word of the rest that starts with `@` is taken out of the argument and kept in `hosts` without the `@` (`disk /mnt/usb @pi` is the argument `/mnt/usb` and `hosts == ["pi"]`; `mem @pi` has no argument); the spacing of what is left is kept. A word with `@` inside (`a@b.com`) is not a host, and for a command that does not run on hosts `@word` stays in the argument. Whether the words name hosts is not the query's business: `Machine.named(by:in:)` does that, in the scope.

| Typed | Word is a command name? | List | Pane | ⏎ |
| --- | --- | --- | --- | --- |
| `$` | – | Every command, by usage, then catalog order | The selected command's summary and what it takes | Form, or run if it takes nothing |
| `$po` | no | Commands matching `po` in name, title or keywords | The same | The same |
| `$port` | yes, no argument | Kill Process on Port first, then the other matches of `port` | Summary, "Port: a number from 1 to 65535, required", "⏎ fills it in" | Form, port field empty, suggestions listed |
| `$port 3000` | yes, argument `3000` | The same | The header `$port 3000`, then what listens on 3000, after a 150 ms pause (an `act`) | Hint "Kill…": asks to confirm, then kills; ⌥⏎ beeps |
| `$port 3000`, nothing listening | yes | The same | "Nothing is listening on port 3000 (only your own processes are checked)", plainly with an info symbol (a notice) | Beeps |
| `$port abc` | yes | The same | The resolve error, in red | Beeps |
| `$ask why is the sky blue` | yes | Ask AI first | The plan of the job: "Sends the text to OpenAI (gpt-6-luna) and pastes the answer." Nothing is sent yet. | Hint "Start": starts the job; ⌥⏎ starts it and copies the answer |
| `$uuid` | yes, takes nothing | Generate UUID first | A new UUID (a value) | Hint "Paste": pastes the UUID shown; ⌥⏎ copies it |
| `$mem` | yes, takes nothing | Memory Usage first | The memory, drawn, and refreshed every 2 s while it is selected | Pastes the table as shown at that moment |
| `$code cortex` | yes | Open in VS Code first | The `vscode://` link | Hint "Open in VS Code"; ⌥⏎ "Copy link" copies the link |
| `$disk` | yes, optional volume | Disk Space first | The startup volume | Pastes the table (⇥: the form, the volumes listed, ↓ picks one) |
| `$disk Macintosh HD` | yes | The same | The analysis of that volume | Pastes the table |
| `$port 3000 @pi` | yes, argument `3000`, host `pi` | Kill Process on Port first | "Loading Kill Process on Port on pi…", then what pi's user has listening on 3000 | Hint "Kill…": asks to confirm ("Kill node on pi?"), then kills |
| `$mem @pi` | yes, host `pi` | Memory Usage first | The header `$mem @pi` with an "on pi" tag, "Loading Memory Usage on pi…", then pi's memory, refreshed | Pastes the table |
| `$disk /mnt/usb @pi` | yes, argument `/mnt/usb`, host `pi` | Disk Space first | The file system `/mnt/usb` is on, on pi | Pastes the table |
| `$mem @nas` | yes, no such host | The same | The error in red, listing the hosts | Beeps |
| `$kil node` | no | Nothing matches both words | "No matching commands. Type a command's name, then its input: $port 3000" | Nothing |

Rules:

- Only an exact name makes the rest an argument. A partial word searches, and the argument is then part of the search. There is no completion key: ⏎ on a partly typed command opens its form, which names the command.
- The typed argument is only the named command's input. With `$kill node`, Kill Process on Port (listed second, because it has the keyword `kill`) gets no argument and shows what it takes. Typing the argument keeps the selection.
- Ranking is `ActionCatalog.rank` on the word, with a command's name scoring like a keyword (exact 110, prefix 70); `CommandCatalog.rank` then moves the named command to the front.
- A `choice` argument matches typed text against the choices' titles, then values, ignoring case, then the only title that starts with it. No match is the resolve error (`“Floppy” is not a mounted volume. Mounted: …`). On a host `$disk` takes a path instead, which is not matched against anything.
- A path argument takes what `ActionInput.typed` reads as files: absolute or `~/` paths, quoted like shell words, or one path with spaces as copied. Anything else is text, and the command says what is wrong.
- The 150 ms pause is `CommandsScope.previewDelay`. A command that takes nothing is resolved at once.
- Typed input is never sensitive.

## The form

⏎ on a command whose required fields are not all filled opens the form, and so does ⇥ on any command with fields. It replaces the list and pane (a `PaletteOverlay`) under the search field, which keeps the query but is disabled while the form shows.

```
┌──────────────────────────────────────────────────────────┐
│ $port                                                    │   search field, disabled
├──────────────────────────────────────────────────────────┤
│ ⦸  Kill Process on Port                                  │   symbol, title
│    Ends what listens on a port: TCP listeners and UDP    │   summary
│    sockets, or the container publishing it.              │
│                                                          │
│    Port      [ 3000                       ]  required    │   the argument field
│              ▸ 3000        Clipboard                     │   suggestions
│                8080        History · yesterday           │
│                                                          │
│    Grace     ( 3 s | 10 s )                              │   options, if the command has any
│    ─────────────────────────────────────────────────     │
│    Kill node?                                            │   the outcome, as the field changes
│    PID 4242, alex, TCP *:3000                            │
├──────────────────────────────────────────────────────────┤
│ ⏎ Kill…   ⇥ Next field   esc Back                        │   hints bar
└──────────────────────────────────────────────────────────┘
```

(The Grace option is an illustration; `$port` has no options.)

- **Fields.** The argument first, marked "required" or "optional", then the Host field for a command that runs on hosts, then one control per option (`ActionOptionControl`: a segmented choice, a number or a short text field). The argument field has focus when the form opens. ⇥ and ⇧⇥ move between fields when there are several. A segmented option never takes focus: ⇥ outlines it and ←→ change it.
- **Host.** A segmented choice like an option: This Mac first, then the aliases of `~/.ssh/config` (read whenever the form opens; "none in ~/.ssh/config" when there are none). A form starts at This Mac when it is made, whatever the last run used. Each time the list opens it (⇥ or ⏎), the field follows the query: a typed `@pi` (`$mem @pi`, ⇥) fills it in, and without one, or with a host that is not valid (the pane already said so), it is This Mac, also for a form kept from before in the same palette session, so `$kill node @pi`, Esc and `$kill node`, ⇥ does not run on pi. Its other values (the argument as edited, the options) stay as they were left. It is not an option: it is never stored, and the palette hiding drops it with the form. The outcome, the run and the progress card (`$disk /mnt/usb @pi`) use the picked host, and an outcome resolved for another host is not the form's. For `$disk` the argument follows the host: "Volume" with the volumes as suggestions on This Mac, "Path" with no suggestions on a host.
- **Kinds of argument field.** `text`: one line. `prompt`: several lines (`$ask`, `$img`, `$note`); ⇧⏎ inserts a line break, ⏎ still runs. `number`: runs only on a whole number in range. `path`: what is typed has to be an existing file or folder (`~/` allowed; several as shell words), and a file dropped onto the palette while the form shows fills it, typed as `~/…` and quoted where the shell would need it. `choice`: a list to pick from; typing filters it, ↑↓ move, and the field shows the highlighted choice. A choice that allows paths (`$code`, `$term`) takes an existing file or folder too.
- **Suggestions** are listed under the argument field ("Suggestions"). ↓ from the field moves the highlight into them and puts the highlighted value into the field; typing filters them; ↑ past the first goes back to what was typed; a click does what ↓ does. A suggestion is only ever a value in the field, which ⏎ then runs on.
- **Outcome.** The pane under the fields is the one the list shows (`ActionsAPI.commandPane` with the header left out, since the fields show it): the command is resolved after the 150 ms pause whenever a field changes (at once when it takes nothing), and the pane shows the outcome, whatever its kind. A value that asks for it is refreshed while the form shows it (see "Live refresh"). The resolve error is shown in red, a notice plainly, and ⏎ beeps. A field that is not valid (not a port number) shows a red message under the fields, for example "Port: a whole number from 1 to 65535".
- **⏎** runs when every required field is valid. The overlay closes, the palette closes and the result is delivered as from the list. ⌥⏎ is the second step of the outcome shown, as in the list. The hints bar follows the outcome: "Run" and "Run and copy" until the command is resolved on what the fields hold, then its own words ("Paste", "Copy"; "Open in VS Code", "Copy link"; "Kill…"; "Start", "Start and copy"; "Pick Colour"), and ⌥⏎ beeps where there is no hint for it. On an empty required field ⏎ outlines the field in red ("Fill in the port first") and does nothing else.
- **Option values are remembered when the form runs**, not while typing, so Esc leaves them as they were.
- **Esc** goes back to the list with the query as it was. A second Esc closes the palette.
- **Values are kept** while the palette is open: `$port`, ⏎, type `30`, Esc, ⏎ again shows `30` still there. When the palette hides, the forms are dropped and their lookups cancelled.

`CommandForm` (`@Observable`) holds the state: the command, the argument field (`SuggestingFieldState`: what was typed and which suggestion is highlighted), the machine, the option values, the suggestions and choices once loaded, the `CommandResolution` and its task, its `CommandRefresh` and the `hints` for the bar (the overlay's `currentHints`). `CommandsScope` keeps the forms by command ID until `clear()`. `submit()` returns the input and the resolution to use (nil when it is not there yet: the run resolves again), or nil altogether: `.missing` marks the field, `.invalid` and a failed resolution refuse.

## Suggestions

A command's argument declares where its form may suggest values from (`CommandSuggestions`):

| Case | Where from | Used by |
| --- | --- | --- |
| `.none` | Nothing | `$kill`, user commands without `matches` |
| `.clips(matching: pattern)` | The pasteboard, then the recent text clips, whose whole trimmed text matches the regular expression. At most five (`CommandSuggestion.clipLimit`), newest first, without duplicates. | `$port` with `^:?[0-9]{1,5}$`, `$open` with `^(/\|~/)[^\n]*$`, user files through `matches` |
| `.clipboardText` | The pasteboard's text, if there is one, as one entry. | `$ask`, `$img`, `$note`, `$todo` |
| `.choices` | The argument's own choices. A `choice` argument always lists its choices, whatever it declares. | `$disk` (on this Mac), `$code`, `$term`, `$sound` |

Each entry shows the value (its first line, truncated) and where it is from: "Clipboard" (with the number of characters when it is long), "History · 2 min ago" or nothing for a choice. For a `number` argument a clip becomes its number: `:3000` is suggested as `3000`, so it passes the number check.

The form loads suggestions when it opens (`CommandForm.load`), once per form. The pasteboard is read through `ResolvedActionInput.pasteboard()` and left out when it is sensitive. The history comes from `ClipboardAPI.recentTexts(limit:)`, which looks through the newest 50 text clips and leaves out the sensitive ones in the query itself. Without the Clipboard module the closure returns nothing and only the pasteboard is suggested. Both sources are `CommandSuggestionSources`, so tests can replace them.

## The command protocol

A command is three things, each decided once: what you type (its argument and options), where it runs (this Mac, or a host: `Machine`) and what ⏎ does (its *outcome*). The outcome, not the command, decides the preview, the hints, the confirmation, the progress and the delivery.

In `CortexCore/Sources/CortexCore/Commands/Command.swift`:

```swift
public protocol Command: Sendable {
    /// Stable across launches: usage counts and remembered options are stored under it.
    var id: String { get }
    /// The word after `$`: "port". Lowercase, no whitespace, unique among all commands.
    var name: String { get }
    var title: String { get }
    /// One sentence for the pane and the form.
    var summary: String { get }
    var symbol: String { get }
    var keywords: [String] { get }
    /// The main input: what is typed after the name, or the form's first field.
    /// nil: the command takes none.
    var argument: CommandArgument? { get }
    /// The form's other fields, remembered per command.
    var options: [ActionOption] { get }
    /// Whether `@host` and the form's Host field are offered.
    var runsOnHosts: Bool { get }
    /// What ⏎ is called in the hints where the outcome does not say it
    /// ("Open in VS Code", "Pick Colour"); nil: the outcome's own.
    var verb: String? { get }
    /// Sends its input to an online service: never run on sensitive input.
    var isRemote: Bool { get }
    /// The argument when it runs on a machine; by default `argument`.
    func argument(on machine: Machine) -> CommandArgument?
    func accepts(_ input: ActionInput) -> Bool
    /// Whether `>` offers it on this context input; by default never.
    func matches(_ input: ActionInput) -> Bool
    /// Cheap and side-effect free; called while the command is selected.
    func resolve(_ invocation: CommandInvocation) async throws -> CommandOutcome
}

public struct CommandInvocation {
    public var input: ActionInput          // the argument: .text, .files or .none
    public var options: ActionOptionValues
    public var machine: Machine            // .local, or .ssh(alias), already checked against ~/.ssh/config
}
```

A `Command` is not a `QuickAction`: it never runs. Its `resolve` returns one of five outcomes (`CommandOutcome.swift`), each with a `kind` (`value`, `open`, `act`, `job`, `handoff`):

| Outcome | Holds | Pane | ⏎ | ⌥⏎ | Progress | Commands |
| --- | --- | --- | --- | --- | --- | --- |
| `.value(CommandValue, refresh:)` | Text, secret text, a report (`ActionReport`) or an image; `refresh` says how often it is resolved again while it is shown | The value (text, a report view, an image) | Paste: exactly what is shown | Copy | No | `$uuid`, `$token` (secret), `$mem`, `$cpu`, `$gpu` (refresh every 2 s), `$disk` |
| `.open(OpenTarget)` | A `url`, a file to `reveal` in Finder, a file `openWith` an app, or a sound to `play` | What opens and with what | A verb ("Open in VS Code", "Show in Finder", "Play") | Copy link or path | No | `$code`, `$term`, `$open`, `$sound`, user commands with a `url` |
| `.act(ActionConfirmation)` | What is affected, and `perform` | The question, with the processes or containers listed | The confirming button and "…" ("Kill…"): shows the alert, then performs | – | While it performs | `$port`, `$kill`, user commands with `confirm = true` |
| `.job(plan:, run:)` | A sentence or the line to run, and `run(ActionContext)` | The plan | Start: in the background | Start and copy | The progress card | `$clip`, `$ask`, `$img`, `$note`, `$todo`, `$tidy`, user shell commands |
| `.handoff(description:, run:)` | What happens next, and `run` | The description | The command's `verb` ("Pick Colour", "Capture Text"): hands over | – | No | `$color`, `$ocr` |

`CommandValue.secret` replaces `hasSensitiveResult`: it is pasted and copied like text, and recorded as a sensitive clip. A value's `refresh` makes the scope and the form resolve again while it is shown ("Live refresh"). `CommandOutcome.keys(of:)` gives the words for ⏎ and ⌥⏎ ("The hints"); `OpenTarget.copyText` is what ⌥⏎ copies of something that opens.

**Resolving is cheap and changes nothing.** The scope calls `resolve` while the command is selected: at once for a command that takes nothing, after the 150 ms pause for typed input. Looking things up is fine when it is quick and previewed anyway (`$port` runs `lsof`, `$mem` reads `vm_stat`, `$code` reads `projects.toml`). Anything slow or with an effect goes inside the outcome, in `perform`, `run` or the handoff: a download (`$clip` parses and describes the cut in `resolve`, and downloads in `run`), a request to an AI vendor (`$ask`, `$img`, `$note`, `$todo` and `$tidy` resolve to a job whose plan says what is sent to whom, and contact nobody before ⏎), ending a process, starting the eyedropper. `resolve` throws a `QuickActionError` for what is wrong with the input; that is the pane's error, and ⏎ beeps. Nothing to do is not offered as an empty question but is no failure either: it throws `QuickActionError.notice(…)` (`$port 3000` with nothing listening), which the pane draws plainly instead of in red ("Nothing to do").

```swift
public struct CommandArgument {
    public enum Kind {
        case text
        case prompt                        // several lines; ⇧⏎ breaks a line
        case number(ClosedRange<Int>)
        case path                          // an existing file or folder; resolves on .files
        case choice(CommandChoices)        // one of a list loaded when the form opens
    }
    public var title: String               // "Port"
    public var placeholder: String         // "3000": in the row and the empty field
    public var kind: Kind
    public var isRequired: Bool
    public var suggestions: CommandSuggestions
}
```

`CommandChoices` has an `id`, a `load` closure, and `allowsPaths` (an existing file or folder is taken too, as typed text: `$code ~/notes.md`). `CommandChoices.match` finds the choice typed text means, and `CommandChoices.pick` says why none fits (`$code`, `$term`, `$sound`).

Defaults in an extension:

- `summary` is empty, `keywords` and `options` are empty, `argument` is nil, `runsOnHosts` and `isRemote` are false. `argument(on:)` is `argument`; `DiskSpaceCommand` overrides it with a path for a host.
- `accepts` is derived from the argument: with no argument only `.none`; `.none` also when the argument is optional; `.text` (not blank) for every kind but `path`; `.files` for `path`. A number or a choice is accepted as any text, and a value that is not valid is the resolve error.
- `matches` is false, so `>` does not offer the command. Override it for context that is unmistakably meant for the command (`PortCommand`: a copied port number; `OpenCommand`: a copied path that exists).
- `usage` is `name` plus the argument's placeholder (`port 3000`), as the row shows it.
- `input(typed:)` turns what followed the name into the input: a `path` argument through `ActionInput.typed`, anything else as `.text`, nothing as `.none`.

The argument arrives in `resolve` as `invocation.input` (`.text`, `.files` or `.none`), the options in `invocation.options` and, for a command that runs on hosts, the machine in `invocation.machine` (`Machine`: `.local` or `.ssh(alias)`). Such a command runs its script with the `MachineShell` it was given, never matching aliases or writing "not a host" errors itself. `ADDING_ACTIONS.md` ([Adding a command](../ADDING_ACTIONS.md#adding-a-command)) is the checklist for a new built-in command; this section describes the protocol it follows.

`CommandCatalog` has the built-in commands (`KillCommand`, `PortCommand`, `DiskSpaceCommand`, `MemoryUsageCommand`, `CPUUsageCommand`, `GPUUsageCommand`, `OpenCommand`, `CodeCommand`, `TermCommand`, `ClipCommand`, `SoundCommand`, `UUIDCommand`, `TokenCommand`), `rank(_:for:usage:)`, and `problems(in:)`. A command whose folded name an earlier one has is a problem and is left out: "“kill” is the name of a built-in command", or "“GH” is already the trigger of gh.toml" when the earlier one is a file's.

## The scope

`CommandsScope` is the `PaletteScope` for `$`. It is `@MainActor @Observable`.

- `list` is a `ResultList<any Command, String>`; `query` is the current `CommandQuery`; `resolution` is what the selected command resolved to on what was typed, or why it did not (`CommandResolution`: the command's ID, the input, the options, the machine and a `Result<CommandOutcome, QuickActionError>`); `machine` is the host the query names, checked in `search` with `Machine.named(by:in:)` against `SSHHosts.configured` (injectable as `hosts:`), or `hostProblem` says why it is none. `machine(for:)` is that for the named command and This Mac for the others.
- `search(_:)` builds the `CommandQuery` from the names of all commands (and which of them run on hosts), ranks through `CommandCatalog.rank` with the usage counts from `ActionsAPI`, and resolves the selected command. The selection is kept while the argument is typed by passing the folded word, prefixed with a marker character, as the list's query (`ResultList.replace(with:query:)`).
- `input(for:)` is the typed argument for the named command and `.none` for the others.
- `choose(_:copyOnly:)` is ⏎: `run` if the command `accepts` the input (including `.none`), otherwise `openForm`. `run` beeps when the command does not accept the input, did not resolve on this input (the pane says why, as an error or a notice), or ⌥⏎ was pressed on an outcome with no ⌥⏎ hint (an act or a handoff). The form's ⏎ is `run(_ form:)`, which saves the options through `ActionsAPI.setOptions` and delivers.
- `activationHints` are the selected command's `CommandOutcome.keys(of:)` (`shownOutcome(of:)`: the resolution for the typed input and host) followed by ⌘1–9 "Run", or the generic "Run and paste" and "Run and copy" when there is none.
- `refresh` is a `CommandRefresh`: `updatePreview` follows each new resolution that is a value with a `refresh`, and stops it for another command, input, host or no resolution; `didLeave`, `clear` and `openForm` stop it, and the form's Esc starts it again (`PaletteOverlay.dismissed`, which the model calls whenever an overlay goes, not only on Esc: another module opening, the palette shown again or hidden). `refresh.interval` replaces the value's interval (tests).
- `typed(_:)` is the command as typed for the pane's header.
- `keys` has ⇥ ("Fill in", "Host" or "Options") when the selected command has an argument, runs on hosts or has options.
- `openForm(for:)` reuses the form of that command if the palette still has one, fills in what was typed (argument, and the host: the typed one or This Mac), loads suggestions and presents the overlay: the form's body, the hints (`currentHints`: those of the form's outcome, ⇥ Next field when there are several fields), `escape: .dismiss`, `dismissed` (the form stops refreshing, the list resumes), `move` (the arrow keys go to the form first) and `dropFiles` for an argument that takes paths. The host offers a drop to the overlay before the modules, so a form takes a file although Quick Actions comes first in the module list.
- The resolution runs `ActionsAPI.resolve` on the machine after `previewDelay` (at once for a command that takes nothing), for every command that accepts the input: there is no "instant or not". A `hostProblem` is shown at once as the resolve error, without resolving anything. While a new argument is typed, the previous result stays until the new one is there, unless it was made on another machine; `loading(for:)` then names what is loading, which `commandPane` draws as a dimmed body with a progress indicator. ⌥⏎ pressed while the pane is still resolving waits for it (`runTask`, cancelled by further typing, leaving and Esc) and then runs again with the resolution, so the check for a second step looks at the outcome that is carried out. The pane is `ActionsAPI.commandPane`: the header, then the outcome drawn by its kind, or the error in red, or the notice, with "Loading Memory Usage on pi…" while it resolves, and the "Couldn't refresh" line when a refresh failed.
- `commandsDidChange()` lists again when your files changed; the module registers it once with `ActionsAPI.onUserFilesChanged` and ignores calls while it is off.
- `clear()` (the palette hid or the module stopped) cancels and drops the forms, the refresh, the list and the resolution.

## Running through Actions

`CommandsModule` has no runner of its own. It uses the `ActionsAPI` of the Quick Actions module:

```swift
func resolve(_ command: any Command, input: ActionInput, options: ActionOptionValues?, machine: Machine) async -> CommandResolution?
func run(_ command: any Command, input: ActionInput, machine: Machine, resolution: CommandResolution?, delivery: ActionDelivery, summary: String?) async -> Bool
func options(for command: any Command) -> ActionOptionValues
func setOptions(_ values: ActionOptionValues, for command: any Command)
var usage: [String: ActionUsage] { get }
var userCommands: [UserCommand] { get }
func onUserFilesChanged(_ handler: @escaping @MainActor () -> Void)
func commandPane(for command: any Command, typed: String?, resolution: CommandResolution?, loading: String?, refreshProblem: String?) -> AnyView
```

All of these forward to `ActionsService`. `commandPane` returns `CommandOutcomeView` as an `AnyView`, so `$` shows outcomes without naming the Actions module's views. `CommandResolution`, `ActionDelivery` (paste into an app, only copy, replace the selection) and `ReportPresenting` (a `Command` that draws its reports) are declared in `ActionsAPI.swift` so that Commands may name them.

**The adapter.** `CommandAction` (in CortexCore) is a `QuickAction` made from a command and, normally, the outcome it resolved to. It keeps the command's `id`, so the usage counts and remembered options in the `quickActionUsage` and `quickActionOptions` defaults carry over, and maps the outcome to the output Quick Actions already delivers:

| Outcome | `ActionOutput` | Then |
| --- | --- | --- |
| `.value` text, secret, report, image | `.text`, `.text` (recorded as a sensitive clip), `.report`, `.image` | Pasted (⏎) or copied (⌥⏎) |
| `.open` url, reveal, openWith, play | `.open`, `.reveal`, `.openWith`, `.play` | Done by the app |
| `.act` | `.confirm` | The alert; the confirmed step runs as a job and delivers what `perform` returns |
| `.job` | what `run` returns | `isInstant` is false: a job with the progress card, its output delivered as an action's is |
| `.handoff` | `.handled` after `run` | Nothing to paste: the hand-over delivers the result itself |

`ActionsService.run(_ command:…resolution:)` makes the adapter. A run uses exactly the outcome the pane showed: when `resolution` is for the same command, input, options and machine, its outcome is carried out without resolving again (`$uuid` pastes the UUID that was shown, and `$ask` has not contacted the vendor before ⏎). Otherwise (the form was submitted before its resolution finished, or the options changed) the command is resolved first; one that cannot resolve is a failed run, reported like any failed action (a notification; a notice is posted as an ordinary one with its sentence). A copy (⌥⏎) of an `.open` outcome copies its link or path (`OpenTarget.copyText`) as a normal clip instead of opening it. The summary is what the progress card shows: `$port 3000`, or `$disk /mnt/usb @pi`, from `CommandsModule.prefix + name + " " + argument + " @" + host`. `CommandsScope.deliver` calls `palette().closeAndDeliver(.paste(.plainText) or .copyOnly)` with a closure that runs `actions.run(..., delivery: .paste(target) or .copy, summary:)`.

An adapter made without an outcome resolves when it is run; a notice it resolves to ("Nothing is listening on port 3000") is `.done` with that sentence, so `>` posts it as an ordinary notification. That is how `>` offers a command: `ActionsService.builtIns` lists every built-in command as a `CommandAction`, and `matches` decides which are offered on the context input (`$port` on a copied port, `$open` on a copied path), always on this Mac. Such an adapter is `isInstant`, so `>` previews it like any action. `shortcutActions` leaves out every `CommandAction`.

Commands run on typed input, which is never marked sensitive. `isRemote` (the AI commands) works as for actions: a remote command does not run on sensitive input. A secret value is `hasSensitiveResult` on the adapter.

## Commands from other modules

A module conforms to `CommandContributing` (`CommandsAPI.swift`) and lists its commands in `contributedCommands`. `CommandsModule` asks on every listing, so the commands of a module that is switched off disappear and Commands names no module. AI contributes `$ask` and `$img`; Knowledge contributes `$note`, `$todo` and `$tidy` while AI is on (it sends through `AIAPI`, and hands its proposal to the palette for confirmation instead of pasting); Color Picker contributes `$color`; Text Recognition contributes `$ocr`. Each is an ordinary `Command`: AI and Knowledge resolve to a job (the plan names the vendor and the model; the vendor is contacted only when the job runs), Color Picker and Text Recognition to a handoff.

The order is built-ins, other modules', your files. `CommandsModule.commands(in:)` leaves out a command whose name an earlier one has, so a built-in or a module's name beats a file's. `ActionsService.reservedCommands` (the built-ins and the contributed commands) is read whenever the folder is loaded, so switching AI on later does not re-check your files until the folder changes; the list leaves the clashing file out anyway.

The AI commands are `AICommand` in CortexCore. `$ask` and `$img` have a `prompt` argument that suggests the clipboard text; `$img` has a Model option listing the image model set in Settings first and then the vendor's others. See [AI.md](AI.md).

## What `>` loses

The Quick Actions module is for input that comes from context, in every way in:

- `ActionListing` has only `.context` and `.handedIn`. The query after `>` is always a search. There are no trigger words (`>port 3000` finds nothing) and no argument field.
- `ActionsScope` has no typed input: its input is the handed-in input or the context, and every listed action accepts it.
- `QuickAction` has no `trigger`, `inputSources` or `usage`. `ActionCatalog.builtIns` lists actions only. `ActionsService.shortcutActions` is every action that is not a `CommandAction`.
- `>` still offers a command through `matches` (as a `CommandAction`): Kill Process on Port on a copied `3000` or `:3000`, and Open in Finder on a copied path that exists or a copied file. They then run on that input like any action, on this Mac, shown with the source "Clipboard". Kill never matches. A user file with both `trigger` and `accepts` is offered in `>` for text only when its `matches` pattern fits the text (see "Your own commands").
- The empty state of `>` says how to type input: "To type an input, use $ commands."

## Your own commands

Commands are defined in the TOML files of the Quick Actions folder, `~/.config/cortex/actions/`: the format, placeholders and rules about running a command are in [ACTIONS.md](ACTIONS.md). The keys that matter here:

| Keys | Listed as |
| --- | --- |
| `accepts`, no `trigger` | A `>` action. |
| `trigger`, no `accepts` | A `$` command named by the trigger. `argument` (`required`, `optional` or `none`) says what it takes: required by default when `{argument}` is used, otherwise none. `example` is the argument's placeholder (`$gh owner/repo`) and the empty field's text; `matches` is a regular expression for the form's clip suggestions (`.clips(matching:)`); `confirm = true` asks first. |
| both | Both: in `$` under the trigger, and in `>` when the context input fits `matches`. Without `matches` the file is not offered in `>` for text. |

Give `argument` or `accepts`, not both. The trigger is one word, typed as `gh` (a leading `$` is accepted and dropped). It has to be unique among the built-in commands, the contributed ones and the earlier files (files load sorted by name, and a clash is reported as a problem in Settings → Quick Actions, with that file left out of `$`).

```toml
# ~/.config/cortex/actions/github.toml
name = "GitHub Repository"
trigger = "gh"                          # typed after $: $gh apple/swift
url = "https://github.com/{argument}"   # opened in the default browser or app
example = "owner/repo"                  # optional: shown as $gh owner/repo, and in the form's empty field
# matches = "^[\\w.-]+/[\\w.-]+$"       # optional: the form suggests copied text like this
# keywords = ["github"]                 # optional: more search words
# symbol = "link"                       # optional SF Symbol (default: link, or terminal for commands)
```

```toml
# ~/.config/cortex/actions/deploy.toml
name = "Deploy"
trigger = "deploy"
command = "~/app/deploy.sh {argument}"  # /bin/zsh -c in your home folder, Homebrew on the PATH
argument = "optional"                   # required, optional or none; default: required if {argument} is used
confirm = true                          # optional: ask in an alert first
# output = "text"                       # text: paste standard output; none (default): show it in a notification
```

```toml
# ~/.config/cortex/actions/tracking.toml
name = "Track Parcel"
trigger = "track"                       # $track 1Z999AA10123456784
accepts = ["text"]                      # also offered in > for a copied tracking number…
matches = "^1Z[0-9A-Z]{16}$"            # …that looks like this (and suggested in the $track form)
url = "https://www.ups.com/track?tracknum={argument}"
```

`{argument}` is everything typed after the trigger or filled into the form, percent-encoded in a URL, and passed to a command like the other placeholders (also as `$1`). A file that takes only files gets a path field. A `url` resolves to an `open` outcome: the pane shows the link and ⏎ opens it (with `confirm = true`, an `act` that asks "Open …?" first). A `command` resolves to a `job`: nothing runs until ⏎, and the pane shows the line it will run, with the text quoted in place (for a file that is also a `>` action, with its `{input}` still in it). With `confirm = true` it is an `act` instead: the pane shows the same line as the question, and the command runs only after the alert is confirmed. A command file's standard output is shown in a notification (its last 500 characters), or pasted with `output = "text"`.

`UserActionLibrary.load` returns `actions: [UserAction]` and `commands: [UserCommand]` from the same definitions. A `UserCommand` has the same ID as the file's `UserAction` (`user.<file name>`), so a file with both counts its uses once. Its argument is `.text` when the file takes text, `.path` when it takes only files, and none when it takes neither; its suggestions come from `matches`. It is a `Command` like the built-ins: `resolve` builds the outcome and runs nothing.

*Save as Command* in `>` writes such a file (`CommandFile`): the selected text is the `command`, the name you give is the `trigger`, and the file is `<trigger>.toml`, never over an existing one.

## Not supported

- Flags for options on the command line (`$img a cat --model …`). The form covers options.
- A Shortcuts action for commands.
- Completing a partly typed name with ⇥. ⇥ opens the form instead.
- A `>` action "Ask AI about this". The clipboard suggestion in the `$ask` form does the same in two keystrokes.
- Top folders by size in `$disk`, which would take minutes.

## Tests

- `CortexCore/Tests/CortexCoreTests/Commands/`: `CommandQueryTests` (the parsing, including the `@host` words), `CommandSuggestionTests` (the suggestion lists, field validation), `CommandOutcomeTests` (the outcome kind of every built-in, the reports' refresh, the words for ⏎ and ⌥⏎ per outcome and the link or path ⌥⏎ copies, notices from `$port` and `$kill` and their plain-error counterparts, the adapter mapping each outcome and a notice to `.done`, one resolved outcome run without resolving again, `>` offering `$port` and `$open` through `matches`), `CommandTests` (`BuiltInCommandTests` for IDs and names, `OpenCommandTests`, `PortCommandTests`, `KillCommandTests`), `HostCommandTests` (`$port` and `$kill` over canned Linux and Mac hosts: `ss` and `lsof` output, host-named alerts and messages, containers and which of them publish the host port, `sshd` and PID 1 never offered, errors, the notification text), `ProcessToolsTests` (listing from canned `id`/`ps` output of Linux and macOS, the end script's output and quoting, every script as valid `sh`, and a real run on this Mac including the PID-reuse guard), `DiskSpaceTests`, `MemoryUsageTests`, `CPUUsageTests`, `GPUUsageTests`, `SSHHostsTests`, `MachineTests` (the title, `named(by:in:)` with its errors, running a script here), `CodeCommandTests`, `ClipCommandTests`, `SoundCommandTests`, `UserCommandTests` and `CommandFileTests`. `AITests` checks that `$ask` and `$img` send nothing until their job runs. System-reading code takes its input as a parameter (`DiskSpaceCommand(volumes:)`, a `MachineShell`; the commands read `invocation.machine`), so the tests feed samples and do not assert this Mac's numbers.
- `CortexTests/Modules/Commands/`: `CommandsScopeTests` (listing and ranking, the exact-name rule, the argument resolved after the pause and only once, an outcome of every kind in the pane, ⏎ carrying out the outcome that was shown without resolving again and resolving once when none was there, ⌥⏎, beeps, the job summary, `@host` picking the machine (also for `$kill` and `$port`), resolving on it and showing the host in the row and the card, a host that is not in `~/.ssh/config` or more than one as the resolve error, a resolution only reused for the same machine, input and options, user files listed and reloaded) and `CommandOutcomeUITests` (the hints per outcome kind in the list and in the form, generic hints until resolved or when it failed, ⌥⏎ copying the link or path of an open outcome as a clip and beeping for an act, a handoff and a failed resolve, ⌥⏎ pressed before the pane has resolved (in the list and the form) waiting and then beeping or copying, a result of earlier input marked as pending, a kept form's host following the query, the live refresh replacing the value on schedule without a loading state, never overlapping, and stopping on leave, clear, another selection, other text and another host, a failed refresh keeping the last value, ⏎ pasting the value shown, the form's own refresh and the list resuming, notices not being errors and beeping, the notification a notice makes from `>` or a run, the header's text, every kind of outcome rendering in the pane) and `CommandFormTests` (opens empty, suggestions in order and without sensitive clips, ↓ puts a suggestion into the field, an empty required field runs nothing, a failed resolution beeps, options are remembered on run, Esc keeps the values, `clear` drops them, the Host field: after the argument, starting at This Mac, filled in by a typed `@pi`, moved with ←→, the argument following the host, the host passed to the run and never remembered). `KnowledgeFilingCommandTests` and `ColorPickerTests` check that `$note`, `$todo`, `$tidy`, `$color` and `$ocr` resolve without sending or starting anything. `ModuleLifecycleTests` checks that the AI and Color Picker commands follow their module's switch, and `PaletteRouterTests` and `ModuleListTests` know the `$` trigger.
- Manual: [MANUAL_TESTS.md](../MANUAL_TESTS.md) M23 (every command in real use, the form, your own files, Quick Actions off), M18 (a command file in the one format), M24 (`$ask` and `$img`) and M26 (`$color`).
