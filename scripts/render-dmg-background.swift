import AppKit

// DMG background for the zMeet installer window, drawn by make-dmg.sh.
// Finder layout coordinates are in points (make-dmg.sh places the icons at the
// matching positions); a 2× PNG keeps the artwork crisp on Retina displays.
// Usage: swift scripts/render-dmg-background.swift output.png assets/brand/ZMark@2x.png
let size = NSSize(width: 720, height: 440)
let scale = 2
guard CommandLine.arguments.count == 3,
      let mark = NSImage(contentsOfFile: CommandLine.arguments[2]),
      let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width) * scale,
                                    pixelsHigh: Int(size.height) * scale, bitsPerSample: 8,
                                    samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
      let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
    fatalError("Usage: swift scripts/render-dmg-background.swift output.png path/to/ZMark@2x.png")
}
bitmap.size = size
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
context.cgContext.scaleBy(x: CGFloat(scale), y: CGFloat(scale))

func color(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
            green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: alpha)
}
// zMeet palette: near-black base (ZMeetPalette.bg family), the brand green from
// the z mark and app icon for accents, pale mint text (ZMeetPalette.light).
let brandGreen = color(0x66B800)
let light = color(0xEAF3EE)
let muted = color(0x8A9B92)
let bounds = NSRect(origin: .zero, size: size)
NSGradient(colors: [color(0x0B100E), color(0x0F1D17)])!.draw(in: bounds, angle: 90)

func centeredText(_ text: String, top: CGFloat, font: NSFont, tint: NSColor) {
    let style = NSMutableParagraphStyle()
    style.alignment = .center
    let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: tint, .paragraphStyle: style]
    (text as NSString).draw(in: NSRect(x: 30, y: size.height - top - 40, width: size.width - 60, height: 40),
                            withAttributes: attributes)
}

// Accent bar over the wordmark.
brandGreen.withAlphaComponent(0.9).setFill()
NSBezierPath(roundedRect: NSRect(x: 344, y: 393, width: 32, height: 3), xRadius: 1.5, yRadius: 1.5).fill()

// Wordmark: the brand z mark followed by "Meet", centered as one unit (matches
// the app's ZMeetWordmark).
let meet = NSAttributedString(string: "Meet", attributes: [
    .font: NSFont.systemFont(ofSize: 30, weight: .semibold), .foregroundColor: light,
])
let markHeight: CGFloat = 36
let markWidth = markHeight * mark.size.width / mark.size.height
let gap: CGFloat = 6
let meetSize = meet.size()
let totalWidth = markWidth + gap + meetSize.width
let originX = (size.width - totalWidth) / 2
let wordmarkMidY = size.height - 88
mark.draw(in: NSRect(x: originX, y: wordmarkMidY - markHeight / 2 - 3, width: markWidth, height: markHeight))
meet.draw(at: NSPoint(x: originX + markWidth + gap, y: wordmarkMidY - meetSize.height / 2))

// The arrow is artwork; both the app and Applications icons stay real draggable items.
let arrowY: CGFloat = size.height - 218
let arrow = NSBezierPath()
arrow.move(to: NSPoint(x: 334, y: arrowY))
arrow.line(to: NSPoint(x: 386, y: arrowY))
arrow.move(to: NSPoint(x: 376, y: arrowY + 10))
arrow.line(to: NSPoint(x: 386, y: arrowY))
arrow.line(to: NSPoint(x: 376, y: arrowY - 10))
arrow.lineWidth = 2
arrow.lineCapStyle = .round
arrow.lineJoinStyle = .round
brandGreen.withAlphaComponent(0.8).setStroke()
arrow.stroke()

// Finder always draws dark filename text over a custom picture; pale pills behind
// the real filenames keep them readable without faking the labels.
light.setFill()
for (centerX, width): (CGFloat, CGFloat) in [(200, 90), (520, 140)] {
    NSBezierPath(roundedRect: NSRect(x: centerX - width / 2, y: size.height - 309, width: width, height: 30),
                 xRadius: 10, yRadius: 10).fill()
}

centeredText("Drag zMeet to Applications.", top: 343,
             font: .systemFont(ofSize: 15, weight: .medium), tint: muted)
NSGraphicsContext.restoreGraphicsState()
guard let data = bitmap.representation(using: .png, properties: [:]) else { fatalError("Could not encode background") }
try data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
