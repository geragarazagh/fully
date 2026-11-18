// Fully's icon: a window grows to the edge of the plate in four even steps, the last outline being the plate's own
// edge: two clicks, and the window reaches the edge.
// Only the picture is drawn, light.png and dark.png, 1024 px, transparent; the plate is the system's own fill
// (./build writes icon.json and runs actool).
// Usage: icon <dir> <plate.png>   plate.png: an empty icon rendered by Icon Composer's ictool (./build makes it), whose
// alpha is the plate's exact shape; the picture maps onto the plate 1:1 (measured: a 1024 frame lands on its edges).
//
// The numbers. One grammar, a real macOS window at 3 px per pt: 32 pt title bar = 96 px, 14 pt buttons = 42 px with
// 9 pt = 27 px of air to the frame, between them, above and below them (macOS's own title bar, where edge, gaps and
// margins are all 9 pt), corner 16 pt = 48 px. Every line is on the 8 px grid, so each is a whole device pixel at the
// Dock's 128 px: frame 32 px (4), title-bar line and outlines 16 px (2). The window is 512 x 512 in the middle of the
// plate; the outlines are the window at p = 1/4, 1/2, 3/4 of the way to the plate (position, size and corner linear in
// p, the corner going from 48 px to the plate's 229 px), and p = 1 is the plate's edge itself. Square and centred, so
// every side moves by the same 64 px at every step (8 device px at the Dock): the steps are even everywhere, in both
// themes. Outlines at 40 % of the ink, the window and its buttons in full ink, the buttons unlit (one colour).
import AppKit

let S: CGFloat = 1024, s: CGFloat = 3, frameW: CGFloat = 32, thinW: CGFloat = 16
let out = CommandLine.arguments[1]
let plate = NSImage(contentsOfFile: CommandLine.arguments[2])!

func canvas(_ path: String, _ body: () -> Void) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    body()
    NSGraphicsContext.current = nil
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

// Drawn opaque in a layer that takes the ink's alpha, so lines that meet don't add up (the dark ink is 0.92 white).
func layer(_ tint: NSColor, _ body: (NSColor) -> Void) {
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.saveGState(); ctx.setAlpha(tint.alphaComponent); ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    body(tint.withAlphaComponent(1))
    ctx.endTransparencyLayer(); ctx.restoreGState()
}

func window(_ r: NSRect, _ ink: NSColor) {
    ink.setStroke(); ink.setFill()
    let f = NSBezierPath(roundedRect: r.insetBy(dx: frameW/2, dy: frameW/2), xRadius: 16 * s - frameW/2, yRadius: 16 * s - frameW/2)
    f.lineWidth = frameW; f.stroke()
    let top = r.maxY - frameW, left = r.minX + frameW          // the frame's inner edges
    let barY = top - 32 * s - thinW / 2                         // 9 + 14 + 9 pt of bar inside, then the line
    let bar = NSBezierPath(); bar.move(to: NSPoint(x: left, y: barY)); bar.line(to: NSPoint(x: r.maxX - frameW, y: barY))
    bar.lineWidth = thinW; bar.stroke()
    for k in 0..<3 {
        let x = left + 9 * s + CGFloat(k) * 23 * s, y = top - 23 * s
        NSBezierPath(ovalIn: NSRect(x: x, y: y, width: 14 * s, height: 14 * s)).fill()
    }
}

// The plate's own edge as a ring w px wide: the plate minus the same shape w px in from every side.
func plateRing(_ ink: NSColor, _ w: CGFloat) {
    let all = NSRect(x: 0, y: 0, width: S, height: S)
    plate.draw(in: all, from: .zero, operation: .sourceOver, fraction: 1)
    ink.setFill(); all.fill(using: .sourceIn)
    plate.draw(in: all.insetBy(dx: w, dy: w), from: .zero, operation: .destinationOut, fraction: 1)
}

let w0 = NSRect(x: 256, y: 256, width: 512, height: 512)
for (file, ink) in [("light.png", NSColor(srgbRed: 0x1C/255, green: 0x1C/255, blue: 0x1E/255, alpha: 1)),
                    ("dark.png", NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.92))] {
    canvas("\(out)/\(file)") {
        layer(ink.withAlphaComponent(ink.alphaComponent * 0.4)) { ghost in
            ghost.setStroke()
            for k in 1...3 {
                let p = CGFloat(k) / 4
                let r = NSRect(x: w0.minX * (1 - p), y: w0.minY * (1 - p),
                               width: w0.width + (S - w0.width) * p, height: w0.height + (S - w0.height) * p)
                let rad = 48 + (229 - 48) * p - thinW/2
                let b = NSBezierPath(roundedRect: r.insetBy(dx: thinW/2, dy: thinW/2), xRadius: rad, yRadius: rad)
                b.lineWidth = thinW; b.stroke()
            }
        }
        layer(ink.withAlphaComponent(ink.alphaComponent * 0.4)) { plateRing($0, thinW) }   // its own layer: it erases inside
        layer(ink) { window(w0, $0) }
    }
}
