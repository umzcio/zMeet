import AppKit

/// Resolves the per-meeting glyph: the real Zoom/Teams app icon when the
/// meeting was detected from one of those apps, otherwise a generic zMeet mark.
@MainActor
enum SourceAppIcons {
    /// Cache keyed by bundle id (or "generic") so the icon isn't fetched from disk
    /// on every SwiftUI render — these are read for every rail/search/header row.
    /// A miss (app not installed, e.g. a browser-based Zoom/Teams call) is cached
    /// too, under the requested id, so the LaunchServices lookup isn't repeated
    /// on every render — invalidated below if the app is later launched.
    private static var cache: [String: NSImage] = [:]
    private static var observingLaunches = false

    /// Resolves the meeting glyph. Prefers the recorded `sourceApp`; when that's
    /// missing (older sessions), falls back to sniffing the title for Zoom/Teams.
    static func icon(for sourceApp: String?, title: String? = nil) -> NSImage {
        observeLaunchesIfNeeded()
        if let id = bundleIdentifier(sourceApp: sourceApp, title: title) {
            if let cached = cache[id] { return cached }
            if let url = appURL(for: id) {
                let img = NSWorkspace.shared.icon(forFile: url.path)
                img.size = NSSize(width: 20, height: 20)
                cache[id] = img
                return img
            }
            // Not installed: cache the generic icon under this id so the miss
            // (a LaunchServices lookup, doubled for Teams's two candidate ids)
            // doesn't repeat on every rail/search/header render.
            let generic = genericIcon()
            cache[id] = generic
            return generic
        }
        if let cached = cache["generic"] { return cached }
        let generic = genericIcon()
        cache["generic"] = generic
        return generic
    }

    /// Installing/launching an app mid-session should stop showing the generic
    /// fallback — clear the cache once so the next lookup re-resolves it.
    private static func observeLaunchesIfNeeded() {
        guard !observingLaunches else { return }
        observingLaunches = true
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { cache.removeAll() }
        }
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
