// Command line interface for Fully: inspect Accessibility / macOS double-click state, or fill a window to visibleFrame without tiling.
// Run as fully-cli (symlink to Fully.app/Contents/MacOS/Fully) or as Fully with subcommands:
//
//   fully-cli status [--json]      prints version, running state, this terminal's Accessibility grant and macOS double-click setting
//   fully-cli fill [APP_NAME]      fills the frontmost (or named) app's focused window to the screen's visible frame
//   fully-cli --version | --help

import AppKit
import ApplicationServices

private let fullyCliName = "fully-cli"

private let fuAppBundle: Bundle = {
    // executableURL, not argv[0]: run by name from PATH (the Homebrew symlink) argv[0] is the bare name, and the bundle
    // three levels above it is the current folder's, not the app's (measured 2026-11-23: version 0, settings unread).
    let real = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).resolvingSymlinksInPath()
    let appURL = real.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    return Bundle(url: appURL) ?? .main
}()

private func fullyAnswersForItself() -> Bool {
    typealias Lookup = @convention(c) (pid_t) -> pid_t
    let me = getpid()
    if let f = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") {
        let r = unsafeBitCast(f, to: Lookup.self)(me)
        if r > 0 { return r == me }
    }
    return getppid() == 1
}

private func fuFail(_ s: String) -> Never {
    FileHandle.standardError.write(Data((s + "\n").utf8))
    exit(1)
}

private func fuJSON(_ obj: Any) -> Never {
    guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
          let text = String(data: data, encoding: .utf8) else { fuFail("Could not encode JSON.") }
    print(text)
    exit(0)
}

private func fuRunning() -> Bool {
    guard let id = fuAppBundle.bundleIdentifier else { return false }
    return NSRunningApplication.runningApplications(withBundleIdentifier: id).contains { $0.processIdentifier != getpid() }
}

private func fmtRect(_ r: CGRect?) -> String {
    guard let r else { return "none" }
    return "\(Int(r.origin.x)),\(Int(r.origin.y)) \(Int(r.width))x\(Int(r.height))"
}

@MainActor func runFullyCLI(_ rawArgs: [String]) -> Bool {
    let exe = fuAppBundle.object(forInfoDictionaryKey: "CFBundleExecutable") as? String ?? "Fully"
    let named = URL(fileURLWithPath: rawArgs[0]).lastPathComponent != exe
    let rest = Array(rawArgs.dropFirst())
    let usage = """
    Usage: \(fullyCliName) status [--json]      prints version, running state, this terminal's Accessibility and macOS double-click setting
           \(fullyCliName) fill [APP_NAME]      fills the frontmost or named app's focused window to visibleFrame
           \(fullyCliName) --version | --help
    """
    let guiFlags: Set<String> = ["--login", "--background", "--relaunched", "--has-access", "--probe", "--fill", "--scan"]
    guard let cmd = rest.first else {
        if named { print(usage); exit(0) }
        return false
    }
    switch cmd {
    case "--help", "-h":
        print(usage); exit(0)
    case "--version", "-V":
        let v = fuAppBundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let n = fuAppBundle.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Fully"
        print("\(n) \(v)"); exit(0)
    case "status", "fill":
        break
    default:
        if named || (cmd.hasPrefix("--") && !guiFlags.contains(cmd)) { fuFail(usage) }
        return false
    }
    if fullyAnswersForItself() {
        fuFail("\(fullyCliName) runs from a terminal or script, not launched as an app or launchd job.")
    }

    let tail = Array(rest.dropFirst())
    switch cmd {
    case "status":
        let json = tail == ["--json"]
        guard tail.isEmpty || json else { fuFail(usage) }
        let version = fuAppBundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let running = fuRunning()
        // The grant of the terminal running this command (the one `fill` uses), not Fully's: macOS credits a child of a
        // terminal to the terminal (its responsible process), and the running app has no control channel to ask. Said so in
        // the name and the text, so an agent never reads "yes" as "the double-click works" (2026-11-24: the key was called accessibility).
        let access = AXIsProcessTrusted()
        CFPreferencesAppSynchronize(kCFPreferencesAnyApplication)
        let raw = CFPreferencesCopyAppValue("AppleActionOnDoubleClick" as CFString, kCFPreferencesAnyApplication) as? String ?? "Maximize"
        let ok = raw == "None"
        if json {
            fuJSON([
                "version": version,
                "running": running,
                "terminalAccessibility": access,
                "macOSDoubleClick": raw,
                "macOSDoubleClickReady": ok,
            ])
        }
        print("version: \(version)")
        print("running: \(running ? "yes" : "no")")
        print("terminalAccessibility: \(access ? "yes" : "no") (this terminal's grant, not Fully's; Fully's is in System Settings > Privacy & Security > Accessibility, on macOS 27 «Device Control and Data Access»)")
        print("macOSDoubleClick: \(raw)\(ok ? " (ok)" : " (set to None/Do Nothing/No Action in System Settings)")")
        exit(0)

    case "fill":
        guard tail.count <= 1 else { fuFail(usage) }
        guard AXIsProcessTrusted() else {
            fuFail("No Accessibility permission for the terminal running \(fullyCliName).")
        }
        let targetApp: NSRunningApplication?
        if let name = tail.first {
            targetApp = NSWorkspace.shared.runningApplications.first {
                ($0.localizedName?.localizedCaseInsensitiveCompare(name) == .orderedSame) ||
                ($0.bundleIdentifier?.localizedCaseInsensitiveCompare(name) == .orderedSame)
            }
            if targetApp == nil { fuFail("No running app matching «\(name)».") }
        } else {
            targetApp = NSWorkspace.shared.frontmostApplication
        }
        guard let app = targetApp else { fuFail("No target app found.") }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        let win = element(axApp, kAXFocusedWindowAttribute) ?? element(axApp, kAXMainWindowAttribute)
        guard let win, let frame = axFrame(win) else {
            fuFail("No accessible window for \(app.localizedName ?? "app").")
        }
        let center = CGPoint(x: frame.midX, y: frame.midY)
        let r = fill(win, at: center)
        print("\(app.localizedName ?? "Window"): \(fmtRect(r.before)) -> \(fmtRect(r.after))")
        exit(0)

    default:
        fuFail(usage)
    }
}
