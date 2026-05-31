import AppKit

/// Resolves the per-meeting glyph: the real Zoom/Teams app icon when the
/// meeting was detected from one of those apps, otherwise a generic zMeet mark.
@MainActor
enum SourceAppIcons {
    /// Cache keyed by bundle id (or "generic") so the icon isn't fetched from disk
    /// on every SwiftUI render — these are read for every rail/search/header row.
    private static var cache: [String: NSImage] = [:]

    /// Resolves the meeting glyph. Prefers the recorded `sourceApp`; when that's
    /// missing (older sessions), falls back to sniffing the title for Zoom/Teams.
    static func icon(for sourceApp: String?, title: String? = nil) -> NSImage {
        if let id = bundleIdentifier(sourceApp: sourceApp, title: title) {
            if let cached = cache[id] { return cached }
            if let url = appURL(for: id) {
                let img = NSWorkspace.shared.icon(forFile: url.path)
                img.size = NSSize(width: 20, height: 20)
                cache[id] = img
                return img
            }
        }
        if let cached = cache["generic"] { return cached }
        let generic = genericIcon()
        cache["generic"] = generic
        return generic
    }

    /// Map zMeet's source labels (set by the detector) to bundle ids, falling
    /// back to keywords in the meeting title.
    private static func bundleIdentifier(sourceApp: String?, title: String?) -> String? {
        let hay = "\(sourceApp ?? "") \(title ?? "")".lowercased()
        if hay.contains("zoom") {
            return "us.zoom.xos"
        }
        if hay.contains("teams") {
            return "com.microsoft.teams2"  // tried first; falls back below
        }
        return nil
    }

    /// Resolve an installed app URL, with a small fallback list for apps that
    /// changed bundle ids over time (e.g. new Teams).
    private static func appURL(for primaryID: String) -> URL? {
        let candidates: [String]
        switch primaryID {
        case "com.microsoft.teams2":
            candidates = [primaryID, "com.microsoft.teams"]
        default:
            candidates = [primaryID]
        }
        for id in candidates {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                return url
            }
        }
        return nil
    }

    private static func genericIcon() -> NSImage {
        let cfg = NSImage.SymbolConfiguration(pointSize: 16, weight: .semibold)
        let img = NSImage(systemSymbolName: "waveform.circle.fill", accessibilityDescription: "zMeet meeting")
            ?? NSImage()
        let configured = img.withSymbolConfiguration(cfg) ?? img
        configured.size = NSSize(width: 20, height: 20)
        return configured
    }
}
