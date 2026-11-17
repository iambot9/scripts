// Draws FocusBar.iconset: a tomato on a warm squircle, rendered natively at
// every size macOS asks for. Run by build.sh; iconutil turns the folder into
// FocusBar.icns.
//
//   swiftc make_icon.swift -o icongen && ./icongen FocusBar.iconset

import AppKit
import Foundation

_ = NSApplication.shared

// MARK: - Palette

func rgb(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: a)
}

let backTop = rgb(255, 250, 244)
let backBottom = rgb(255, 228, 211)
let tomatoLight = rgb(240, 85, 62)
let tomatoDeep = rgb(178, 32, 26)
let leafLight = rgb(104, 184, 92)
let leafDeep = rgb(44, 110, 58)
let stemColor = rgb(74, 128, 60)

// MARK: - Drawing

/// Everything is expressed against a 1024 grid, then scaled to the real size.
func draw(size: CGFloat) {
    let u = size / 1024

    func pt(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: x * u, y: y * u) }

    // Background squircle, on Apple's 824/1024 icon grid.
    let plate = NSRect(x: 100 * u, y: 100 * u, width: 824 * u, height: 824 * u)
    let platePath = NSBezierPath(roundedRect: plate, xRadius: 185 * u, yRadius: 185 * u)

    NSGraphicsContext.saveGraphicsState()
    if size >= 64 {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
        shadow.shadowOffset = NSSize(width: 0, height: -10 * u)
        shadow.shadowBlurRadius = 24 * u
        shadow.set()
    }
    NSGradient(starting: backTop, ending: backBottom)?.draw(in: platePath, angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    // Tomato body: a little wider than it is tall, sitting just below centre so
    // the calyx has room.
    let bodyCentre = pt(512, 470)
    let bodyW = 520 * u, bodyH = 470 * u
    let body = NSRect(x: bodyCentre.x - bodyW / 2, y: bodyCentre.y - bodyH / 2,
                      width: bodyW, height: bodyH)
    let bodyPath = NSBezierPath(ovalIn: body)
    NSGradient(starting: tomatoLight, ending: tomatoDeep)?.draw(in: bodyPath, angle: -75)

    // Soft shading along the bottom edge, for roundness.
    NSGraphicsContext.saveGraphicsState()
    bodyPath.addClip()
    let shade = NSBezierPath(ovalIn: body.insetBy(dx: -bodyW * 0.1, dy: -bodyH * 0.1)
        .offsetBy(dx: 0, dy: -bodyH * 0.62))
    NSGradient(starting: NSColor.black.withAlphaComponent(0.20),
               ending: NSColor.black.withAlphaComponent(0))?.draw(in: shade, angle: 90)
    NSGraphicsContext.restoreGraphicsState()

    // Highlight, skipped at the sizes where it would just be noise.
    if size >= 32 {
        NSGraphicsContext.saveGraphicsState()
        bodyPath.addClip()
        let gloss = NSBezierPath(ovalIn: NSRect(x: 0, y: 0, width: 190 * u, height: 120 * u))
        let spin = NSAffineTransform()
        spin.translateX(by: 300 * u, yBy: 560 * u)
        spin.rotate(byDegrees: -28)
        gloss.transform(using: spin as AffineTransform)
        NSGradient(starting: NSColor.white.withAlphaComponent(0.42),
                   ending: NSColor.white.withAlphaComponent(0))?.draw(in: gloss, angle: -60)
        NSGraphicsContext.restoreGraphicsState()
    }

    // Calyx: leaves radiating from the top of the fruit.
    let calyx = pt(512, 690)
    let leafGradient = NSGradient(starting: leafLight, ending: leafDeep)
    for step in 0..<5 {
        let angle = -90.0 + Double(step) * 72.0
        let leaf = NSBezierPath()
        leaf.move(to: .zero)
        leaf.curve(to: NSPoint(x: 210 * u, y: 0),
                   controlPoint1: NSPoint(x: 70 * u, y: 78 * u),
                   controlPoint2: NSPoint(x: 150 * u, y: 58 * u))
        leaf.curve(to: .zero,
                   controlPoint1: NSPoint(x: 150 * u, y: -58 * u),
                   controlPoint2: NSPoint(x: 70 * u, y: -78 * u))
        leaf.close()
        let place = NSAffineTransform()
        place.translateX(by: calyx.x, yBy: calyx.y)
        place.rotate(byDegrees: CGFloat(angle))
        leaf.transform(using: place as AffineTransform)
        leafGradient?.draw(in: leaf, angle: -90)
    }

    // Stem.
    let stem = NSBezierPath()
    stem.move(to: pt(478, 700))
    stem.curve(to: pt(520, 860),
               controlPoint1: pt(470, 780),
               controlPoint2: pt(492, 820))
    stem.curve(to: pt(566, 700),
               controlPoint1: pt(556, 822),
               controlPoint2: pt(574, 772))
    stem.close()
    stemColor.setFill()
    stem.fill()
}

// MARK: - Output

func render(_ size: Int) -> Data {
    let side = CGFloat(size)
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
    else { fatalError("could not allocate a \(size)px bitmap") }
    rep.size = NSSize(width: side, height: side)

    NSGraphicsContext.saveGraphicsState()
    guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else { fatalError("no context") }
    NSGraphicsContext.current = ctx
    ctx.imageInterpolation = .high
    ctx.shouldAntialias = true
    draw(size: side)
    ctx.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()

    guard let png = rep.representation(using: .png, properties: [:]) else {
        fatalError("could not encode a \(size)px PNG")
    }
    return png
}

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "FocusBar.iconset"
try? FileManager.default.removeItem(atPath: out)
try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

// name -> pixel size. Each is drawn natively rather than downsampled.
let wanted: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, px) in wanted {
    try render(px).write(to: URL(fileURLWithPath: "\(out)/\(name).png"))
}
print("Wrote \(wanted.count) PNGs to \(out)")
