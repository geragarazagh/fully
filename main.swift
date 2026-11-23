// Fully: a double-click on the title bar of any app's window fills that window to the visible part of its screen
// (menu bar and Dock left out), as a plain frame set through Accessibility. macOS's own Fill (since macOS 15) makes a
// tile instead, and the window manager gives a tile its old size back the moment the window is dragged; a plain frame
// has no old size to go back to. macOS's own double-click action is meant to be None, so the two never both act.
// The only permission is Accessibility (macOS 27: «Device Control and Data Access»), for watching the clicks and for
// setting the frame. No files, no logs; the only network call is the daily update check (updates.swift).

import AppKit
import ApplicationServices

startInBackgroundIfAtLogin()
// A fresh copy asked by the running app whether the grant is there now (see App.tryTap).
if CommandLine.arguments.contains("--has-access") { exit(AXIsProcessTrusted() ? 0 : 1) }
_ = MainActor.assumeIsolated { runFullyCLI(CommandLine.arguments) }

// MARK: Accessibility helpers

func attr(_ e: AXUIElement, _ a: String) -> CFTypeRef? {
    var v: CFTypeRef?
    return AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success ? v : nil
}
func role(_ e: AXUIElement) -> String { attr(e, kAXRoleAttribute) as? String ?? "?" }
func subrole(_ e: AXUIElement) -> String { attr(e, kAXSubroleAttribute) as? String ?? "" }
func element(_ e: AXUIElement, _ a: String) -> AXUIElement? {
    guard let v = attr(e, a), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
    return (v as! AXUIElement)
}
func axFrame(_ e: AXUIElement) -> CGRect? {
    guard let p = attr(e, kAXPositionAttribute), let s = attr(e, kAXSizeAttribute),
          CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
    var o = CGPoint.zero, z = CGSize.zero
    guard AXValueGetValue(p as! AXValue, .cgPoint, &o), AXValueGetValue(s as! AXValue, .cgSize, &z) else { return nil }
    return CGRect(origin: o, size: z)
}
func settable(_ e: AXUIElement, _ a: String) -> Bool {
    var b = DarwinBoolean(false)
    return AXUIElementIsAttributeSettable(e, a as CFString, &b) == .success && b.boolValue
}

// MARK: Is this point the title bar of a standard window?

// Roles a double-click is meant for: controls, text, lists, web pages. A hit on one of them, or inside one, is never
// the title bar, even inside the title bar's band (Safari's address field, Finder's view buttons, a tab).
let controls: Set<String> = [
    "AXButton", "AXRadioButton", "AXCheckBox", "AXPopUpButton", "AXMenuButton", "AXTextField", "AXTextArea",
    "AXComboBox", "AXTabGroup", "AXRadioGroup", "AXSlider", "AXIncrementor", "AXDisclosureTriangle", "AXLink",
    "AXWebArea", "AXScrollArea", "AXList", "AXOutline", "AXTable", "AXBrowser", "AXRow", "AXCell", "AXImage",
    "AXColorWell", "AXDateField", "AXLevelIndicator", "AXSplitter", "AXMenuBar", "AXMenuBarItem", "AXMenu",
    "AXMenuItem", "AXSheet", "AXDrawer", "AXSegmentedControl", "AXPopover", "AXValueIndicator",
]

struct Verdict {
    var window: AXUIElement?
    var fill = false
    var why = ""
    var chain: [String] = []
    var needsWebTree = false   // the hit is an Electron page whose accessibility tree is off (see act)
}

// Electron apps (Claude, VS Code, Slack…) draw their title bar as part of a web page. With Chromium's accessibility off,
// which is its default, the whole page answers a hit test as one scroll area, so a button and an empty spot of the
// header look the same; the page's tree is switched on for the moment of the check (AXManualAccessibility, the switch
// Electron offers to tools like this one) and back off after.
func isElectron(_ pid: pid_t) -> Bool {
    guard let url = NSRunningApplication(processIdentifier: pid)?.bundleURL else { return false }
    return FileManager.default.fileExists(atPath: url.appendingPathComponent("Contents/Frameworks/Electron Framework.framework").path)
}

// p is in global display points, top left of the main screen at 0,0 (Accessibility's and CGEvent's space).
func judge(_ p: CGPoint) -> Verdict { judge(p, treeOn: false) }
func judgePage(_ p: CGPoint) -> Verdict { judge(p, treeOn: true) }

func judge(_ p: CGPoint, treeOn: Bool) -> Verdict {
    var v = Verdict()
    let system = AXUIElementCreateSystemWide()
    // An app busy for a moment (Safari loading a page, measured 0.5 s timeouts in 0.3's tests) answers late; macOS's own
    // double-click waits for the app too, since the app itself handles it. So a timed-out hit test is asked again, up to
    // about 3 s in all (a test machine without a GPU took up to 2 s to answer right after a window shrank from full
    // size); the fill runs on its own queue, so nothing else waits meanwhile.
    AXUIElementSetMessagingTimeout(system, 0.5)
    var hit: AXUIElement?, err = AXError.cannotComplete, tries = 0
    while tries < 6 {
        err = AXUIElementCopyElementAtPosition(system, Float(p.x), Float(p.y), &hit)
        if err != .cannotComplete { break }
        tries += 1; trace("  hit test timed out, again")
    }
    guard err == .success, let hit else { v.why = "nothing at the point (\(err.rawValue))"; return v }
    // Up from the element to its window; any control on the way means the click was meant for that control.
    // Inside a web page (AXWebArea) the page itself and the scroll view that holds it are not controls: what decides is
    // the element under the pointer, a header's empty space or a button in it.
    var e: AXUIElement? = actual(hit, at: p), window: AXUIElement?
    var steps = 0, inPage = false, opaquePage = false
    while let cur = e, steps < 40 {
        let r = role(cur)
        v.chain.append(subrole(cur).isEmpty ? r : "\(r)/\(subrole(cur))")
        if r == "AXWindow" { window = cur; break }
        // Finder alone treats the folder's name in its toolbar as a control: no fill on the letters, fill beside them
        // (measured in 0.3's matrix; TextEdit, Notes and Terminal fill on their titles). The name's frame is far wider
        // than the letters, so the letters' own bounds decide, across only: their height comes back wrong (27.2).
        if r == "AXStaticText", steps == 0, finderName(cur, p) { v.why = "on the folder's name (Finder)"; return v }
        // An Electron page whose tree is not live answers as the scroll area, or, once the tree has been on and off
        // again, with a stale tree (a button answered as the bare web area, measured): either way it can't be read.
        if (r == "AXWebArea" || r == "AXScrollArea" && steps == 0) && !inPage && !treeOn && electron(cur) && !liveTree(cur) {
            opaquePage = true; inPage = true
        } else if r == "AXWebArea" { inPage = true }
        else if r == "AXScrollArea" && inPage {}
        // A map that runs up under the title bar (Find My: the window is one map, its sidebar and toolbar float over
        // it) is the bar's background there: macOS fills on it inside the band and nowhere below (measured 27.2).
        else if r == "AXImage" && subrole(cur) == "AXMapArea" {}
        // A sidebar's divider that runs up into the title bar (the Catalyst and SwiftUI apps: Books, Find My, Journal,
        // Stocks, Voice Memos, Weather) is part of the bar there: macOS fills on it inside the band (measured 27.2).
        else if r == "AXSplitter" && steps == 0 {}
        else if controls.contains(r) { v.why = "on a control: \(r)"; return v }
        if r == "AXApplication" { break }
        e = element(cur, kAXParentAttribute); steps += 1
    }
    guard let window else { v.why = "no window"; return v }
    v.window = window
    guard subrole(window) == "AXStandardWindow" else { v.why = "not a standard window: \(subrole(window))"; return v }
    if (attr(window, "AXFullScreen") as? Bool) == true { v.why = "full screen"; return v }
    // A window with a sheet open (a save dialog, a first-run welcome) takes no title-bar double-click in macOS either
    // (measured in 0.3's matrix: Books, Maps, Music, Podcasts, Stocks with their welcome sheets).
    if ((attr(window, kAXChildrenAttribute) as? [AXUIElement]) ?? []).contains(where: { role($0) == "AXSheet" }) {
        v.why = "a sheet is open"; return v
    }
    guard let w = axFrame(window) else { v.why = "window without a frame"; return v }
    // A window of a fixed size (Calculator, Digital Color Meter) is still taken: macOS's Fill centres it (see fill).
    guard settable(window, kAXPositionAttribute) else { v.why = "position can't be set"; return v }
    // The title bar's band: the window buttons sit in its middle, so it reaches as far below them as it starts above
    // them (28 pt for a plain title bar, the whole toolbar for a unified one); a toolbar below them adds its own height.
    guard let close = element(window, kAXCloseButtonAttribute), let c = axFrame(close) else {
        v.why = "no window buttons"; return v
    }
    var bottom = c.maxY + (c.minY - w.minY)
    for child in (attr(window, kAXChildrenAttribute) as? [AXUIElement]) ?? [] where role(child) == "AXToolbar" {
        if let t = axFrame(child) { bottom = max(bottom, t.maxY) }
    }
    guard p.y >= w.minY, p.y < bottom, p.x >= w.minX, p.x < w.maxX else {
        v.why = "below the title bar (band \(Int(bottom - w.minY)) pt)"; return v
    }
    // Content that runs under the toolbar can answer for the toolbar's own buttons: Find My's map answers the hit test
    // at its 3D and Tracking buttons, which lie over it in the toolbar (the window's child, not the map's). So when the
    // hit came from the content (not the toolbar, not the bare window: Calendar's empty bar answers as the window, and
    // macOS fills around its buttons), the toolbar is asked for a control under the point. These buttons' frames
    // are what is drawn (36 pt circles), and macOS does not fill on them up to their very edge (measured 27.2).
    if v.chain.count > 1, !v.chain.contains(where: { $0.hasPrefix("AXToolbar") }), let c = toolbarControl(window, p) { v.why = "on a control in the toolbar: \(role(c))"; return v }
    if opaquePage { v.needsWebTree = true; v.why = "Electron page, tree off (band \(Int(bottom - w.minY)) pt)"; return v }
    v.fill = true; v.why = "title bar (band \(Int(bottom - w.minY)) pt)\(inPage ? ", web page" : "")"
    return v
}

// What is really under the point. An app's own hit test can be wrong both ways, measured in Safari with tabs in the
// toolbar (macOS 27.2, 0.3): left and right of the tabs, where the bar is empty and macOS's own double-click fills the
// window, Safari answers with a tab whose frame is nowhere near the point (the empty spot beside the tab); and
// along the tabs' lower edge, inside a tab, it answers with the bare tab bar. So the hit is checked by geometry: an
// element whose frame does not hold the point gives way to its parent, and a container gives way to a tab or a text
// field or button of its own whose frame holds it (Finder's and Notes' search fields answer as their toolbar group, Notes'
// New Note button as the toolbar, and macOS does not fill there). A button's frame is taller than what is drawn, so it
// counts only well inside (see `inset` below).
// Big containers (scroll areas, lists, web pages) are not looked into: a sidebar runs up under the title bar in Finder
// and Notes, and macOS fills there.
let buttons: Set<String> = ["AXButton", "AXMenuButton", "AXPopUpButton", "AXCheckBox"]
let pointControls: Set<String> = buttons.union(["AXRadioButton", "AXTextField", "AXTextArea", "AXComboBox"])
// `inset` > 0 asks for the point to be that far inside: at a frame's very edge macOS still fills (Finder's search
// field, frame from 7 pt, filled at 7 pt).
func holds(_ e: AXUIElement, _ p: CGPoint, inset: CGFloat = 0) -> Bool? {
    guard let f = axFrame(e), f.width > 0, f.height > 0 else { return nil }
    return f.insetBy(dx: inset, dy: inset).contains(p)
}
func actual(_ hit: AXUIElement, at p: CGPoint) -> AXUIElement {
    // Only a tab is doubted this way: other elements may stand a little off what they draw and are still what macOS
    // hits (Safari's address field answers at 15 pt, its frame starts at 18).
    var e = hit, n = 0
    while role(e) == "AXRadioButton", holds(e, p) == false, let up = element(e, kAXParentAttribute), n < 40 {
        trace("  hit \(role(e))/\(subrole(e)) does not hold the point: its parent instead")
        e = up; n += 1
    }
    if controls.contains(role(e)) || role(e) == "AXWindow" { return e }
    // Looked for in the hit and in up to two of its containers (never the window's own children: a sidebar or a text
    // view may run under the title bar, and macOS fills there), three levels down each, a few dozen elements: tab bars
    // and toolbar groups are small. Chrome needs the container: its hit test answers with an empty overlay group that
    // lies over the tab strip, and the tabs are that group's siblings (measured on Chrome 2026-11, 27.2). Three levels,
    // since Calendar answers at times with its bare toolbar over its Day/Week/Month tabs and its Calendars/Inbox
    // segments, which lie toolbar > item group > tab group > tab (two levels filled there, measured 27.2, 2026-11-17).
    var base: AXUIElement? = e, ups = 0, seen = 0
    while let b = base, role(b) != "AXWindow", ups < 3 {
        var level = [b]
        for _ in 0..<3 {
            var next: [AXUIElement] = []
            for c in level.flatMap({ (attr($0, kAXChildrenAttribute) as? [AXUIElement]) ?? [] }) {
                seen += 1; if seen > 96 { return e }
                // A tab counts from its edge (along a Safari tab's lower edge macOS does not fill), a field from 1 pt
                // inside (at its very edge macOS still fills: Finder's search field), a button from 8 pt inside: a
                // toolbar gives each button a 52 pt slot and draws it 38 pt tall in the middle, and macOS fills on the
                // bar around it (Safari's Share at 7 pt from the top, Notes' View Options 3 pt in from its side) but
                // not on it (Notes' New Note, which Notes' own hit test answers as the bare toolbar).
                let r = role(c)
                let inset: CGFloat = r == "AXRadioButton" ? 0 : buttons.contains(r) ? 8 : 1
                guard holds(c, p, inset: inset) == true else { continue }
                if pointControls.contains(role(c)) { trace("  hit \(role(e)) is over \(role(c))/\(subrole(c)): that instead"); return c }
                if !controls.contains(role(c)) || tabBars.contains(role(c)) { next.append(c) }
            }
            level = next
        }
        guard let up = element(b, kAXParentAttribute), holds(up, p) != false else { break }
        base = up; ups += 1
    }
    return e
}
// Tab bars are controls of their own but hold the tabs a point may be over.
let tabBars: Set<String> = ["AXTabGroup", "AXRadioGroup"]

// A control of the window's toolbar whose frame holds the point (see judge); a toolbar is small, a few dozen elements.
func toolbarControl(_ window: AXUIElement, _ p: CGPoint) -> AXUIElement? {
    var level = ((attr(window, kAXChildrenAttribute) as? [AXUIElement]) ?? []).filter { role($0) == "AXToolbar" && holds($0, p) == true }
    var seen = 0
    for _ in 0..<6 {
        var next: [AXUIElement] = []
        for c in level.flatMap({ (attr($0, kAXChildrenAttribute) as? [AXUIElement]) ?? [] }) {
            seen += 1; if seen > 96 { return nil }
            guard holds(c, p) == true else { continue }
            if controls.contains(role(c)) { return c }
            next.append(c)
        }
        level = next
    }
    return nil
}

func finderName(_ e: AXUIElement, _ p: CGPoint) -> Bool {
    var pid: pid_t = 0
    guard AXUIElementGetPid(e, &pid) == .success,
          NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == "com.apple.finder",
          let up = element(e, kAXParentAttribute), role(up) == "AXWindow",
          let n = attr(e, kAXNumberOfCharactersAttribute) as? Int, n > 0 else { return false }
    var range = CFRange(location: 0, length: n), out: CFTypeRef?
    guard AXUIElementCopyParameterizedAttributeValue(e, kAXBoundsForRangeParameterizedAttribute as CFString,
                                                     AXValueCreate(.cfRange, &range)!, &out) == .success, let out,
          CFGetTypeID(out) == AXValueGetTypeID() else { return false }
    var g = CGRect.zero
    AXValueGetValue(out as! AXValue, .cgRect, &g)
    return p.x >= g.minX - 2 && p.x <= g.maxX + 2
}

// The page's tree is live only while someone keeps Chromium's accessibility on (VoiceOver, or this app for a moment).
func liveTree(_ e: AXUIElement) -> Bool {
    var pid: pid_t = 0
    AXUIElementGetPid(e, &pid)
    return (attr(AXUIElementCreateApplication(pid), "AXManualAccessibility") as? Bool) == true
}

func electron(_ e: AXUIElement) -> Bool {
    var pid: pid_t = 0
    return AXUIElementGetPid(e, &pid) == .success && isElectron(pid)
}

// The page's tree switched on, the check repeated until the page answers with its own elements (Chromium builds the
// tree in the background: measured below in the card), the switch put back as it was.
func judgeWithPage(_ p: CGPoint, _ first: Verdict) -> Verdict {
    guard let w = first.window else { return first }
    var pid: pid_t = 0
    AXUIElementGetPid(w, &pid)
    let app = AXUIElementCreateApplication(pid)
    let was = (attr(app, "AXManualAccessibility") as? Bool) == true
    if !was {
        let r = AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        trace("  AXManualAccessibility on for \(pid): \(r.rawValue)")
    }
    defer { if !was { AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanFalse) } }
    // Chromium rebuilds the tree in the background and, until it has, answers with the stale or empty page (a button
    // read as the web area for the first ~0.2 s, measured). So the answer is taken once at least 0.25 s have passed
    // and two checks in a row agree; no new check starts after 2.5 s, and then nothing is done (the last check itself
    // may run on: a hit test is retried up to about 3 s, see judge).
    let t0 = Date()
    var v = first, last = "", same = 0, settled = false
    while Date().timeIntervalSince(t0) < 2.5 {
        usleep(40_000)
        v = judgePage(p)
        let key = "\(v.fill) \(v.chain)"
        if v.chain.first == "AXScrollArea" { last = ""; continue }   // the page has no tree yet: keep waiting
        if Date().timeIntervalSince(t0) >= 0.25 { same = key == last ? same + 1 : 0; if same >= 1 { settled = true; break } }
        last = key
    }
    if !settled { v.fill = false; v.why = "Electron page did not settle" }
    v.why += " [tree \(Int(Date().timeIntervalSince(t0) * 1000)) ms]"
    return v
}

// MARK: Filling

// The visible frame of the screen under the point, in Accessibility's space (top left origin).
func target(for p: CGPoint) -> CGRect? {
    guard let main = NSScreen.screens.first else { return nil }
    let h = main.frame.height
    let cocoa = CGPoint(x: p.x, y: h - p.y)
    guard let s = NSScreen.screens.first(where: { NSMouseInRect(cocoa, $0.frame, false) }) ?? NSScreen.main else { return nil }
    let f = s.visibleFrame
    return CGRect(x: f.minX, y: h - f.maxY, width: f.width, height: f.height)
}

func set(_ w: AXUIElement, _ r: CGRect) {
    var o = r.origin, z = r.size
    let pos = AXValueCreate(.cgPoint, &o)!, size = AXValueCreate(.cgSize, &z)!
    // Position first, so the size is not cut by the edge of where the window was; again after, because an app may
    // move a window it has just resized.
    AXUIElementSetAttributeValue(w, kAXPositionAttribute as CFString, pos)
    AXUIElementSetAttributeValue(w, kAXSizeAttribute as CFString, size)
    AXUIElementSetAttributeValue(w, kAXPositionAttribute as CFString, pos)
}

@discardableResult func fill(_ w: AXUIElement, at p: CGPoint) -> (before: CGRect?, after: CGRect?, goal: CGRect?) {
    let before = axFrame(w)
    // NSScreen belongs to the main thread; fills run on their own queue.
    let goal = Thread.isMainThread ? target(for: p) : DispatchQueue.main.sync { target(for: p) }
    guard let goal else { return (before, before, nil) }
    // With «enhanced user interface» on (VoiceOver, some window tools set it) apps animate a frame change and land on
    // the wrong size; it is turned off for the change and put back, as Rectangle and others do.
    var pid: pid_t = 0
    AXUIElementGetPid(w, &pid)
    let app = AXUIElementCreateApplication(pid)
    let enhanced = (attr(app, "AXEnhancedUserInterface") as? Bool) == true
    if enhanced { AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanFalse) }
    // A window whose size can't be set at all keeps it and is centred in the visible frame, as macOS's Fill does
    // (Calculator 230x408 -> 749,311 on a 0,0 1728x1030 visible frame, measured 27.2).
    let resizable = settable(w, kAXSizeAttribute)
    let to = resizable ? goal : before.map { centred($0.size, in: goal) } ?? goal
    if let before { animate(w, from: before, to: to, size: resizable) }
    if resizable { set(w, to) } else { place(w, to.origin) }
    // An app may hold its window smaller than asked: a fixed width (System Settings 740), an aspect ratio (Chess, Photo
    // Booth, QuickTime with a movie), a maximum size. macOS's Fill then centres the window in the visible frame
    // (measured 27.2: System Settings 494,0 740x1030, Photo Booth 159,0 1410x1030, QuickTime 0,29 1728x972); here it
    // slides there on the same spring.
    if resizable, let got = axFrame(w), got.width < goal.width - 1 || got.height < goal.height - 1 {
        var c = centred(got.size, in: goal)
        // One point short is not an app's limit but the system's: with the Dock shown, a size set through
        // Accessibility stops one point above the Dock (27.2, every app tried: Font Book, Safari, Books, App Store;
        // macOS's own Fill tile is not held by it); that side stays where the goal puts it.
        if goal.height - got.height <= 1 { c.origin.y = goal.minY }
        if goal.width - got.width <= 1 { c.origin.x = goal.minX }
        animate(w, from: got, to: c, size: false)
        place(w, c.origin)
    }
    if enhanced { AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue) }
    return (before, axFrame(w), goal)
}

// The frame of that size centred in r as macOS centres it: whole points, rounded down in its own bottom-left space
// (Digital Color Meter 217 pt tall in 1030 -> y 407, Grapher 351 -> 340, Chess 1331 wide in 1728 -> x 198; measured).
func centred(_ z: CGSize, in r: CGRect) -> CGRect {
    CGRect(x: r.minX + ((r.width - z.width) / 2).rounded(.down), y: r.maxY - z.height - ((r.height - z.height) / 2).rounded(.down),
           width: z.width, height: z.height)
}

func place(_ w: AXUIElement, _ o: CGPoint) {
    var o = o
    AXUIElementSetAttributeValue(w, kAXPositionAttribute as CFString, AXValueCreate(.cgPoint, &o)!)
}

// macOS's own fill (a title-bar double-click set to Fill, or a window dragged to the top edge) moves the frame on a
// critically damped spring: position and size together, fast at first, settling softly, about 0.34 s. Measured frame
// by frame on 27.2: progress = 1 - (1 + ωt)·e^(-ωt) with ω = 27 per second fits it within 1 %.
// The same curve is played here by setting the frame through Accessibility about 120 times a second. An app that
// takes too long to follow (one step over 60 ms) gets the final frame at once instead: a slow resize would stutter.
func animate(_ w: AXUIElement, from a: CGRect, to b: CGRect, size: Bool = true) {
    let omega = 27.0, length = 0.34, tick = 1.0 / 120
    if a == b { return }
    let t0 = Date()
    var next = 0.0
    while true {
        let t = Date().timeIntervalSince(t0)
        if t >= length { return }
        let k = 1 - (1 + omega * t) * exp(-omega * t)
        let r = CGRect(x: a.minX + (b.minX - a.minX) * k, y: a.minY + (b.minY - a.minY) * k,
                       width: a.width + (b.width - a.width) * k, height: a.height + (b.height - a.height) * k).integral
        let s0 = Date()
        var o = r.origin, z = r.size
        // Growing: the size first would push the window past the screen's edge for a moment; so the position first
        // (the window only grows toward the target), then the size.
        AXUIElementSetAttributeValue(w, kAXPositionAttribute as CFString, AXValueCreate(.cgPoint, &o)!)
        if size { AXUIElementSetAttributeValue(w, kAXSizeAttribute as CFString, AXValueCreate(.cgSize, &z)!) }
        if Date().timeIntervalSince(s0) > 0.06 { trace("  slow app: rest of the animation skipped"); return }
        next += tick
        let wait = next - Date().timeIntervalSince(t0)
        if wait > 0 { usleep(useconds_t(wait * 1_000_000)) }
    }
}

func trace(_ s: @autoclosure () -> String) {
    #if TRACE
    FileHandle.standardError.write((s() + "\n").data(using: .utf8)!)
    #endif
}

func describe(_ r: CGRect?) -> String {
    guard let r else { return "-" }
    return "\(Int(r.minX)),\(Int(r.minY)) \(Int(r.width))x\(Int(r.height))"
}

// MARK: Watching the clicks

// A listen-only tap: the clicks go on to the app as they are, and nothing waits for this code. The second click's
// press is remembered, and the window is filled when it is let go near the same spot (a double-click that turns into a
// drag is left alone). The decision runs after the event has gone on.
private var tapPort: CFMachPort?
// One double-click handled at a time, off the main thread: a fill takes about 0.34 s and must not hold the app.
let work = DispatchQueue(label: "fill")
private var secondDown: CGPoint?

@MainActor func startTap() -> Bool {
    let mask = (1 << CGEventType.leftMouseDown.rawValue) | (1 << CGEventType.leftMouseUp.rawValue)
    guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly,
                                       eventsOfInterest: CGEventMask(mask), callback: { _, type, event, _ in
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tapPort { CGEvent.tapEnable(tap: tapPort, enable: true) }
        case .leftMouseDown:
            let mods = event.flags.intersection([.maskCommand, .maskAlternate, .maskControl, .maskShift])
            // Clicks with a modifier key belong to the apps.
            secondDown = event.getIntegerValueField(.mouseEventClickState) == 2 && mods.isEmpty ? event.location : nil
        case .leftMouseUp:
            if let d = secondDown, event.getIntegerValueField(.mouseEventClickState) == 2,
               hypot(event.location.x - d.x, event.location.y - d.y) < 4 {
                work.async { act(at: d) }
            }
            secondDown = nil
        default: break
        }
        return Unmanaged.passUnretained(event)
    }, userInfo: nil) else { return false }
    tapPort = port
    CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, port, 0), .commonModes)
    return true
}

func act(at p: CGPoint) {
    let t = Date()
    var v = judge(p)
    if v.needsWebTree { v = judgeWithPage(p, v) }
    trace("double-click \(Int(p.x)),\(Int(p.y)): \(v.fill ? "FILL" : "skip") \(v.why) [\(v.chain.joined(separator: " < "))] \(Int(Date().timeIntervalSince(t) * 1000)) ms")
    guard v.fill, let w = v.window else { return }
    let r = fill(w, at: p)
    trace("  \(describe(r.before)) -> \(describe(r.after)) (goal \(describe(r.goal)))")
}

// MARK: The app

@MainActor final class App: NSObject, NSApplicationDelegate {
    var window: AppWindow?
    var tapOn = false
    let launched = ProcessInfo.processInfo.systemUptime

    func applicationDidFinishLaunching(_ n: Notification) {
        #if TRACE
        // Test builds: --probe X Y prints what a double-click at that point would do and quits; --fill X Y also does it.
        let args = CommandLine.arguments
        // --scan X0 Y0 X1 Y1 STEP: a map of the area, one letter per point (F fill, c a control, w below the title bar,
        // s not a standard window, o anything else), then every distinct reason with its first point.
        if let i = args.firstIndex(of: "--scan"), i + 5 < args.count {
            let n = args[(i + 1)...(i + 5)].compactMap { Double($0) }
            var seen: [String: String] = [:], order: [String] = [], all: [String: [String]] = [:]
            for y in stride(from: n[1], through: n[3], by: n[4]) {
                var line = String(format: "%5d ", Int(y))
                for x in stride(from: n[0], through: n[2], by: n[4]) {
                    let v = judge(CGPoint(x: x, y: y))
                    let key = "\(v.fill ? "FILL" : "skip") \(v.why.replacingOccurrences(of: #"\d+ pt"#, with: "N pt", options: .regularExpression)) [\(v.chain.joined(separator: " < "))]"
                    if seen[key] == nil { seen[key] = "\(Int(x)),\(Int(y))"; order.append(key) }
                    all[key, default: []].append("\(Int(x)),\(Int(y))")
                    line += v.fill ? "F" : v.why.hasPrefix("on a control") ? "c" : v.why.hasPrefix("below") ? "w" : v.why.hasPrefix("not a standard") ? "s" : "o"
                }
                print(line)
            }
            // Each reason with its first point, a middle one and how many points answered so (the matrix picks its spots here).
            for k in order { let l = all[k]!; print("\(seen[k]!)\t\(l[l.count / 2])\t\(l.count)\t\(k)") }
            exit(0)
        }
        for flag in ["--probe", "--fill"] {
            if let i = args.firstIndex(of: flag), i + 2 < args.count, let x = Double(args[i + 1]), let y = Double(args[i + 2]) {
                let p = CGPoint(x: x, y: y)
                var v = judge(p)
                if v.needsWebTree { v = judgeWithPage(p, v) }
                print("\(Int(x)),\(Int(y))\t\(v.fill ? "FILL" : "skip")\t\(v.why)\t\(v.chain.joined(separator: " < "))\ttrusted=\(AXIsProcessTrusted())")
                if flag == "--fill", v.fill, let w = v.window {
                    let r = fill(w, at: p)
                    print("\(describe(r.before)) -> \(describe(r.after)) goal \(describe(r.goal))")
                }
                exit(0)
            }
        }
        #endif
        window = AppWindow(name: Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Fully",
                           github: "https://github.com/geragarazagh/fully", extra: DoubleClickRow())
        window?.onShow = { [weak self] in self?.askAccess() }
        tryTap()
    }

    // macOS's own question, which leads to Privacy & Security; asked again whenever the window is opened without the grant.
    func askAccess() {
        guard !AXIsProcessTrusted() else { return }
        AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
    }

    // Accessibility can be granted at any moment, and macOS tells nobody. On macOS 27 a running process also keeps the
    // answer it got first: AXIsProcessTrusted stays false after the grant, and only a process started after it sees
    // it (measured on Copia in a 27.2 test machine, 2026-11-15). So a fresh copy of the app is asked every 3 seconds,
    // and once it says yes the app starts itself again.
    func tryTap() {
        guard !tapOn else { return }
        if AXIsProcessTrusted() && startTap() { tapOn = true; trace("tap on"); return }
        if !CommandLine.arguments.contains("--background") || window?.panel.isVisible == true { askAccessOnce() }
        // A copy started by relaunch() never starts another in its first minute: should the fresh copy and this process
        // ever disagree, the app would otherwise restart every 3 seconds. And only a process that is itself not trusted
        // restarts: one that is trusted but could not start the tap would otherwise restart every minute for good (the
        // fresh copy says yes, the tap fails again); it tries the tap again every 3 s instead.
        let justRelaunched = CommandLine.arguments.contains("--relaunched") && ProcessInfo.processInfo.systemUptime - launched < 60
        if !AXIsProcessTrusted() && !justRelaunched && freshCopyHasAccess() { relaunch(); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.tryTap() }
    }

    func freshCopyHasAccess() -> Bool {
        let p = Process()
        p.executableURL = Bundle.main.executableURL
        p.arguments = ["--has-access"]
        p.environment = [:]
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    func relaunch() {
        trace("access granted: starting again")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-n", "-g", Bundle.main.bundlePath, "--args", "--relaunched"] + (window?.panel.isVisible == true ? [] : ["--background"])
        try? p.run()
        p.waitUntilExit()
        exit(0)
    }
    private var asked = false
    private func askAccessOnce() { if !asked { asked = true; askAccess() } }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { window?.show(); return false }

    // A fill or an Electron check in flight has switched another app's AXEnhancedUserInterface off or its
    // AXManualAccessibility on; quitting then (Quit, or Sparkle installing an update) would leave it so. The app quits
    // once the fill queue is idle (a fill takes about 0.34 s). Not work.sync here: a fill asks the main thread for the
    // screen (fill, DispatchQueue.main.sync) and the two would wait for each other.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        work.async { DispatchQueue.main.async { NSApp.reply(toApplicationShouldTerminate: true) } }
        return .terminateLater
    }
}

// The one row of its own: what macOS itself does on a title-bar double-click. Anything but None makes macOS act too
// (Fill would make its tile, the very thing this app replaces), so the row says so and leads to the setting
// (Desktop & Dock, «Window title bar double-click action», on macOS 13-15 «Double-click a window's title bar to»).
@MainActor final class DoubleClickRow: NSView {
    let label = NSTextField(labelWithString: "")
    let button = NSButton(title: L("Change…"), target: nil, action: nil)

    init() {
        let W: CGFloat = 340, M: CGFloat = 20
        super.init(frame: NSRect(x: 0, y: 0, width: W, height: 34))
        label.font = .systemFont(ofSize: 13); label.frame = NSRect(x: M, y: 9, width: 230, height: 18)
        addSubview(label)
        button.bezelStyle = .rounded; button.controlSize = .small; button.font = .systemFont(ofSize: 11)
        button.refusesFirstResponder = true; button.target = self; button.action = #selector(open)
        button.sizeToFit(); button.frame.origin = NSPoint(x: W - M - button.frame.width, y: 7)
        addSubview(button)
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }

    // The values macOS stores, with the names System Settings shows for them (DesktopSettings.appex, its English
    // .loctable). None is «Do Nothing» up to macOS 15 and «No Action» since 26 (read in the test machines,
    // 13.7, 14.8, 15.7, 26.6 and 27.2, 2026-11-17); the stored values are the same on all (Fill exists since 15).
    func refresh() {
        let renamed = ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0))
        let names = ["None": renamed ? "No Action" : "Do Nothing", "Fill": "Fill", "Maximize": "Zoom", "Minimize": "Minimize"]
        // Read fresh each time: the value is changed in System Settings while this app runs.
        CFPreferencesAppSynchronize(kCFPreferencesAnyApplication)
        let raw = CFPreferencesCopyAppValue("AppleActionOnDoubleClick" as CFString, kCFPreferencesAnyApplication) as? String
        // No value at all acts as Zoom (measured on 27.2: Finder zoomed to its content, a filled window kept its size).
        let name = raw.map { names[$0] ?? $0 } ?? "Zoom"
        label.stringValue = "\(L("macOS double-click")): \(name)"
        label.textColor = raw == "None" ? .labelColor : .systemRed
        button.isHidden = raw == "None"
    }

    @objc func open() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Desktop-Settings.extension")!)
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = App()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
