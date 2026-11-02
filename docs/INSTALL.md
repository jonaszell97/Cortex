# Installing Cortex

There is no download: you build Cortex from source and install the result into `/Applications`.

## Requirements

- **macOS 26 or later.** The project and the `CortexCore` package both target macOS 26 and iOS 26 (`project.yml`, `CortexCore/Package.swift`).
- **Xcode 27.** That is what Cortex is developed with. The minimum is whatever ships Swift 6.2 (the package's `swift-tools-version`) and the macOS 26 SDK. The first build also downloads the Swift packages it uses (KeyboardShortcuts, SQLCipher), so it needs network access.
- **[XcodeGen](https://github.com/yonaskolb/XcodeGen)**: `brew install xcodegen`. `Cortex.xcodeproj` is generated from `project.yml` and not checked in.
- **An Apple Development certificate and its team.** In Xcode: Settings → Accounts → sign in → Manage Certificates → + → Apple Development. A free Apple ID is enough for the Mac app (see [Apple Developer account](#apple-developer-account)). See below for why an ad-hoc build is not enough.
- **Only for the sync server:** [uv](https://docs.astral.sh/uv/) or Docker. Cortex itself does not need either.
- **Optional:** `brew install ffmpeg imagemagick` for the video and WebP quick actions. The knowledge base's git history needs the Command Line Tools (`xcode-select --install`).

**Why a certificate.** macOS ties the Accessibility permission to the app's code signature. With a stable certificate, the grant survives every rebuild and update. An ad-hoc signed or unsigned build has a new identity each time, so macOS silently drops the grant: Cortex then still opens the palette and copies, but cannot paste into other apps, expand snippet keywords or reverse scrolling, until you remove it from the Accessibility list and add it again. The Keychain items Cortex creates are tied to the signature as well ([docs/MANUAL_TESTS.md](MANUAL_TESTS.md)). For this reason `make install` refuses to install an app that has no team identifier. (`make test-app` signs ad hoc on purpose and builds into `build/test`, away from the installed app.)

## Apple Developer account

What needs a paid Apple Developer Program membership (99 USD a year) and what does not. The project is developed with a paid account; nothing below was tested with a free one, so treat the "free" column as what the code needs, not as a guarantee.

| | Free Apple ID (Personal Team) | Paid membership |
| --- | --- | --- |
| **Mac app** (`make install`) | Should work. The app's only entitlement is Apple Events to Finder (`Config/Cortex.entitlements`), and it uses no iCloud, push, App Group or Keychain group. It is not sandboxed and not distributed, so no notarization or App Store access is needed. | Works. Nothing more is gained for the Mac app. |
| **`cortex-mcp`** (inside the Mac app) | Same as the Mac app. | Same. |
| **iPhone app** (`make install-ios`) | Not supported. The app, its share extension and its widgets share one data folder through an App Group (`Config/CortexMobile.entitlements`, `Config/CortexExtension.entitlements`), and community reports say Personal Teams cannot use App Groups; Apple's own pages do not say. The app also uses a Keychain access group, which was not checked either. | Works. App Groups and Keychain sharing are available, profiles do not expire after 7 days, and TestFlight lets you install without a cable. |
| **Sync between two Macs** | Works: it needs the [sync server](../sync-server/README.md), not an Apple service. | Same. |

Limits that apply to a free account on top of that ([Apple's comparison](https://developer.apple.com/support/compare-memberships/)):

- Provisioning profiles expire after 7 days. For an app that embeds one, it stops launching until you build and install it again. The Mac app has no entitlement that needs a profile, so it should not be affected, but this was not checked.
- Up to 10 App IDs per week, 3 devices and 3 apps per device. Cortex uses four App IDs (the Mac app, the iPhone app, the share extension and the widgets), plus `cortex-mcp` and the tests if Xcode registers them.

**Ad-hoc and self-signed builds are not a substitute.** A build without a team identifier loses the Accessibility permission on every rebuild (see below), and `make install` refuses to install one. A self-signed certificate has no team identifier, so it is refused as well.

## Steps

1. **Clone and bootstrap.**

   ```bash
   git clone <repo-url> Cortex
   cd Cortex
   make bootstrap
   ```

   `make bootstrap` fetches the vendored GRDB sources (a git submodule at `CortexCore/Vendor/GRDB.swift`; `git clone --recurse-submodules` does the same), creates `Config/Local.xcconfig` from `Config/Local.xcconfig.example` if it does not exist, and generates `Cortex.xcodeproj`.

2. **Fill in `Config/Local.xcconfig`** (untracked, so it stays on your machine):

   ```
   DEVELOPMENT_TEAM = ABCDE12345
   BUNDLE_ID_PREFIX = com.example
   ```

   - `DEVELOPMENT_TEAM` is the 10-character team ID: the Organizational Unit of your Apple Development certificate (Keychain Access → the certificate → Get Info), or Xcode → Settings → Accounts → team details. Left empty (the default in `Config/Shared.xcconfig`), nothing is signed with a team and `make install` stops.
   - `BUNDLE_ID_PREFIX` is a reverse-DNS prefix of your own. The bundle IDs are `<prefix>.Cortex` (the app), `<prefix>.cortex-mcp`, `<prefix>.CortexMobile` and `<prefix>.CortexTests`. It has to be an ID that your team can register for automatic signing, so do not keep `com.example`. macOS keeps the app's settings (UserDefaults) and its permission grants (Accessibility, Screen Recording, Automation) under `<prefix>.Cortex`, so changing the prefix later makes Cortex a new app to macOS: settings and permissions start empty. Your data does not move: the database, the knowledge folder and the Keychain items use fixed locations ([Data](#data)).

3. **Build and install.**

   ```bash
   make install
   ```

   This regenerates the project, builds the Release configuration into `build/install` (with `-allowProvisioningUpdates`, so Xcode may create the signing assets for your bundle IDs; be signed in to your account in Xcode), checks that the result is signed with a team, quits a running Cortex, replaces `/Applications/Cortex.app` with a copy (a copy, so cleaning `build/` or moving the repository never breaks the installed app) and opens it. If the build or signing fails, the running app is left alone. Run it at the Mac.

   Signing needs the login Keychain unlocked for `codesign`. Over SSH, `make install` unlocks it (it asks for your login password; the password goes straight to `security` and is not stored). For other signed builds over SSH, run `security unlock-keychain ~/Library/Keychains/login.keychain-db` first, or build from Xcode. If signing over SSH still fails with `errSecInternalComponent` after unlocking, allow Apple's tools to use the key once (asks for the password again):

   ```bash
   security set-key-partition-list -S apple-tool:,apple:,codesign: -s ~/Library/Keychains/login.keychain-db
   ```

4. **First launch and permissions.** Cortex is a menu bar app: it has no Dock icon and no main window, only the icon in the menu bar. ⇧⌘V opens the palette (Settings → General changes it). While Accessibility is missing, a window explains it and opens System Settings → Privacy & Security → Accessibility; switch Cortex on there. Cortex notices the grant within a second. If Cortex is already listed and on, but pasting does not work, the entry belongs to an older build: remove it with − and add Cortex again (or `tccutil reset Accessibility <prefix>.Cortex`).

   | Permission | For | When it is asked |
   | --- | --- | --- |
   | Accessibility | Pasting into other apps (⌘V), the selection hotkey, snippet keyword expansion, scroll reversal. Without it the palette still opens and copies | At first launch, by the window above |
   | Automation (Finder) | Quick actions on the files selected in Finder | The first time an action asks Finder for its selection. Settings → General → Permissions has a shortcut to the pane |
   | Screen Recording | *Capture Text* only ([Text recognition](modules/TEXT_RECOGNITION.md)). Searching screenshots, the colour picker and everything else do not need it | When you press the capture hotkey or use the button in Settings → General → Permissions. macOS applies it once Cortex is quit and opened again |
   | Notifications | Job results, copied colours and captured text | The first time Cortex posts one; macOS asks once |

   Settings → General → Permissions lists only what the switched-on modules need. *Launch at login* is in Settings → General. Modules that are off by default (AI, text recognition, scrolling, sync) are switched on in their own Settings page.

5. **Agents (optional).** To give Claude Code or another MCP client access to the knowledge base, add the `cortex-mcp` server that is inside the app ([Knowledge, "The MCP server"](modules/KNOWLEDGE.md#the-mcp-server)):

   ```bash
   claude mcp add --scope user cortex /Applications/Cortex.app/Contents/MacOS/cortex-mcp
   ```

   Settings → Knowledge → Agents shows the line for your setup, with a copy button. Other clients start the same executable over stdio. It works on the files, so Cortex does not need to be running.

## The iOS companion

The iPhone app (`CortexMobile`, with its share extension and widgets) syncs with your Macs through the same sync server. It needs a **paid Apple Developer Program membership**: see [Apple Developer account](#apple-developer-account). Skip this section if you only use the Mac app.

- `make build-ios` builds it for the simulator. It needs the iOS 26 simulator runtime (Xcode → Settings → Components) and the same `Config/Local.xcconfig`. `make check` compiles both apps without signing, which is the way to verify a build without a paid account.
- `make install-ios DEVICE=<name or UDID>` builds a Release build signed with your team and installs it on an iPhone with `devicectl`. `xcrun devicectl list devices` lists the devices; `IOS_DEVICE` in `Config/Local.xcconfig` sets a default. The first build registers the App Group `group.<prefix>.cortex` with your team through automatic signing, which is the step a free account cannot do.

The plan and the state of the iPhone app are in [plans/IOS.md](../plans/IOS.md).

## Updating

```bash
git pull
make install
```

`make install` regenerates the project. If the GRDB submodule was updated, run `git submodule update --init --recursive` first (`make bootstrap` does this too). The database is migrated when the new version starts. The settings and the permissions stay, as long as `Config/Local.xcconfig` is unchanged.

## Uninstalling

1. Switch off *Launch at login* and, if on, the knowledge base's *Skills in Claude Code* (Settings; it removes its symlinks in `~/.claude/skills/`). If you added the MCP server: `claude mcp remove cortex`.
2. Quit Cortex and move `/Applications/Cortex.app` to the Trash. Remove Cortex from System Settings → Privacy & Security (Accessibility, Screen Recording, Automation), or reset it: `tccutil reset All <prefix>.Cortex`.
3. Delete what Cortex stored (see [Data](#data)). Check first what you want to keep:

   ```bash
   rm -r ~/"Library/Application Support/Cortex"     # database and clip blobs: your clipboard history, snippets, reading list
   defaults delete <prefix>.Cortex                  # settings
   ```

   `~/.config/cortex/` holds your own files: quick actions and commands (`actions/`), `projects.toml`, `terminal.toml`, `sounds.toml` with the clips of `$clip` (`sounds/`) and the knowledge base (`knowledge/`, with its git history). Keep it, or delete it as well.
4. Delete the Keychain items of the service `dev.jonaszell.cortex` in Keychain Access, or one by one:

   ```bash
   security delete-generic-password -s dev.jonaszell.cortex -a database-key   # the database key
   security delete-generic-password -s dev.jonaszell.cortex -a sync-key       # only if you used sync
   security delete-generic-password -s dev.jonaszell.cortex -a sync-token
   security delete-generic-password -s dev.jonaszell.cortex -a ai.openai-api-key
   ```

   Without the database key the database is unreadable, so delete the key only together with the database.

## Data

Where Cortex keeps what it stores, and what never leaves the Mac.

- Database: `~/Library/Application Support/Cortex/Cortex.sqlite`, encrypted with SQLCipher. The 256-bit key is in the login Keychain (service `dev.jonaszell.cortex`, account `database-key`). Lose the key and the database is unreadable; the app then offers to move it aside, never deletes it.
- Clip payloads that are images or larger than 256 KB: `~/Library/Application Support/Cortex/Blobs/`, one file each, AES-GCM encrypted with a key derived from the database key.
- Snippets and the reading list: in the same database. They leave the Mac only when [Sync](modules/SYNC.md) is on, encrypted. Settings → Snippets → Import exchanges them with Raycast's snippet JSON (`name`, `text`, `keyword`); exported files are written readable only by you.
- Sync (off by default): the sync key and the server token are Keychain items in the same service (`dev.jonaszell.cortex`, accounts `sync-key` and `sync-token`); the server address and what to sync are in UserDefaults. The database's `syncRecord` table tracks what still has to be sent (one small row per clip, snippet, reading list link, action file and knowledge file, kept whether sync is on or off). Settings → Sync → *Disconnect* removes the Keychain items. When sync is on, the app talks to the server you entered and nothing else.
- Text read from image clips: in the same database (`clipItem.recognizedText`), indexed for search like copied text. It never leaves the Mac, not even with sync on. A captured screen region is written to a temporary folder only you can read and deleted as soon as its text is read.
- Keyword expansion (Settings → Snippets, off by default) uses an event tap that keeps the last typed characters in memory only (at least 20, or one more than the longest keyword). With it off, no tap exists.
- Scroll reversal (Settings → Scrolling, off by default) uses an event tap on its own thread that sees only scroll events and changes their direction and wheel step. With it off, no tap exists.
- Knowledge base: plain Markdown files in `~/.config/cortex/knowledge/` (not encrypted, so editors, agents and backups can read them; saving text that looks like a secret asks first). The index is in memory only. With *Keep a git history* on, the folder is also a git repository with every version (`.git/` in it), never pushed anywhere. `cortex-mcp` reads and writes the same files and has no network access. The skills links are symlinks in `~/.claude/skills/` (or `$CLAUDE_CONFIG_DIR/skills`).
- Recent calculations (the text typed after `=`, the last 20) are in UserDefaults (`calculator.recents`) and never leave the Mac. Settings → Calculator → *Clear* removes them.
- Quick action usage counts and the remembered option values (for ordering and defaults) are in UserDefaults and never leave the Mac; actions never upload anything. Only the action files themselves sync.
- Logs: unified logging only. `log stream --predicate 'subsystem == "dev.jonaszell.cortex"' --level debug`
