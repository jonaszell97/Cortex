# Scrolling

macOS has one scroll direction for all devices ("Natural scrolling"), so a trackpad that scrolls naturally makes a mouse wheel scroll the wrong way round, or the other way round. The Scrolling module reverses the direction per device and per axis, so the trackpad can scroll naturally while the mouse scrolls the classic way, much like the Scroll Reverser app. It can also set how far one notch of a mouse wheel scrolls. It has no palette trigger and no data of its own.

## Using it

Switch the module on: Settings → Scrolling → Enabled. It is **off by default**. It needs the Accessibility permission, because it works through an event tap; the page shows "Needs Accessibility access" with a *Grant Access…* button while the tap cannot start, and the tap starts by itself once the permission is granted.

Quit Scroll Reverser or any other app that changes scrolling first; two reversals cancel each other out.

A scroll event with a scroll phase (fingers on the trackpad) or a momentum phase (coasting after they lift) counts as the trackpad. Anything else counts as the mouse. A Magic Mouse sends trackpad-like events, so it counts as a trackpad. Shift plus the wheel arrives from macOS as horizontal scrolling and is treated as such.

There is no hotkey, no palette scope and no status menu item.

## Settings

Settings → Scrolling:

| Option | Default | Meaning |
| --- | --- | --- |
| Enabled | off | The module's switch. |
| Reverse vertical | on | Flips up and down. |
| Reverse horizontal | off | Flips left and right. |
| Trackpad | off | Applies the reversal to the trackpad (and the Magic Mouse). |
| Mouse | on | Applies the reversal to a wheel mouse. |
| Wheel step size | about a fifth of the slider (3 lines) | How many lines one slow notch of a mouse wheel scrolls. The slider runs from 0 (leave it to macOS) to 30 and is finer at the small end, like Scroll Reverser's. Faster turns keep the size macOS gives them, still reversed if the mouse is. |

With the defaults, the mouse scrolls the opposite way to the system setting, the trackpad follows it, and each wheel notch scrolls three lines. The step size never changes continuous scrolling (a trackpad, a Magic Mouse, a smooth-scrolling mouse).

A reversal needs at least one axis and one device. The tap exists only while the module is on and the settings would change some event (a reversal rule, or a step size above 0); otherwise there is no tap.

## Data and privacy

The module stores only its settings in UserDefaults, under the keys `scrollReverseVertical`, `scrollReverseHorizontal`, `scrollReverseTrackpad`, `scrollReverseMouse` and `scrollWheelStepSize`. Its switch is `module.scrolling.enabled`; before that was first set, the older key `scrollReversal` (from when scrolling was a single option) is honoured. Nothing is synced (settings never are; see [SYNC.md](../SYNC.md)) and nothing leaves the Mac.

While active, a default event tap sees scroll events only, in every app. It changes the direction and the wheel step of the event and passes it on; it never holds back or drops an event, and it records nothing. With the module off, or with nothing to change, no tap exists. This differs from the Snippets module's tap, which sees key presses (see [SNIPPETS.md](SNIPPETS.md)).

## How it works

| File | Role |
| --- | --- |
| `Cortex/Modules/Scrolling/ScrollingModule.swift` | The `CortexModule` (id `scrolling`, no trigger, off by default, asks for Accessibility, order 60). Declares the four toggles as `options`, adds the slider through `settingsView`, and starts the tap with `context.whileWanted`, which runs the tap exactly while `ScrollingSettings.activeRules` is non-nil and Accessibility is granted, and updates its rules when settings change. |
| `ScrollingSettings.swift` | The UserDefaults-backed settings, `activeRules`, and the slider mapping (`stepSize(sliderPosition:)` and its inverse). |
| `ScrollingSettingsView.swift` | The slider, an explanation and the Accessibility warning. |
| `ScrollReverser.swift` | The tap. `ScrollTap` is a session event tap on its own thread (`Cortex scroll tap`), so a busy main thread never makes scrolling lag. The callback only reads the `Rules` under a lock and negates a few numbers. `source(of:)` tells trackpad from mouse, and `apply(_:to:)` changes an event. |

An axis has three deltas (lines, fixed-point lines, pixels), and apps read different ones. `ScrollReverser.adjust` reads all three first, because setting the lines makes macOS recompute the others. A single slow notch (a line delta of 1) is replaced by the step size; larger deltas are only reversed.

The module is a model for a background module that needs an event tap: it has no API, no scope and no database use. See [ARCHITECTURE.md](../ARCHITECTURE.md) and [ADDING_A_MODULE.md](../ADDING_A_MODULE.md) for `whileWanted`.

## Tests

- `CortexTests/Modules/Scrolling/ScrollReverserTests.swift`: the default rules, when rules are effective, the step size slider against Scroll Reverser's positions, persistence, which events count as trackpad or mouse, reversing every delta, the step of one notch, faster turns, continuous scrolling, and that reversing twice restores an event.
- Manual: [MANUAL_TESTS.md](../MANUAL_TESTS.md) M20 (real trackpad and mouse in Safari and Finder, momentum, horizontal scrolling, step size, no lag, switching off).
