# TV Remote for Mac

**An Apple TV remote that lives in your Mac's menu bar.** Arrow keys move, Return selects, Esc goes back. When the Apple TV opens its on-screen keyboard, a text field pops up on the Mac by itself, so you just type.

[Русская версия](README.ru.md)

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-brightgreen.svg)
![tvOS 15+](https://img.shields.io/badge/tvOS-15%2B-black.svg)
![Swift](https://img.shields.io/badge/swift-5.10-orange.svg)
[![License: GPL-3.0](https://img.shields.io/badge/license-GPL--3.0-blue.svg)](LICENSE)

<img src="docs/fork/shortcuts-window.png" width="520" alt="The remote with its keyboard shortcuts shown" />

- Works over your home network, the same way the iPhone remote does. No cloud, no account, no subscription.
- Free and open source.
- Built on [Itsytv](https://github.com/nickustinov/itsytv-macos) by Nick Ustinov. What's different is [listed below](#how-it-differs-from-itsytv).

## What it does

**Remote**
- Floating remote panel from the menu bar: d-pad, Select, Back, TV/Home, Play/Pause, volume.
- Full keyboard control: arrows, Return, Esc, Delete, Space. Holding a key works like holding a Siri Remote button.
- Shortcut hints on the buttons, and a Keyboard Shortcuts window where you can try every key and change it.

**Typing**
- The text field opens on its own when a text field on the Apple TV gets focus (search, logins, YouTube, Netflix…) and closes when it loses focus.
- Text already typed on the TV shows up on the Mac. Delete works letter by letter.
- ↑ and ↓ leave the field and go straight to the TV.
- Any input language your Mac has, including Russian, Japanese and Korean.

**Everything else**
- Now playing: artwork, title, progress, playback controls.
- App launcher with every app on the Apple TV, drag to reorder.
- Several Apple TVs, with a global hotkey for each.
- Launch at login, AppleScript and a Shortcuts action.

## How it differs from Itsytv

[Itsytv](https://github.com/nickustinov/itsytv-macos) is the original app this project grew from. It's sold on the Mac App Store and is also free on GitHub. This project goes its own way:

| | Itsytv | TV Remote for Mac |
|---|---|---|
| Keyboard on the Mac when the TV asks for text | open it yourself with ⌘K | **opens by itself** |
| Text already typed on the TV | not shown | **shown, editable** |
| Leaving the text field | ⌘K again | **↑ / ↓, or it closes with the TV's field** |
| Connection after the link drops | can loop or lose key presses | **reconnects with backoff, keys wait for the link** |
| Remote left open on another desktop | stays there | **comes to the current desktop** |
| Finding the app in Spotlight | "itsytv" | **"remote", "apple tv", "пульт", "тв"** |
| Build | two repositories side by side | **one repository** |
| Promo for other apps in the menu | yes | **no** |
| Shortcut hints, shortcuts window, custom keys, real key holds | yes, since 1.8 | yes (they started here) |

## Install

There's no signed download yet, so for now you build it yourself. It takes a few minutes.

You need: a Mac with macOS 14 or later, Xcode 16 or later, and an Apple TV (4th generation or later, tvOS 15+) on the same network.

```bash
brew install xcodegen
git clone https://github.com/Lemelson/tv-remote-for-mac.git
cd tv-remote-for-mac
DEVELOPMENT_TEAM=<your Apple team ID> scripts/install-fork.sh
```

The script builds a Release copy, puts it in /Applications as "Apple TV Remote – Пульт ТВ" and starts it. Your team ID is in Xcode → Settings → Accounts.

Prefer Xcode? Run `xcodegen generate`, open `itsytv.xcodeproj`, pick your team under Signing & Capabilities and run the **itsytv** scheme.

## First connection

1. Click the TV icon in the menu bar and pick your Apple TV.
2. The TV shows a four-digit code. Type it on the Mac.
3. Done. The pairing is stored in the macOS Keychain and the connection is encrypted.

## Keyboard shortcuts

| Key | Apple TV |
|---|---|
| ← ↑ → ↓ | move |
| Return | select (hold: context menu) |
| Esc | back (hold: Home screen) |
| Delete | TV / Home (hold: Control Center) |
| Space | play / pause |
| = / − | volume up / down |
| ⇧⌘M | mute |
| ⌘K | type on the Apple TV |
| ⌘F | search apps |
| ⌘W | close the remote |

Change any of them in the remote's ⋯ menu → Keyboard shortcuts…

## Scripting

```bash
osascript -e 'tell application id "com.itsytv.app" to pause'
osascript -e 'tell application id "com.itsytv.app" to play'
```

There's also a Shortcuts action that opens the remote for a given Apple TV, handy on a Stream Deck.

## Troubleshooting

**No code on the TV when pairing.** On the Apple TV, open Settings → AirPlay and Apple Home and set Allow access to "Anyone on the same network". Turn Require Password off while pairing. In Settings → General → Restrictions, allow AirPlay Settings and Remote App Pairing.

**The remote closes a few seconds after connecting.** Same setting: Allow access must be "Anyone on the same network", not "Only people sharing this home".

**No icon in the menu bar.** On MacBooks with a notch, macOS hides icons that don't fit. Hold ⌘ and drag other icons out of the menu bar.

**Volume doesn't change.** The Mac can only change volume when the Apple TV controls it over HDMI-CEC (Settings → Remotes and Devices → Volume Control). Infrared volume works only from the physical remote.

## How it works

The Apple TV speaks two local protocols, the same ones the iPhone remote uses:

- **Companion Link**: buttons, touch, app list, and text input. When a text field on the TV gets focus, the TV sends a `_tiStarted` event with the current text. That's what makes the Mac's field open by itself.
- **MediaRemote over an AirPlay tunnel**: what's playing, artwork, progress.

Both are end-to-end encrypted after a one-time pairing (SRP and ChaCha20-Poly1305). The protocol code is in [`ItsytvCore/`](ItsytvCore). The menu bar app is in [`itsytv/`](itsytv).

## License

- The project as a whole, and every change made here, is licensed under **[GPL-3.0](LICENSE)**.
- Code that comes from Itsytv stays under its original **[MIT license](LICENSE-MIT)**, © 2026 Nick Ustinov.

## Thanks

- [Itsytv](https://github.com/nickustinov/itsytv-macos) by Nick Ustinov, the app this one is built on.
- [pyatv](https://github.com/postlund/pyatv), the Python library that documented most of the Apple TV protocols.

Apple TV and macOS are trademarks of Apple Inc. This project is not affiliated with Apple.
