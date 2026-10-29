<p align="center">
  <img src="docs/assets/icon.png" width="128" height="128" alt="Stow icon">
</p>

<h1 align="center">Stow</h1>

<p align="center">
  <b>A calmer menu bar, one click away.</b><br>
  A free, open-source menu bar manager for macOS: tuck away the icons you rarely need<br>
  and bring them back with a click, a shortcut or a glance at the menu bar.
</p>

<p align="center">
  <a href="https://github.com/Kaandis/stow/releases/latest"><img src="https://img.shields.io/github/v/release/Kaandis/stow?label=download&color=6cc3cf" alt="Latest release"></a>
  <img src="https://img.shields.io/badge/macOS-15%2B-111" alt="macOS 15+">
  <img src="https://img.shields.io/badge/Swift-SwiftUI%20%2B%20AppKit-f05138?logo=swift&logoColor=white" alt="Swift">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue" alt="MIT license"></a>
</p>

<p align="center">
  <a href="https://kaandis.github.io/stow/">Website</a> ·
  <a href="https://github.com/Kaandis/stow/releases/latest/download/Stow.zip">Download</a> ·
  <a href="README.tr.md">Türkçe</a>
</p>

## What it does

- **Hidden and Always Hidden.** Stow adds an arrow and a thin divider to the menu bar. Everything left of the divider tucks away; click the arrow to bring it back. Turn on Always Hidden for a second divider whose icons only show when you ⌥-click the arrow.
- **You choose with ⌘-drag.** Hold ⌘ and drag icons across the divider, the way macOS already rearranges the menu bar. macOS keeps the order.
- **Tucks itself back.** Revealed icons hide again after 5, 15 or 30 seconds or a minute, but never while the pointer is on the menu bar or one of its menus is open.
- **A shortcut, or just hover.** Toggle with ⌃⌥S or ⌥⌘B, or let the icons show when the pointer rests on the menu bar.
- **Right-click the arrow** for Settings, the guide and Quit.
- **Works with Harbor.** With [Harbor](https://kaandis.github.io/harbor/) installed, Stow’s settings appear there and apply at once.

## Why it works this way

- **Only public API.** Hiding is widening Stow’s own divider until nothing to its left fits. macOS then leaves those icons out of the bar. No Accessibility, no Screen Recording, no private frameworks: there is nothing to grant.
- **Ready for macOS 27.** macOS 27 draws the menu bar as one piece, which broke managers that moved each icon’s window, and adds its own overflow arrow at the edge of the icons. Stow never touched those windows; its tucked icons simply wait in that overflow too.
- **No separate bar.** A second bar of hidden icons (like Ice’s) would need each icon on its own, which macOS 27 no longer offers. Stow sticks to what the system supports, so updates don’t break it.
- **Quiet.** Nothing runs while the bar sits still. Hover reveal is off by default because it’s the one feature that has to follow the pointer.
- **Puts everything back.** Quitting Stow shrinks its divider first, so no icon stays pushed away.

## Install

1. Download **[Stow.zip](https://github.com/Kaandis/stow/releases/latest/download/Stow.zip)** and unzip it.
2. Move **Stow.app** to Applications and open it.
3. The first time, right-click Stow and choose **Open** (builds aren’t notarized yet), or run:

```bash
xattr -dr com.apple.quarantine /Applications/Stow.app
```

A short guide shows how to ⌘-drag icons across the divider. Keep Stow’s arrow right of the divider, so it stays in view when icons tuck away; Stow tells you if it isn’t.

## Building

Requires Xcode 26 and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
xcodegen generate
xcodebuild -project Stow.xcodeproj -scheme Stow -configuration Release build
```

Releases are built with `scripts/release.sh`, which signs them with the “Harbor Apps Code Signing” certificate. `scripts/make-icon.swift` draws the icon and `scripts/sync-strings.py` rebuilds the English and Turkish strings.

## Project layout

```
Stow/
  App/          app entry and launch
  Core/         status items, sections, shortcut and hover reveal
  Settings/     the settings window
  Onboarding/   the guide
  Resources/    Info.plist, icon, strings, settings-schema.json
docs/           the website (GitHub Pages)
scripts/        release, icon and strings tools
```

## Disclaimer

Stow is an independent project and is not affiliated with, endorsed by or sponsored by Apple Inc. Mac and macOS are trademarks of Apple Inc., registered in the U.S. and other countries. Stow was written from scratch and shares no code with Ice, Hidden Bar or Bartender.

## License

[MIT](LICENSE)
