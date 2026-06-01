import AppKit

/// Renders the menu-bar status icon. Idle = plain template mic; recording = red
/// mic-in-waveform; processing = mint wand (notes being generated).
enum MenuBarIcon {
    enum State { case idle, recording, processing }

    static func image(for state: State) -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
        switch state {
        case .idle:
            let mic = symbol("mic.fill", fallback: "mic").withSymbolConfiguration(config) ?? symbol("mic.fill", fallback: "mic")
            mic.isTemplate = true
            return mic
        case .recording:
            let base = symbol(recordingSymbolName, fallback: "mic.fill")
            let red = base.withSymbolConfiguration(config.applying(.init(paletteColors: [.systemRed]))) ?? base
            red.isTemplate = false
            return red
        case .processing:
            let base = symbol("wand.and.stars", fallback: "gearshape.fill")
            let mint = NSColor(red: 0.180, green: 0.878, blue: 0.541, alpha: 1)
            let tinted = base.withSymbolConfiguration(config.applying(.init(paletteColors: [mint]))) ?? base
            tinted.isTemplate = false
            return tinted
        }
    }

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
