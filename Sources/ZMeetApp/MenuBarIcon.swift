import AppKit
import ZMeetCore

/// Renders the menu-bar status icon from Zach's mic-with-z-badge artwork (see
/// `MenuBarIconStyle` for which look each state gets). The layers are generated
/// by scripts/make-menubar-icon.py and copied into the app's Resources by
/// build-app.sh; when they're missing (a bare `swift run`), the older SF Symbol
/// icons are drawn instead.
@MainActor
enum MenuBarIcon {
    /// Per-state VoiceOver description — the menu-bar icon is the app's one
    /// persistent status surface, so this must actually distinguish state
    /// rather than repeat a generic "zMeet" for idle/recording/processing.
    static func accessibilityDescription(for state: StatusIconState) -> String {
        switch state {
        case .idle: "zMeet — idle"
        case .meetingDetected: "zMeet — meeting detected, not recording"
        case .recording: "zMeet — recording"
        case .processing: "zMeet — processing notes"
        }
    }

    /// The icon's shape and its z, as black alpha masks (1x + @2x each).
    private static let shape = Bundle.main.image(forResource: "MenuBarIcon")
    private static let zLayer = Bundle.main.image(forResource: "MenuBarIconZ")
    /// The green of Zach's colored artwork.
    private static let artworkGreen = NSColor(srgbRed: 0x5C / 255.0, green: 0xA5 / 255.0, blue: 0, alpha: 1)

    static func image(for state: StatusIconState) -> NSImage {
        let description = accessibilityDescription(for: state)
        guard let shape, let zLayer else { return symbolImage(for: state, description: description) }
        let green = artworkGreen
        let image: NSImage
        switch MenuBarIconStyle.style(for: state) {
        case .plain:
            // A template: macOS tints it to match the menu bar, like any system icon.
            image = shape.copy() as? NSImage ?? shape
            image.isTemplate = true
        case .plainWithDot:
            image = composite(size: shape.size) { rect in
                fill(shape, with: .labelColor, in: rect)
                green.setFill()
                NSBezierPath(ovalIn: dotRect(in: rect)).fill()
            }
        case .greenZ:
            image = composite(size: shape.size) { rect in
                fill(shape, with: .labelColor, in: rect)
                fill(zLayer, with: green, in: rect)
            }
        }
        image.accessibilityDescription = description
        return image
    }

    /// A non-template image, redrawn whenever AppKit draws it. `labelColor`
    /// resolves against the menu bar's appearance at that moment, so the mic still
    /// follows light/dark mode while the green stays green (a template can't mix).
    private static func composite(size: NSSize, _ draw: @escaping (NSRect) -> Void) -> NSImage {
        let image = NSImage(size: size, flipped: false) { rect in
            draw(rect)
            return true
        }
        image.isTemplate = false
        return image
    }

    /// Paints a black alpha mask with `color`, inside its own transparency layer so
    /// the tint only lands on the mask — not on anything drawn before it.
    nonisolated private static func fill(_ mask: NSImage, with color: NSColor, in rect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        mask.draw(in: rect)
        color.setFill()
        rect.fill(using: .sourceAtop)
        context.endTransparencyLayer()
    }

    /// The "meeting detected" dot: 4.5pt, tucked into the empty top-right corner of
    /// the artwork, clear of the mic head and the badge.
    nonisolated private static func dotRect(in rect: NSRect) -> NSRect {
        let diameter: CGFloat = 4.5
        return NSRect(x: rect.maxX - diameter - 0.5, y: rect.maxY - diameter - 0.5,
                      width: diameter, height: diameter)
    }

    /// The previous SF Symbol icons — used only when the artwork isn't bundled.
    private static func symbolImage(for state: StatusIconState, description: String) -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
        switch state {
        case .idle:
            let mic = symbol("mic.fill", fallback: "mic", description: description).withSymbolConfiguration(config)
                ?? symbol("mic.fill", fallback: "mic", description: description)
            mic.isTemplate = true
            mic.accessibilityDescription = description
            return mic
        case .meetingDetected:
            // Template, like idle, so it sits naturally in the menu bar — the badge
            // shape (not color) says "there's a meeting here you can record".
            let badged = symbol("mic.badge.plus", fallback: "mic.fill", description: description)
                .withSymbolConfiguration(config)
                ?? symbol("mic.badge.plus", fallback: "mic.fill", description: description)
            badged.isTemplate = true
            badged.accessibilityDescription = description
            return badged
        case .recording:
            let base = symbol(recordingSymbolName, fallback: "mic.fill", description: description)
            let red = base.withSymbolConfiguration(config.applying(.init(paletteColors: [.systemRed]))) ?? base
            red.isTemplate = false
            red.accessibilityDescription = description
            return red
        case .processing:
            let base = symbol("wand.and.stars", fallback: "gearshape.fill", description: description)
            let tinted = base.withSymbolConfiguration(config.applying(.init(paletteColors: [ZMeetPalette.mintNS]))) ?? base
            tinted.isTemplate = false
            tinted.accessibilityDescription = description
            return tinted
        }
    }

    private static var recordingSymbolName: String {
        for name in ["waveform.badge.mic", "mic.and.signal.meter.fill", "mic.fill"] {
            if NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil { return name }
        }
        return "mic.fill"
    }

    private static func symbol(_ name: String, fallback: String, description: String) -> NSImage {
        NSImage(systemSymbolName: name, accessibilityDescription: description)
            ?? NSImage(systemSymbolName: fallback, accessibilityDescription: description)
            ?? NSImage()
    }
}
