# Changelog

## 1.0.3 — 2026-10-29

- On macOS 27, hiding no longer grows Stow’s divider, which the menu bar animated, sometimes shoving icons left before they faded. Blank spacers are added beside it already at full width, so icons fade out where they are; showing takes them away and the icons slide back in from the left, the same way every time.
- Stow notices when you allow Accessibility right away, without being restarted, and tells Harbor, which shows it on Stow’s page. The right-click menu offers to allow it when it’s missing.
- The dividers are visible again while everything shows; they were drawn too faint to find.

## 1.0.2 — 2026-10-29

- Quick clicks no longer send icons flying in from the left. The arrow answers at once; the menu bar waits for its last animation to finish and then shows only the latest state.
- On macOS 27, Stow can measure where the app menus end (optional Accessibility), which Always Hidden uses to size itself.
- Always Hidden works: its divider starts at the far left, so nothing is always hidden until you ⌘-drag icons past it, and turning it on shows everything so you can find it. Dividers show whenever everything is shown, even with “Show dividers” off. On macOS 27 it needs Accessibility to size itself.

## 1.0.1 — 2026-10-29

- Fixed a crash when changing settings: rearranging the bar wrote item positions, which re-triggered the settings change in a loop.
- On macOS 27, icons now always fade away in place. The spacers beside the divider are kept between hides instead of added each time, which nudged the icons left first; they follow the divider when you ⌘-drag it.
- Blank spacers left behind by an earlier crash are cleared at launch.

## 1.0 — 2026-10-29

First release: Hidden and Always Hidden sections chosen by ⌘-dragging icons across Stow’s divider, reveal by click, ⌥-click, shortcut or hover, automatic re-hiding that waits while the menu bar is in use, a guide, settings in Stow and in Harbor, English and Turkish. Only public API, no permissions.
