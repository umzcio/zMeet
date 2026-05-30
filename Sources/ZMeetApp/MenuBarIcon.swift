import AppKit

/// Renders the menu-bar status icon. Idle is a plain mic (template image that
/// adapts to light/dark menu bars); recording is a mic wrapped in a waveform,
/// tinted red as a live indicator.
enum MenuBarIcon {
    static func image(recording: Bool) -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)

        if recording {
            let base = symbol(recordingSymbolName, fallback: "mic.fill")
            // Red, non-template so the tint survives in the menu bar.
            let red = base.withSymbolConfiguration(
                config.applying(.init(paletteColors: [.systemRed]))
            ) ?? base
            red.isTemplate = false
            return red
        }

        let mic = symbol("mic.fill", fallback: "mic")
            .withSymbolConfiguration(config) ?? symbol("mic.fill", fallback: "mic")
        mic.isTemplate = true
        return mic
    }

    /// The first available "mic + waveform" symbol across macOS versions.
    private static var recordingSymbolName: String {
        for name in ["waveform.badge.mic", "mic.and.signal.meter.fill", "mic.fill"] {
            if NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil { return name }
        }
        return "mic.fill"
    }

    private static func symbol(_ name: String, fallback: String) -> NSImage {
        NSImage(systemSymbolName: name, accessibilityDescription: "zMeet")
            ?? NSImage(systemSymbolName: fallback, accessibilityDescription: "zMeet")
            ?? NSImage()
    }
}
