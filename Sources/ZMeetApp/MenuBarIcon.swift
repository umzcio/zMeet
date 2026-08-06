import AppKit

/// Renders the menu-bar status icon. Idle = plain template mic; recording = red
/// mic-in-waveform; processing = mint wand (notes being generated).
enum MenuBarIcon {
    enum State { case idle, recording, processing }

    /// Per-state VoiceOver description — the menu-bar icon is the app's one
    /// persistent status surface, so this must actually distinguish state
    /// rather than repeat a generic "zMeet" for idle/recording/processing.
    static func accessibilityDescription(for state: State) -> String {
        switch state {
        case .idle: "zMeet — idle"
        case .recording: "zMeet — recording"
        case .processing: "zMeet — processing notes"
        }
    }

    static func image(for state: State) -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
        let description = accessibilityDescription(for: state)
        switch state {
        case .idle:
            let mic = symbol("mic.fill", fallback: "mic", description: description).withSymbolConfiguration(config)
                ?? symbol("mic.fill", fallback: "mic", description: description)
            mic.isTemplate = true
            mic.accessibilityDescription = description
            return mic
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
