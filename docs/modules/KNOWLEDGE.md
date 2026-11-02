# Knowledge

The Knowledge module is a place for notes, skills and to-dos, kept as plain Markdown files in `~/.config/cortex/knowledge/`, one folder per project. Cortex indexes the files; any editor, script or agent can read and write them, and Time Machine or git back them up as they are. In the palette, `?` finds and captures notes and `!` keeps to-dos. Capturing takes one trigger, the text and ⏎; where it belongs can be decided later, by you, by an AI model (`$note`, `$todo`, `$tidy`) or by an agent through the MCP server.

## Using it

Open the palette and type `?` for notes, skills and projects, or `!` for to-dos. A trigger at the start of the query picks the scope; put a backslash in front (`\?`) to search the clipboard history for a text that starts with it.

**`?` in the palette.** The details of searching are under [The palette](#the-palette).

| Key | Does |
| --- | --- |
| `?` alone | Lists the projects (the inbox first), then the ten most recently updated items. |
| `?potrace` | Full-text search over every project and kind, best match first. |
| `?@server docker` | Narrows to a project: `@` and the start of its folder name or its name. |
| `?#cli` | Narrows to a tag (the start of the tag). |
| ⏎ | On an item: pastes its body. On a project: searches in that project. |
| ⌥⏎ | Copies the body without pasting. |
| ⌘1 to ⌘9 | Pastes the selected item's fenced code blocks (the preview lists them). |
| ⌘E | Edits the item in Cortex's editor window. |
| ⌘⏎ | Opens the file in VS Code, or in the default app for Markdown when VS Code is not installed. |
| ⌘O | Opens the browser window on the selected item or project. |
| ⌘⌫ | Moves the item to the Trash after asking (a skill with its whole folder). |

When a search with words finds nothing, the last rows are **Save as note "what you typed"** and, if the clipboard holds text, **Save clipboard as note "what you typed"**. ⏎ writes `inbox/notes/<date>-<slug>.md` with the typed text as title (the clipboard text as body on the second row) and closes the palette. If `@` names exactly one project the note goes there instead of the inbox, and `#` tags are written to it. When `?@name` names no project, the first row is **New project "Name"**; ⏎ makes the folder and its README and searches in it, keeping the rest of the query. Text that looks like a password or key shows a lock on its row and asks before saving.

**`!` in the palette.**

| Key | Does |
| --- | --- |
| `!` alone | Open to-dos: due ones first, then by project (the inbox first). |
| `!backup` | Filters the open to-dos. |
| `!done` | Lists the done ones instead, the most recently closed first. |
| `!fix the backup @server #urgent` | The last row, **Add to-do**, adds what you typed. ⏎ adds it and the palette stays on the list. Without `@` it goes to the inbox. |
| ⏎ or ⇥ | On a to-do with a checklist, moves into the checklist; ⏎ then ticks an item. Esc or ⇥ goes back to the list. Without a checklist, ⏎ edits. |
| ⌘D | Closes the selected to-do, or reopens a done one. It stays listed, dimmed, until the query changes, so a second ⌘D undoes the first. |
| ⌘E | Edits it. |
| ⌘⏎ | Opens the file in VS Code (or the default Markdown app). |
| ⌘⌫ | Moves it to the Trash after asking. |

**Hotkey.** *Search and capture notes* in Settings → Knowledge opens and closes the palette at `?`. It has no default shortcut.

**Status menu.** *Browse Knowledge…* opens the browser window, *New To-Do…* opens the palette at `!`, *Open Knowledge Folder* opens the folder in Finder (and creates it if it is missing).

**Quick actions.** *Save as Note* and *Add as To-Do* take text from a clip (⌘K in the palette), the selection hotkey, `>` or Shortcuts. The first line is the title and the rest the body; a first line over 80 characters is cut at a word and the whole text becomes the body. Both write to the inbox and post a notification. Text that looks like a password or key asks for confirmation first.

**The browser window** has the projects on the left (with item counts, the inbox first), Notes / To-Dos / Skills above the middle list with a search field (every word must be in the title, tags or text) and + (⌘N: a new note or to-do in the project, after asking its title), and the selected item on the right. Rows show the title, a second line (a note's first line, a to-do's checklist progress and tags, a skill's description) and a pill: when a note last changed, a to-do's due day (orange from today on). A to-do's circle closes or reopens it; done to-dos are collapsed under *Done (n)*, which the header opens. A row's context menu has *Mark as Done*, *Move to* (another project), *Open in VS Code*, *Show in Finder*, *Copy Text* and *Move to Trash…* (also ⌫, after asking). On the right the title is the heading (a skill's description below it); the project, a to-do's status and due day, and the tags are chips: the project chip moves a note or to-do to another project at once (the list then shows the item after it), the due chip opens a calendar, a comma or ⏎ in *Add tag* makes a tag. *Updated …* opens the path, dates and any other front matter. The text switches between *Edit* (the Markdown as plain text) and *Preview* (rendered, with checklist boxes to tick). ⌘S or *Save* saves, and so does showing another item or closing the window; *Revert* drops the edits. A new title renames the file. *Open in VS Code* (⌘O in the window) saves first. The window follows changes to the files within a second.

**The editor window** (⌘E) edits one item: title (a skill's or project's name), project, tags, description or summary, done and due, and the Markdown. A new title renames the file; another project moves it. ⌘S saves and ⌘⏎ saves and opens VS Code. If the file changed on disk since it was opened (an editor, an agent or the other Mac), saving asks whether to overwrite or reload. Edits are saved before another item is shown.

**Filing with AI** (`$note`, `$todo`, `$tidy`), **agents** (the MCP server and the skills links) and the **imports** are described in their own sections below.

## Settings

Settings → Knowledge. The page also has the Enabled switch; the module is on by default.

**Settings → Projects** (listed under General while the module is on) shows every project with its symbol, colour, ID and item count. *Edit…* (or a double-click) and *New Project…* open an editor: name, folder name (a new project's only; it defaults to the name as a slug and must be free), summary, colour (*Automatic* or one of the thirteen), symbol (a grid of common ones or any SF Symbol by name) and the linked folders (*Add Folder…*, stored with `~`). Saving writes those keys into the README and leaves its text and any other keys as written; a project without a README gets one. Projects are not renamed or deleted here: that is moving or deleting the folder.

| Option | Default | Meaning |
| --- | --- | --- |
| Search and capture notes (hotkey) | none | Opens the palette at `?`. |
| Folder | `~/.config/cortex/knowledge` | The folder in use, with a button that opens it. Not editable here (see [Data and privacy](#data-and-privacy)). |
| Keep a git history | on | Commits every change to a git repository in the folder, a minute after the last one. No remote. See [Sync and backups](#sync-and-backups). |
| Link skills into ~/.claude/skills | on | One symlink per skill, so Claude Code loads them in every session. Switching it off removes them. See [The MCP server](#the-mcp-server). |

Below the options:

- **Knowledge base:** the number of items and projects, and a warning when git is missing (it needs the Command Line Tools) or the last commit failed.
- **Agents:** the `claude mcp add` line for this copy of the app with a *Copy* button, and how many skills are linked into Claude Code, with a warning for names that could not be linked.
- **Import:** *Outline (Markdown export)* and *Trello (JSON export)*, each with an *Import…* button. See [The importers](#the-importers).

*Browse Knowledge…* has no setting of its own. AI filing uses the AI module's service, API key and text model (Settings → AI) and needs AI and Commands to be on.

## On the iPhone

The iOS companion ([plans/IOS.md](../../plans/IOS.md), M1, M3, M4 and M5) keeps a synced copy of the folder and works without a network; changes go out with the next sync.

- **Knowledge:** the projects, the inbox first, with their counts and open to-dos; a project's open to-dos, notes, skills and done to-dos; search with `@project` and `#tag` as in `?`. An item shows its front matter as a header and its body rendered.
- **To-Dos:** every project's open to-dos in the order of `!` (due ones first, overdue in red) or the done ones; the circle or a swipe ticks one off, a swipe left deletes.
- **Writing:** *+* in the toolbar makes a note or a to-do (in the project on screen, else the inbox) and, on the project list, a project. In an item, the boxes of a checklist tick, *Add item* adds to a to-do's checklist, *Edit* opens the editor (title, tags, project, done and due, the body as Markdown) and *More* has *Delete…*. Text that looks like a password or key asks before it is saved, as `?` and `!` do; a key that was in the note already doesn't ask again.
- **Actions:** *More* in an item, a long press on any item in a list, and a swipe right on *To-Dos* (*Remind*). *Add to Reminders* makes a reminder (title, the body and checklist as plain text, the due day, and a `cortex://item/…` link at the end of the notes that opens the item; Reminders doesn't show a URL another app sets, so the link is in the notes), or one per open checklist item; adding again updates them instead of adding them twice. The list is asked the first time and changed in Settings → Actions; nothing comes back from Reminders. *Add to Calendar* (a to-do with a due day) opens the calendar's own editor with an all-day event, so Cortex needs no calendar access. *Add to Notes* shares the title and the body as plain text, or runs the Shortcut named in Settings → Actions. *Copy* has the item as Markdown (`# Title` and the body), the body, or the link; *Share* has the text or the `.md` file.
- **Links:** `cortex://item/<path>`, `cortex://search?q=…` and `cortex://new?kind=todo&project=…` open the app there (`KnowledgeLink`). The MCP server's `cortex://<project>/<path>` URIs open the item too.
- **Capture without opening the app:** the share sheet's *Cortex* saves shared text, or up to ten pictures with an optional text, as a note in the inbox (the first line, up to 80 characters, is the title; one line of text is the title alone; the pictures go to `inbox/assets/`). The App Shortcuts *Add Note* and *Add To-Do* (with an optional due day) write into the inbox too, *Search Knowledge* and *Open To-Dos* open the app there; they are in Spotlight, Siri, Shortcuts and the Action button. The Home Screen icon's quick actions are *New Note* and *New To-Do*. Widgets: *To-Dos* (the first open to-dos in the order of the To-Dos tab, overdue in red; the circle ticks one off without opening the app) on the Home and Lock Screen, *New Note* on the Lock Screen, and a *New Note* control for Control Center and the Action button.
- **Spotlight:** notes and to-dos are in an on-device Core Spotlight index (title, summary, body, tags, project, due day); a result opens the item. Settings → *Show in Spotlight* (on by default) turns it off and deletes the index.
- **Background refresh:** iOS wakes the app now and then (at the earliest 30 minutes after it went to the background, as iOS sees fit) for a sync, which keeps the widgets and Spotlight current.
- **Conflicts:** the editor keeps its draft, also when iOS ends the app in the background (the draft is in `EditorDraft.json` in the app's data, until it is saved or discarded). If the file changed meanwhile, usually by sync, saving asks: *Keep Mine*, *Take Theirs* or *Copy Mine* (a "… (copy)" next to it). Settings → *Conflict Copies* lists `.conflicts/`, shows a copy and restores it (the version it replaces is kept there in turn).

The phone has no git history and no Trash: a delete removes the file, and the Macs keep it in `.conflicts/` when the delete arrives. The code is in `CortexMobile/Knowledge/` (`KnowledgeStore`, `EditorPresenter`, the views), `CortexMobile/Actions/` (`ItemActions`, `RemindersExporter`, the menu), `CortexMobile/App/AppNavigator.swift` (the links) and `CortexMobile/Settings/ConflictCopiesView.swift`. The links, the plain text and the reminders' contents are in Core (`KnowledgeLink`, `KnowledgeItemExport.swift`). The settings are `actions.remindersList`, `actions.notesShortcut`, `actions.reminders` (which reminders came from which item) and `spotlight.enabled` in the App Group defaults.

The share extension and the widgets are separate processes that never open the database or the Keychain: they write Markdown files into the shared knowledge folder, and the app picks those up when it next runs (on launch, on coming to the front, in a background refresh), counts them as its own writes and syncs them. Until then the Macs don't have them. What the widgets show is `Widgets.json` in the data directory, written by the app after every refresh; a widget that ticks a to-do off updates it itself. `Spotlight.json` there holds the modification dates last indexed, so a launch indexes only what changed. The code is in `CortexShare/` (the share extension), `CortexWidgets/` (widgets and the control), `CortexMobile/Intents/` (the App Shortcuts), `CortexMobile/SharedIntents/` (*New Note*, *Complete To-Do* and `IntentBridge`, also compiled into the widgets), `CortexMobile/Shared/SharedContainer.swift` (the App Group's paths, for all three), `CortexMobile/App/QuickActions.swift`, `WidgetUpdater.swift` and `CortexMobile/Knowledge/SpotlightIndexer.swift`; Core has `KnowledgeCapture` (notes from shared text and pictures), `WidgetSnapshot` and `KnowledgeSpotlight` (what to index and what changed).

## Data and privacy

**What is stored.** The notes, skills and to-dos are Markdown files in `~/.config/cortex/knowledge/` (or `$XDG_CONFIG_HOME/cortex/knowledge`). They are not encrypted, so editors, agents and backups can read them; this is deliberate. The search index lives in memory only and is rebuilt at every launch. The module has no database tables and no Keychain items. UserDefaults holds `knowledge.keepHistory` (default on) and `knowledge.linkSkills` (default on), the hotkey `knowledgeCapture`, and the module switch `module.knowledge.enabled`. The key `knowledge.folder` points the module at another folder; it has no control in Settings, set it with `defaults write <bundle ID> knowledge.folder /some/folder`. Sync keeps the folder it last scanned in the `metadata` table (`knowledgeSyncFolder`) and its bookkeeping in `syncRecord` (one small row per file).

**Secrets.** Text that looks like a password or key (`SensitiveTextDetector`) is not written silently. The palette's capture rows, `!` and the quick actions ask first; the MCP server refuses until the agent confirms with you. The files stay readable by any app, are kept in the git history and sync, so nothing is hidden once you confirm.

**Git history.** With *Keep a git history* on, the folder is a git repository with a `.gitignore` for `.conflicts/` and `.DS_Store`. Nothing is ever pushed. Each Mac has its own history. Deleting an item moves it to the Trash, but the history still has it.

**Sync.** With Sync on and *Notes, skills and to-dos* switched on in the Sync page, every file in the folder syncs, encrypted on the Mac first (see [SYNC.md](../SYNC.md) for the protocol). Hidden files, `.git/`, `.conflicts/` and files over 25 MB stay on the Mac. See [Sync and backups](#sync-and-backups).

**What leaves the Mac.** Nothing, except in these cases:

- **Sync**, when it is set up: the files, encrypted.
- **`$note` and `$todo`**, when you press ⏎ on the form: the text you typed (or the clipboard text you chose), the instructions for the model, the ID, name and summary of every project, the tags in use (at most the 80 most used), and for `$todo` today's date and weekday. It goes to the AI service chosen in Settings → AI (OpenAI), with the text model set there, and is not stored on OpenAI's side (`store: false`). Text that looks like a password or key is refused, and a clip marked sensitive is never sent.
- **`$tidy`**, when you press ⏎: up to 200 items of the inbox (notes, skills and open to-dos, newest first) with path, kind, title, tags and the first 400 characters of the body, for notes the paths and titles of up to three similar notes outside the inbox, plus the projects and tags as above. Items that look like a password or key are left out.
- **An agent** you connect through MCP reads and writes what you let it. The `cortex-mcp` program itself has no network access.

Nothing is sent in the background, and nothing is sent before you confirm on the form. The proposal is shown in the palette before anything is written.

## How it works

The logic is in CortexCore, the palette and windows in the app. See [ARCHITECTURE.md](../ARCHITECTURE.md) for the module system.

| File | Role |
| --- | --- |
| `CortexCore/Sources/CortexCore/Knowledge/KnowledgeItem.swift` | `KnowledgeItem` (path, project, kind, title, tags, summary, status, due, dates, body, front matter), `KnowledgeProject` and `ProjectColor`, `KnowledgePath` (what a path is), `KnowledgeTag`, `KnowledgeSlug`, `KnowledgeMarkdown` (first heading, code blocks). |
| `FrontMatter.swift` | Parses and writes the front matter subset; keeps what it does not understand as written. |
| `KnowledgeFolder.swift` | Reads, writes atomically (temporary file, then rename), creates notes, to-dos, skills and projects, applies edits, moves to the Trash. |
| `KnowledgeIndex.swift`, `KnowledgeSearch.swift`, `KnowledgeLibrary.swift` | The in-memory SQLite + FTS5 index, the `@project #tag` query, and `KnowledgeLibrary.refresh()`, which reads only the files whose modification date changed. |
| `TodoChecklist.swift` | The Markdown task list in a to-do's body, `TodoQuery` (`!done`, the add row) and `TodoList` (ordering). |
| `KnowledgeEdit.swift` | What the editor saves, with the text it was opened from so a change on disk is noticed. |
| `KnowledgeHistory.swift`, `KnowledgeSkillLinks.swift` | The git history and the symlinks into Claude Code's skills folder. |
| `KnowledgeFileSync.swift` | The `SyncEntityHandler` for the folder. |
| `KnowledgeFiling.swift`, `KnowledgeInstructions.swift` | The AI requests and answers for `$note`, `$todo`, `$tidy`, and the filing rules shared with the MCP prompts. |
| `KnowledgeActions.swift` | `KnowledgeCaptureAction`, the *Save as Note* and *Add as To-Do* quick actions. |
| `OutlineImporter.swift`, `TrelloImporter.swift` | The two importers. |
| `CortexCore/Sources/CortexMCP/`, `CortexCore/Sources/cortex-mcp/main.swift` | The MCP server and its executable. |
| `Cortex/Modules/Knowledge/KnowledgeModule.swift` | The `CortexModule`: manifest (id `knowledge`, trigger `?`, subscope `todos` under `!`, order 27, asks for Accessibility), hotkey, status menu items, options. Conforms to `ActionContributing`, `CommandContributing` and `SyncContributing`. |
| `KnowledgeService.swift`, `KnowledgeSettings.swift` | Owns the folder while the module is on: indexes it, watches it (`DirectoryWatcher`), writes captures, keeps the git history and the skills links. |
| `KnowledgeScope.swift`, `TodoScope.swift`, `Views/` | The `?` and `!` palette scopes and their views. |
| `Editor/`, `Browser/` | The editor and browser windows and their models. |
| `KnowledgeCommands.swift`, `KnowledgeReview.swift`, `Views/KnowledgeReviewViews.swift` | `$note`, `$todo`, `$tidy` and the proposal overlays. |
| `KnowledgeSettingsView.swift` | The sections below the options, with the Outline and Trello import rows. |
| `ProjectsSettingsView.swift`, `Views/ProjectTag.swift` | Settings → Projects and its editor; `ProjectColor`'s SwiftUI colours and the project label (`TintedTag` from the host's components), both shared with the iOS app. |

**Host and other modules.** The module has two scopes because the host allows one trigger per manifest: `?` is the module's own scope and `!` is a subscope (`PaletteSubscope`, route ID `todos`), returned from `palette(_:)`. ⌘⏎ is a `KeyCombo` a scope can take; without one it behaves like ⏎. Pasting and copying go through the palette's `closeAndDeliver`, with `recording: .skip`, so the text is not added to the clipboard history. Quick actions are contributed through `ActionContributing`, so they appear only while this module is on and also run from Shortcuts. `$note`, `$todo` and `$tidy` are contributed to the Commands module through `CommandContributing`, only while the AI module is on, and send through `AIAPI` (the AI module's vendor, text model, Keychain key and usage counts), so Knowledge never sees the API key. Sync reaches the folder through `SyncContributing`.

**Lifecycle.** `KnowledgeService.start()` creates the folder and the inbox, starts a `DirectoryWatcher`, refreshes the index, checks that git works and commits changes made while Cortex was not running. Every change reported by the watcher (ignoring hidden paths, so git's own writes do not count) refreshes the index and schedules a commit. Writes by the app itself also refresh at once. `stop()` closes the windows, stops watching and commits what is pending. Under tests the module uses a temporary folder and a temporary skills folder, never the real ones.

## The files

```
~/.config/cortex/knowledge/
  inbox/                          built-in project for captures
    notes/2026-10-22-potrace.md
    todos/2026-10-22-fix-backup.md
  server-config/
    README.md                     the project: name, summary, symbol, color, linked folders
    notes/
      docker-on-a-new-server.md
    skills/
      deploy-with-compose/SKILL.md
      deploy-with-compose/compose.example.yaml
    todos/
      fix-restic-backup.md
    assets/
      dashboard.png
  .conflicts/                     losing versions kept by Sync
```

**Projects.** Every top-level folder that does not start with a dot is a project. The folder name is its ID. The inbox is created at start. A `README.md` is optional and adds a name, summary, SF Symbol, colour and the folders the project belongs to:

```markdown
---
name: Server config
summary: The staging servers and their deploys
symbol: server.rack
color: teal
folders: [~/Developer/server-config]
---
What this project is about, for you and for agents.
```

Without a README the name is made from the folder name ("server-config" is "Server config"). `color` is one of `red`, `orange`, `yellow`, `green`, `mint`, `teal`, `cyan`, `blue`, `indigo`, `purple`, `pink`, `brown` and `gray` (each platform draws its own system colour); without one, or with a name Cortex does not know, the inbox is gray and every other project gets one of eight well-separated colours picked from its folder name, the same on every Mac and the iPhone. A project made in the palette (`?@name`) or in Settings starts with the colour the fewest projects have, written to its README. Project labels in the palette, the browser, the editor's overlays and the iOS app are drawn in it, on a faint glassy tint. Settings → Projects edits all of this. `folders` is what lets `cortex-mcp` pick the project when an agent works inside one of those folders.

**Notes.**

````markdown
---
title: Convert a PNG to an SVG with potrace
tags: [images, cli]
created: 2026-10-22T10:12:00Z
updated: 2026-10-22T10:12:00Z
---
potrace only reads bitmaps, so convert first:

```sh
magick input.png -threshold 50% input.pbm
potrace input.pbm -s -o output.svg
```
````

A Markdown file anywhere in a project outside `todos/`, `skills/` and `assets/` is a note, so `server-config/runbook.md` works too. A file without front matter is a note titled by its first `# ` heading, or by its file name (without the inbox date).

**To-dos.**

```markdown
---
title: Fix the restic backup
status: open            # open | done
tags: [backup]
due: 2026-10-30         # optional
created: 2026-10-22T10:12:00Z
updated: 2026-10-22T10:12:00Z
done: 2026-10-25T09:00:00Z   # set when status becomes done
---
The nightly run has been failing since the volume move.

- [x] check the cron log
- [ ] rotate the S3 key
- [ ] run once by hand
```

The checklist is the Markdown task list in the body. Files under `todos/` are to-dos; a missing `status` means open. Closing writes `status: done` and `done`; reopening removes `done`.

**Skills.** `skills/<name>/SKILL.md` with `name` and `description` in the front matter, which is Claude Code's layout. Supporting files sit next to it and are not indexed.

**Rules.**

- The file name is a slug of the title (lowercase ASCII letters, digits and hyphens, at most 60 characters; umlauts become ae, oe, ue, ß becomes ss), with the day in front in the inbox (`2026-10-22-potrace.md`). A taken name gets `-2`, `-3`.
- Renaming an item moves the file. A rename in the editor keeps an inbox file's day.
- Tags are lowercased, without `#`, with spaces as hyphens.
- `created` and `updated` are written by whoever writes the file. `updated` falls back to the file's modification date. Dates are `2026-10-22T10:12:00Z`; a day (`2026-10-30`) is read too.
- The front matter is a small YAML subset: scalars, inline and block lists, quotes, `~` for null, comments after a value. Anything else, such as a nested map, is kept exactly as written when Cortex rewrites the file, as is every key it does not know.
- Images and files go to the project's `assets/` and are linked relatively. Assets are not items; they sync as files.
- Hidden files and folders (`.conflicts/`, `.git/`) are not indexed.
- There are no IDs beyond the path, no positions or columns, no per-item permissions. If you want a column, use a tag.
- Writes are atomic: a temporary file, then a rename, so the watcher never reads half a file.

## The palette

`KnowledgeScope` is `?` and `TodoScope` is `!`. Both reload when the index changes.

**Query syntax.** Words search; every word has to match the start of a word (accents do not matter). `@x` picks the projects whose folder name, name or slugged name starts with `x`; `#x` picks items with a tag starting with `x`. A lone `@` or `#` is ignored, and the last `@` wins. In `!`, the word `done` at the start lists done to-dos.

**Ranking.** FTS5 `bm25` with weights title 10, tags 5, summary (a skill's description, a project's summary) 3, body 1; ties go to the most recently updated. A search lists up to 50 results; `?` alone lists the projects and the ten most recently updated items. `?@server` with no words lists the project's items, newest first. A project's README appears in a search as the project's row.

**The `!` order.** To-dos with a due day first, soonest first, whatever their project; then the rest by project (the inbox first), newest `created` first, so that ticking an item or closing a to-do does not move its row. Words filter the list and keep that order. Due days in the past show as "Overdue since …". The add row is there whenever there are words, also when to-dos match. After adding, the palette goes to `!` (or `!@project ` when `@` named one) with the new to-do selected.

**Where a capture goes.** The one project `@` names, else the inbox. An `@` that matches several projects puts it in the inbox; the row's badge says where it goes.

**The preview** shows the Markdown of the selected item, and under it the code blocks that ⌘1 to ⌘9 paste. In `!`, the pane shows the to-do with its checklist. The rows show a kind icon, the title, the project and a snippet of the match.

## AI filing

With the AI module and the Commands module on, three commands join `$`. They send text to the AI service chosen in Settings → AI, with its text model, and show what they propose in the palette before anything is written. Both `$note` and `$todo` take a Text field (the clipboard text is suggested); `$tidy` takes nothing.

| Command | Proposes | In the palette |
| --- | --- | --- |
| `$note potrace only reads bitmaps, convert with magick first` | A note, or a skill for step-by-step instructions: kind, project, title, tags, Markdown body (and a skill's description). | ⇥ and ⇧⇥ go round the projects (the inbox first, then by name); ⏎ saves; Esc discards. |
| `$todo fix the backup by friday, check the cron log first` | A to-do: project, title, tags, due day, checklist, body. | ⇥ and ⇧⇥ change the project; ⏎ adds it; Esc discards. |
| `$tidy` | For each inbox item: move it to a project (with a better title and tags), merge a note into a similar note outside the inbox, or leave it. | All proposals start ticked. ↑↓ select, ⇥ skips or takes back the selected one, ⏎ applies the ticked ones. |

**What is sent, and when.** Nothing goes out until you press ⏎ on the form. The progress card shows while the model answers. The request has three parts:

1. The model's instructions: the filing rules (the same text the MCP prompts use), the list of projects as `id: name — summary`, the tags in use (most used first, at most 80), and the description of the JSON answer. For `$todo` it also has today's date and weekday, so "Friday" can become a due day.
2. The input: for `$note` and `$todo`, the text you typed. For `$tidy`, one block per inbox item with its path, kind, title, tags, the paths and titles of up to three notes it could be merged into, and the first 400 characters of the body. `$tidy` sends at most 200 items (notes, skills and open to-dos, newest first) and leaves out any that look like a password or key.
3. A strict JSON schema, so the answer is always the JSON asked for.

The request goes to OpenAI's Responses API with `store: false`. `$note` and `$todo` refuse text that looks like a password or key, and a clip marked sensitive is never sent. The commands are marked remote and resolve to jobs, so selecting one sends nothing, and their plan text names the service and the model before you press ⏎.

**Reading the answer.** A project the model made up becomes the inbox. Tags are normalised and deduplicated. A due day must be a real `YYYY-MM-DD`, else it is dropped. An empty title becomes the first line of your text. A skill's name is made a slug, and a skill without a description gets the first line of the text. An answer that is not the expected JSON ends in an error notification.

**What is written.** ⏎ writes the file through the same `KnowledgeFolder` methods the palette uses (`createNote`, `createSkill`, `createTodo`) and closes the palette silently. The title and body cannot be edited in the proposal; ⌘E on the new item in `?` opens the editor.

**`$tidy` in detail.** A merge is offered only into notes the index finds similar (any title word of three letters or more, the best three outside the inbox), listed with each inbox note, so the model never guesses a path; a merge into anything else is dropped. Proposals that change nothing, "keep", unknown paths, and a skill moved to another project (its folder stays) are left out. If nothing is left, a notification says so and nothing opens. A move goes through `KnowledgeEdit` like the editor does (a new title renames the file). A merge appends `## <title>` and the body to the target note and moves the inbox note to the Trash. An item that changed since it was sent is left alone and counted in a notification.

Agents can do the same with the MCP prompts `file-this` and `tidy-inbox`, which use the same filing rules with the agent's own model. See [The MCP server](#the-mcp-server).

## The MCP server

`cortex-mcp` is a Model Context Protocol server over stdio that works on the knowledge folder, and on the action files of Quick Actions ([ACTIONS.md](ACTIONS.md)). It works when Cortex is not running, opens no port, needs no token, and has no network access; it never touches the database or the Keychain. It is built into the app (`Cortex.app/Contents/MacOS/cortex-mcp`) by every build, signed like the app. Settings → Knowledge → Agents shows the line to add it, with a *Copy* button:

```bash
claude mcp add --scope user cortex /Applications/Cortex.app/Contents/MacOS/cortex-mcp
```

Other clients (Claude Desktop, Cursor, anything that speaks MCP over stdio) are given the same executable. For development, `swift run --package-path CortexCore cortex-mcp` runs the same program. `--folder <path>` or the environment variable `CORTEX_KNOWLEDGE_FOLDER` points it at another folder, `--actions <path>` at another actions folder than `~/.config/cortex/actions` (`$XDG_CONFIG_HOME/cortex/actions` when that is set); `--version` and `--help` work too.

**Protocol.** One JSON-RPC message per line on stdin and stdout (split on `\n` only), batches answered as batches, protocol versions 2024-11-05 to 2025-11-25 (the client's if supported, else the newest). The server has its own in-memory index, refreshed before every tools, resources and prompts request, so it sees writes by the app, editors and the other Mac. Writes are atomic, and the app's watcher indexes them within a second.

**The current project.** Tools that take a `project` default to "current": the project whose `folders` contains the agent's working directory, else the inbox. When the client shares its roots, a root inside a project's `folders` wins over the working directory (Claude Desktop starts servers in `/`). The deepest matching folder wins. A project can be named by its ID or a prefix that names exactly one; an unknown project is an error that lists the projects. No tool creates a project implicitly.

**Tools.**

| Tool | Does |
| --- | --- |
| `list_projects` | ID, name, summary, linked folders, item and open to-do counts, and which is current. |
| `search` | Full-text search. Arguments: `query` (`@project` and `#tag` work too), `project`, `kind`, `tags`, `status`, `limit` (20, at most 100). Returns path, project, kind, title, tags, status, due, snippet. |
| `read` | An item: front matter as an object, body, a to-do's checklist, a skill's other files. Also reads those other files and any non-hidden text file in the folder. |
| `create_note`, `update_note`, `append_note` | Write notes with correct front matter and dates. `update_note` can change title (renames the file), body, tags, project (moves it), a skill's description or a project's summary. |
| `create_skill` | `skills/<name>/SKILL.md`. |
| `list_todos`, `create_todo`, `update_todo`, `complete_todo` | To-dos. `update_todo` takes status, due (empty removes it), project and the whole checklist as `[{text, done}]`, which replaces the old one. |
| `create_project` | A new folder with a README (`id`, `name`, `summary`, `folders`). Refuses an existing ID. |
| `list_actions` | The action files: file, name, trigger, what an action accepts, the URL or command; the files that do not load with their problem; and `taken_triggers`, the command names a new file cannot use. |
| `create_action` | Writes a new action file from its keys (the format's, plus `file` for the file name): a `$` command with `trigger`, a `>` action with `accepts`, both with both. It is checked the way the app loads it, so a file that would be a problem (a missing key, a placeholder in single quotes, a trigger a built-in, another file or one of the app's modules' commands has) is not written and the result says why. The file is named after `file`, the trigger or the name, with a number added when taken; it never replaces one. The app reloads the folder within a second, and the file syncs like the others. |
| `delete` | Moves an item to the Trash (a skill with its folder). Projects cannot be deleted. |

Results are JSON, as text and as `structuredContent`. A failure the model can fix (unknown project, a bad due day, a missing item) is a tool result with `isError`, not a protocol error.

**Secrets.** Writing text that looks like a password or key (in an action file, its command or URL) writes nothing: the result says why and tells the agent to ask you and call again with `confirm_sensitive: true`. Text already in the file does not ask again.

**Resources.** Every item is a resource, `cortex://<path>` (percent-encoded), plus the template `cortex://{+path}`. Reading takes any non-hidden file: text as text, anything else as a base64 blob.

**Prompts.** Every skill is a prompt named after its folder (`/mcp__cortex__deploy-with-compose` in Claude Code). It takes an optional `request`, which replaces `$ARGUMENTS` in the skill or follows it after a rule; the text starts with the skill's path and its other files, readable with `read`. Two skills with the same folder name: the first path wins. Two more prompts are built in and cannot be shadowed:

- `file-this` (argument `text`) lists the projects with their summaries, which one is current and the tags in use, and tells the agent to search for an item to add to before creating one.
- `tidy-inbox` lists up to 200 inbox items (no done to-dos) with 400-character excerpts and asks for numbered proposals to confirm before applying any.

**Skills for Claude Code without MCP.** *Link skills into ~/.claude/skills* (on by default) keeps one symlink per skill folder in `$CLAUDE_CONFIG_DIR/skills`, or `~/.claude/skills` when that is not set: `~/.claude/skills/<name>` points to `knowledge/<project>/skills/<name>` with an absolute path. Claude Code then loads the skills in every session, with or without the MCP server. Cortex only adds and removes symlinks that point into the knowledge folder; anything else there is left alone. A name taken by anything else, or by a skill of another project, is not linked and is listed in Settings. The links are updated after every refresh in which the list of skills changed. Switching the setting off removes them; switching the module off leaves them.

## Sync and backups

**Sync.** `KnowledgeFileSync` is the `SyncEntityHandler` for the folder (collection `knowledge`; switch *Notes, skills and to-dos*, UserDefaults key `syncKnowledge`, on with Sync). The record key is the path relative to the folder. The payload is the file's bytes and its modification date, which the other Mac's copy gets too. Files up to 256 KB travel in the payload; larger ones, such as pictures in `assets/`, as blobs. See [SYNC.md](../SYNC.md) for the protocol.

- Every file syncs, at any depth, except hidden files, anything in a hidden folder (`.git/`, `.conflicts/`) and files over 25 MB, which stay local and never look deleted.
- The newer write wins. The losing version goes to `.conflicts/<folders>/<name>-<date>-<hash>.<ext>` (the same content only once), where nothing indexes, syncs or commits it.
- A file deleted on the other Mac moves to `.conflicts/` on this one, never away, and the folders it emptied below the project's are removed. Because a rename is a delete and a new file, the other Mac keeps the old name's last version in `.conflicts/`.
- A remote delete takes only a file of exactly that name, because on a case-insensitive volume `Note.md` can be another record's `note.md`.
- A missing folder is not scanned (every file would look deleted). When `knowledge.folder` points elsewhere, the sync rows are forgotten and the cursor starts again from 0, instead of deleting the old folder's files on the other Mac.
- Sync watches the folder and asks for a cycle 5 seconds after a change to a file that is not hidden. Unchanged files are not read again: their hashes are kept by size and modification date across cycles.
- The server must know the `knowledge` collection; use a server from the same version of Cortex. Until then the engine isolates the refused records and syncs everything else.

**Backups.** The folder is plain files, so Time Machine has every version. If the sync server's volume is backed up, it holds only ciphertext. *Keep a git history* (on by default) makes `git init` in the folder (branch `main`, with a `.gitignore` for `.conflicts/` and `.DS_Store`) and commits everything a minute after the last change, once at start for changes made while Cortex was not running, and, if one is pending, when the module is switched off. Commits are by `Cortex <cortex@localhost>`, with signing and hooks off. The message names what changed: `Edit server-config/notes/docker-on-a-new-server.md`, or `Edit 3 files` with one line per file. There is no remote unless you add one. Both Macs have their own history; it is a time machine for the folder, not a second sync, and sync never touches `.git/`. Cortex runs `/usr/bin/git`; without the Command Line Tools (`xcode-select -p` fails) Settings says so and nothing else changes.

## The importers

Both importers are one-off: they read an export, write notes or to-dos into the folder and report what they did. Both skip what exists already, so they can be run again, and neither deletes anything. They are in CortexCore (`OutlineImporter`, `TrelloImporter`) and run from Settings → Knowledge → Import.

**Outline.** Export from Outline with Settings → Export → All collections (Markdown). *Import…* takes the zip (unpacked with `ditto` into a temporary folder that is removed afterwards) or the unpacked folder. A sheet lists the collections with their document counts. Next to each is a picker: an existing project, *New project* named after the collection, *Inbox* or *Skip*. Each collection starts on the project of the same name if there is one, else on *New project*. Collections do not map onto projects one to one, so you choose.

- Each document becomes a note. The title comes from the front matter or the first-line `# ` heading (which is dropped from the body), else the file name. `created` and `updated` are the file's date in the zip. A nested document is tagged with its parent's name.
- Attachments next to a document are copied once per project into `assets/` (a taken name gets `-2`) and the links are rewritten. Relative links to other documents of the export are pointed at the new notes. Absolute links (`/doc/…`) and web links are left as they are. Links to files missing from the export are counted in the report.
- Two documents with the same title in one import get `-2`. A note that exists at the same path is skipped and listed.

**Trello.** Export each board with the board's menu → Print, export and share → Export as JSON. *Import…* takes one or more board files at a time.

- Each board becomes a project named after it. A board imported again goes to the project made the first time.
- Each card becomes a to-do: description as the body, checklists as the task list (several are each headed by their name in bold), attachments as links below the body, labels as tags (a label without a name becomes a tag by its colour).
- A card is done if its list's name contains "done", "erledigt" or "fertig", if the card or its list is archived, or if its due date was ticked. Every other list name becomes a tag.
- `created` comes from the card's ID, `updated` and `done` from its last activity, and `trello: <card ID>` stays in the front matter. Comments are not imported. Cards whose file exists are skipped.

## Tests

- `CortexCore/Tests/CortexCoreTests/Knowledge/`: `FrontMatterTests`, `KnowledgeItemTests`, `KnowledgeLibraryTests` (index and search), `KnowledgeTodoTests` (also the iPhone editor's copy and secret check), `KnowledgeConflictCopiesTests`, `MarkdownBlocksTests`, `KnowledgeItemExportTests` (the iPhone's links, plain text and reminders), `KnowledgeActionsTests`, `KnowledgeHistoryTests`, `KnowledgeAgentTests` (skills links, instructions, appending), `KnowledgeFileSyncTests` (two Macs against the in-memory server), `KnowledgeFilingTests`, and the importers against recorded exports in `Fixtures/outline-export/` and `Fixtures/trello/`.
- `CortexCore/Tests/CortexMCPTests/MCPServerTests.swift`: sends JSON-RPC lines to the server, with a temporary actions folder for `list_actions` and `create_action`.
- `CortexTests/Modules/Knowledge/`: `KnowledgeScopeTests`, `TodoScopeTests`, `NoteEditorModelTests`, `KnowledgeBrowserModelTests`, `KnowledgeAgentsTests` (settings, skills links, the MCP line) and `KnowledgeFilingCommandTests`.
- Manual: [MANUAL_TESTS.md](../MANUAL_TESTS.md) M29 (the palette, editor, browser, clip actions, git history and imports), M30 (MCP and the skills links), M31 (filing with AI), step 11 of M19 (syncing the folder), M32, M34 and M35 (the iPhone).

Run the Core tests with `make test` and the app tests with `make test-app`.
