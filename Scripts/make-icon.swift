// Draws the placeholder app icon and writes Resources/AppIcon.icns.
// Usage: swift Scripts/make-icon.swift   (run from the repository's top folder)
//
// The icon is a stand-in until a final design exists: a dark rounded square, a pair of
// braces in the app's accent gradient, and a play triangle between them.
import AppKit

let side: CGFloat = 1024

func drawIcon() -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(side), pixelsHigh: Int(side), bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let context = NSGraphicsContext.current!.cgContext

    // macOS icons sit inside the canvas with a margin, on a rounded square.
    let plate = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: plate, cornerWidth: 185, cornerHeight: 185, transform: nil)

    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    context.addPath(shape)
    context.setFillColor(NSColor(red: 0.07, green: 0.09, blue: 0.13, alpha: 1).cgColor)
    context.fillPath()
    context.restoreGState()

    let space = CGColorSpaceCreateDeviceRGB()
    func gradient(_ colours: [NSColor]) -> CGGradient {
        CGGradient(colorsSpace: space, colors: colours.map(\.cgColor) as CFArray, locations: nil)!
    }
    let teal = NSColor(red: 0x1F / 255, green: 0xE0 / 255, blue: 0xB5 / 255, alpha: 1)
    let blue = NSColor(red: 0x21 / 255, green: 0xB4 / 255, blue: 0xFF / 255, alpha: 1)

    // The plate: nearly black at the bottom, a little lighter at the top, with a soft glow.
    context.saveGState()
    context.addPath(shape)
    context.clip()
    context.drawLinearGradient(
        gradient([NSColor(red: 0.13, green: 0.16, blue: 0.23, alpha: 1), NSColor(red: 0.05, green: 0.06, blue: 0.09, alpha: 1)]),
        start: CGPoint(x: 512, y: plate.maxY), end: CGPoint(x: 512, y: plate.minY), options: []
    )
    context.drawRadialGradient(
        gradient([teal.withAlphaComponent(0.28), teal.withAlphaComponent(0)]),
        startCenter: CGPoint(x: 512, y: 512), startRadius: 0, endCenter: CGPoint(x: 512, y: 512), endRadius: 420, options: []
    )
    context.restoreGState()

    // The braces, filled with the accent gradient.
    let font = NSFont.systemFont(ofSize: 560, weight: .bold)
    func glyphPath(_ text: String, centredAt x: CGFloat) -> CGPath {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
        let path = CGMutablePath()
        for run in CTLineGetGlyphRuns(line) as! [CTRun] {
            let runFont = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName] as! CTFont
            for index in 0..<CTRunGetGlyphCount(run) {
                var glyph = CGGlyph()
                var position = CGPoint.zero
                CTRunGetGlyphs(run, CFRange(location: index, length: 1), &glyph)
                CTRunGetPositions(run, CFRange(location: index, length: 1), &position)
                if let outline = CTFontCreatePathForGlyph(runFont, glyph, nil) {
                    path.addPath(outline, transform: CGAffineTransform(translationX: position.x, y: position.y))
                }
            }
        }
        let box = path.boundingBoxOfPath
        var move = CGAffineTransform(translationX: x - box.midX, y: 512 - box.midY)
        return path.copy(using: &move)!
    }
    let braces = CGMutablePath()
    braces.addPath(glyphPath("{", centredAt: 300))
    braces.addPath(glyphPath("}", centredAt: 724))
    context.saveGState()
    context.addPath(braces)
    context.clip()
    context.drawLinearGradient(gradient([teal, blue]), start: CGPoint(x: 200, y: 800), end: CGPoint(x: 824, y: 224), options: [])
    context.restoreGState()

    // The play triangle, with rounded corners.
    let triangle = CGMutablePath()
    triangle.move(to: CGPoint(x: 450, y: 618))
    triangle.addLine(to: CGPoint(x: 450, y: 406))
    triangle.addLine(to: CGPoint(x: 624, y: 512))
    triangle.closeSubpath()
    context.saveGState()
    context.setLineJoin(.round)
    context.setLineWidth(44)
    context.setStrokeColor(NSColor.white.cgColor)
    context.setFillColor(NSColor.white.cgColor)
    context.addPath(triangle)
    context.drawPath(using: .fillStroke)
    context.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func resized(_ source: NSBitmapImageRep, to pixels: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current!.imageInterpolation = .high
    source.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
let resources = URL(fileURLWithPath: "Resources", isDirectory: true)
let iconset = fm.temporaryDirectory.appendingPathComponent("AppIcon-\(UUID().uuidString).iconset", isDirectory: true)
try fm.createDirectory(at: resources, withIntermediateDirectories: true)
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: iconset) }

let master = drawIcon()
for points in [16, 32, 128, 256, 512] {
    try resized(master, to: points).write(to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    try resized(master, to: points * 2).write(to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}
try resized(master, to: 1024).write(to: resources.appendingPathComponent("AppIcon.png"))

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", resources.appendingPathComponent("AppIcon.icns").path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fatalError("iconutil could not make the icon file.") }
print("Wrote Resources/AppIcon.icns and Resources/AppIcon.png")
