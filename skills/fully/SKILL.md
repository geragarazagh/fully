---
name: fully
description: "Checks Fully's macOS double-click and Accessibility status and fills a window to the screen's visible frame without macOS tiling via fully-cli. Use when maximizing a Mac window cleanly, checking Fully status, or customizing Fully."
license: MIT
compatibility: "macOS 13 or later (Apple Silicon) with Fully installed (brew install geragarazagh/tap/fully or /Applications/Fully.app)."
---

# Fully

Checks Fully's setup and fills any window cleanly to the screen's visible frame (as a plain frame, not a macOS tile) from the command line (`fully-cli`).

## Locate the CLI

Check in order; use the first that exits 0:

```sh
fully-cli --version
/Applications/Fully.app/Contents/MacOS/Fully --version
```

If neither exists, tell the user how to install it (`brew install geragarazagh/tap/fully`) and stop.

## Common tasks

1. **Check status** (running state, Accessibility permission, and whether macOS's built-in title-bar double-click is set to `None`):
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
