# AGENTS.md — Fully

macOS title-bar double-click window maximizer (fills `visibleFrame` as a plain frame, not a macOS tile, so dragging keeps its size) in plain Swift + AppKit + Accessibility. No Xcode project; `./build` compiles directly with `swiftc`.

## Architecture

- `main.swift` — `CGEventTap` double-click listener, Accessibility title-bar hit-tester (`judge`, `judgeWithPage` with temporary Electron `AXManualAccessibility`), critically damped spring resize (`fill`, `animate`), `DoubleClickRow` checking `AppleActionOnDoubleClick`.
- `cli.swift` — `fully-cli` (`status`, `fill [APP_NAME]`, `--version`, `--help`) with `answersForItself()` guard.
- `window.swift` — fixed settings panel, Open at Login helper.
- `updates.swift` — Sparkle 2.10.1 updater.

## Build & Test

- `./build` — builds ad-hoc signed `Fully.app` (`-target arm64-apple-macos13.0`). Works with Xcode Command Line Tools alone (`iconutil` fallback from `docs/icon.png`). Full Xcode is used for `Assets.car` (required when `SIGN_ID` is set).
- `TRACE=1 ./build` — enables `--probe X Y`, `--fill X Y`, `--scan` diagnostic flags (never signed with Developer ID).

## Invariants

- **Clean teardown**: `applicationShouldTerminate` waits for any in-flight fill/Electron AX check to restore `AXEnhancedUserInterface` and `AXManualAccessibility`.
- **Zero keystrokes seen**: event tap inspects mouse clicks only.
- **Customizing locally**: edit spring timing or hit-test rules in `main.swift`, run `./build`, replace `/Applications/Fully.app`. Ad-hoc re-signing requires re-granting Accessibility.
