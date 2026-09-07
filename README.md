# TapTap 👋

Turn your MacBook into an extra keyboard control surface. Tap the chassis to send a key, hold a modifier, launch a workflow, or control the app in front of you.

TapTap is a local, open-source macOS menu-bar app. It reads the experimental motion sensor exposed by some Apple Silicon MacBooks and converts tap rhythms into keyboard events.

## Quick start

```sh
brew tap 4nkitd/tap
brew install --cask taptap
open -a TapTap
```

On first launch:

1. Allow **Accessibility** when TapTap asks. This is needed to send keyboard events to other apps.
2. Click the waving-hand icon in the menu bar.
3. Open **Settings…** and choose a key for each gesture.
4. Tap the chassis and use that key in your favourite app, shortcut tool, or automation workflow.

## Defaults

| Gesture | Default output |
|---|---|
| Single tap | Hold/unhold left `Option` |
| Double tap | `F14` pulse |
| Triple tap | `F15` pulse |

The default single-tap Option binding behaves like an extra modifier: tap once to hold Option and tap again to release it.

## Make it yours

Open **Settings…** to:

- record any keyboard key, including Option, Command, Control, Shift, function keys, and ordinary keys;
- choose **Pulse** for a normal key press or **Hold / unhold** for a persistent key-down state;
- adjust sensitivity for gentle or firm taps;
- adjust the minimum separation between taps;
- adjust the gesture window used to recognize double and triple taps.

These controls matter because sensor placement, MacBook model, lid angle, desk surface, and tapping location all affect the signal. Start with a few test taps and tune until deliberate taps register without false positives.

## Hardware support

TapTap uses an undocumented Apple SPU HID sensor path. It is expected to work only on MacBooks that expose a compatible `AppleSPUHIDDevice`; Intel Macs, desktops, and some Apple Silicon models may not provide one. The menu-bar status reports whether the sensor opened and whether reports are arriving.

The sensor protocol is reverse-engineered and can change with macOS updates. TapTap does not send sensor data or usage data anywhere.

## Build from source

Requires macOS 13+ and Swift 5.9+:

```sh
git clone https://github.com/4nkitd/taptap.git
cd taptap
swift run
```

The app is deliberately local and has no backend, account, analytics, or network dependency.

## Apple Shortcuts

There are two simple ways to use TapTap with Shortcuts.

### Option 1: Give a gesture a keyboard shortcut

1. Create or open a Shortcut in Apple’s **Shortcuts** app.
2. Open the Shortcut details and choose **Add Keyboard Shortcut**.
3. Press the key you assigned in TapTap, such as `F14`.
4. Tap your MacBook to run the Shortcut.

For a modifier-style binding, assign a shortcut such as `Option + Space` in Shortcuts, then configure TapTap to hold Option. Tap once to hold Option, press Space normally, and tap again to release Option.

### Option 2: Use an automation tool as a bridge

Assign a TapTap key to an action in Karabiner-Elements, BetterTouchTool, Hammerspoon, or Keyboard Maestro. Those tools can then run a Shortcut, shell command, app, or multi-step workflow. This is useful when you want different behavior in different apps.

TapTap can also run an existing Shortcut directly in a future action slot using macOS’s documented command:

```sh
shortcuts list
shortcuts run "My Shortcut"
```

TapTap does not silently create arbitrary user-authored Shortcuts. Apple’s supported App Intents APIs are for exposing an app’s own actions to Shortcuts, Siri, and Spotlight.

## License

TapTap is released under the MIT License.
