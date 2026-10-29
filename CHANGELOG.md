# Changelog

## 1.0.1 — 2026-10-29

- Fixed a crash when changing settings: rearranging the bar wrote item positions, which re-triggered the settings change in a loop.
- On macOS 27, icons now always fade away in place. The spacers beside the divider are kept between hides instead of added each time, which nudged the icons left first; they follow the divider when you ⌘-drag it.
- Blank spacers left behind by an earlier crash are cleared at launch.

## 1.0 — 2026-10-29

First release: Hidden and Always Hidden sections chosen by ⌘-dragging icons across Stow’s divider, reveal by click, ⌥-click, shortcut or hover, automatic re-hiding that waits while the menu bar is in use, a guide, settings in Stow and in Harbor, English and Turkish. Only public API, no permissions.
