# Development

| Command | Does |
| --- | --- |
| `make open` | Regenerate the project and open `Cortex.xcworkspace` |
| `make build` | Debug build of the macOS app |
| `make test` | Core unit tests (`swift test --package-path CortexCore`) |
| `make test-app` | Module boundary check (`scripts/check-modules.sh`), then the macOS app unit tests (hosted in the app, signed ad hoc, so they also run over SSH) |
| `make check` | Compile both apps without signing (works over SSH) |
| `make build-ios` | Debug build of the iOS app for the simulator |
| `make install-ios` | Release build of the iOS app, installed on your iPhone, see [The iOS app](#the-ios-app) |
| `make project` | Regenerate `Cortex.xcodeproj` after editing `project.yml`. Adding or removing source files needs no regeneration, since the source folders are synced folders |
| `make install` | Release build and install, see [INSTALL.md](INSTALL.md) |
| `cd sync-server && uv run pytest` | Sync server tests (needs [uv](https://docs.astral.sh/uv/)) |

What the tests cannot cover (pasting into real apps, password managers, lock screen, system prompts) is in [docs/MANUAL_TESTS.md](MANUAL_TESTS.md). Run it after macOS updates and after changing the palette, pasting or a module.

The app is a small host and a set of modules, each in its own folder under `Cortex/Modules/` and `CortexCore/Sources/CortexCore/`: see [docs/ARCHITECTURE.md](ARCHITECTURE.md) for the design and [docs/ADDING_A_MODULE.md](ADDING_A_MODULE.md) to add one.

The sync server is optional and runs on a machine of your own: [sync-server/README.md](../sync-server/README.md), and [docs/modules/SYNC.md](modules/SYNC.md) for the module.
The repository layout is in [ARCHITECTURE.md](ARCHITECTURE.md#repository-layout).

## The iOS app

`CortexMobile/` is the iOS companion ([plans/IOS.md](../plans/IOS.md)). It joins sync like a third Mac and keeps the knowledge folder and the database in its App Group container (`group.<BUNDLE_ID_PREFIX>.cortex`), which is excluded from iCloud backup. Its Keychain items (database key, sync key, token) are readable after the first unlock and never leave the device. The database has a plaintext SQLite header and is suspended in the background (`AppDatabase.open(…, sharedContainer: true)`, `suspend()`), or iOS kills the suspended app with `0xdead10cc`; the simulator doesn't, so check for that on a device.

- `make install-ios DEVICE=<name or UDID>` builds Release and installs it with `xcrun devicectl`; set `IOS_DEVICE` in `Config/Local.xcconfig` to skip `DEVICE=`. The first build registers the App Group and the Keychain group with your team, and the two extensions' bundle IDs (`<BUNDLE_ID_PREFIX>.CortexMobile.Share` and `.Widgets`).
- The app embeds two extensions, `CortexShare` (share sheet) and `CortexWidgets` (widgets and the Control Center control). They share `Config/CortexExtension.entitlements` (the App Group only, no Keychain group) and never open the database: they write files into the App Group container and the app picks them up (see [KNOWLEDGE.md](modules/KNOWLEDGE.md#on-the-iphone)). Code they share with the app is in `CortexMobile/Shared/` and `CortexMobile/SharedIntents/`, listed as sources of each target in `project.yml`.
- In the simulator, run the sync server locally (see [sync-server/README.md](../sync-server/README.md)) and pass a pairing code at launch; Debug builds join with it without the camera:

  ```bash
  SIMCTL_CHILD_CORTEX_PAIRING_CODE="cxsync1:…" xcrun simctl launch <simulator> <BUNDLE_ID_PREFIX>.CortexMobile
  ```

  The code must come from a device that set up that server (`SyncSetup.firstDevice`); `http://127.0.0.1:8787` works from the simulator.
- Widgets and controls: use an iOS 27 simulator; the iOS 26 simulator's widget gallery shows blank pages for every app. Lock Screen widgets and the Action button can't be tried there.
- Background refresh: put the app in the background, then `lldb -p <pid of the app>` and `e -l objc -- (void)[[BGTaskScheduler sharedScheduler] _simulateLaunchForTaskWithIdentifier:@"<BUNDLE_ID_PREFIX>.CortexMobile.refresh"]`. It is a private call and hung on the iOS 27 simulator during M5, so check it on a device (Xcode's debugger has the same command) if it matters.
- A throwaway UI test target for checking screens must have its sources inside the repository (the ignored `build/` works): `xcodegen` hangs on a source path in `/private/tmp`.
- Links: `xcrun simctl openurl booted 'cortex://item/<path>'` (the simulator asks "Open in Cortex?" first). `xcrun simctl privacy booted grant reminders <BUNDLE_ID_PREFIX>.CortexMobile` skips the Reminders prompt. The simulator has Reminders, Calendar and Shortcuts, but not Notes.

## Screenshots

The screenshots and the demo GIF in the main README (`docs/images/`) are drawn from the real palette, not mocked up:

```bash
make screenshots
```

`CortexTests/Screenshots/ReadmeScreenshots.swift` starts every module on demo data (a fresh database, a temporary config and knowledge folder, in-memory secrets; `DemoData.swift` has the clips, snippets, links and notes), types into the palette and draws it off screen at 2x into `build/screenshots/raw/`. It never touches your database, clipboard or settings: recording is paused, and the module switches and palette style live in a throwaway UserDefaults suite. The suite is skipped unless `CORTEX_SCREENSHOTS` names an output folder, so `make test-app` does not run it. It runs with `-testLanguage en -testRegion en_US`, so numbers and dates look the same on every Mac.

`scripts/screenshots/compose.sh` then puts each render on a generated wallpaper: the palette's frosted backdrop is drawn off screen as transparent, and the script blurs and tints the wallpaper behind it instead, as the window server would. Settings pages are drawn without their title bar (off screen the window is never key, so the real one would be grey), and the script adds one with the traffic lights. It needs `brew install imagemagick ffmpeg` and takes a few minutes, most of it for the GIF's frames; `SKIP_GIF=1 scripts/screenshots/compose.sh build/screenshots/raw docs/images` redoes only the stills.

To change a screenshot, edit the scene in `ReadmeScreenshots.swift` (what is typed, which row is selected, dark or light) or the demo data, and the wallpaper or output name in `compose.sh`. Source app icons in the history come from the apps installed on the Mac that runs it.
