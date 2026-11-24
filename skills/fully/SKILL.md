---
name: fully
description: "Checks Fully's macOS double-click and Accessibility status and fills a window to the screen's visible frame without macOS tiling via fully-cli. Use when maximizing a Mac window cleanly, checking Fully status, or customizing Fully."
license: MIT
compatibility: "macOS 13 or later (Apple Silicon) with Fully installed (brew install geragarazagh/tap/fully or /Applications/Fully.app)."
---

# Fully

Checks Fully's setup and fills any window cleanly to the screen's visible frame (as a plain frame, not a macOS tile) from the command line (`fully-cli`).

## Locate the CLI

Check in order; use the first that exits 0. Use `--help`, never `--version`, and read the app's version from its Info.plist before running its binary: Fully before 0.2 has no command line at all, so it takes every flag (`--help` and `--version` alike) as a plain start and opens its window instead of failing.

```sh
fully-cli --help
defaults read /Applications/Fully.app/Contents/Info CFBundleShortVersionString
/Applications/Fully.app/Contents/MacOS/Fully --help
```

`fully-cli` exists only in versions that have the command line, so it is safe to try first. Run the third line only if the second prints 0.2 or newer; if it prints an older version, tell the user once to update Fully (Check for Updates in its menu, or `brew upgrade --cask geragarazagh/tap/fully`) and stop. If none works, tell the user how to install it (`brew install geragarazagh/tap/fully`) and stop.

## Common tasks

1. **Check status** (running state, this terminal's Accessibility grant as `terminalAccessibility`, which is the grant `fill` uses and not Fully's own, and whether macOS's built-in title-bar double-click is set to `None`; Fully's own grant is only visible in System Settings > Privacy & Security > Accessibility):
   ```sh
   fully-cli status --json
   ```
2. **Fill a window** (frontmost window, or a named running app's focused window):
   ```sh
   fully-cli fill
   fully-cli fill Safari
   ```

## Rebuilding from source

Clone `https://github.com/geragarazagh/fully`, read `AGENTS.md`, edit Swift files, and run `./build` (requires only Xcode Command Line Tools for ad-hoc builds).
