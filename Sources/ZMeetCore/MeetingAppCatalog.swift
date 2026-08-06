/// The meeting apps zMeet detects, in one place: bundle-id prefixes (Core Audio
/// process matching — Teams audio runs in .helper processes so prefixes catch
/// them), window-owner matching, and title heuristics. Both detection tiers
/// MUST derive from this table so they can never disagree.
public struct MeetingAppCatalog: Sendable {
    public struct App: Sendable {
        public let name: String                   // human-readable
        public let bundlePrefixes: [String]       // process/audio matching
        public let windowOwnerExact: [String]     // exact owner names
        public let windowOwnerContains: [String]  // substring owner match (case-insensitive)
        public let titleMarkers: [String]         // meeting-window title words (case-insensitive)
        public let defaultTitle: String
    }

    public static let apps: [App] = [
        App(name: "Zoom", bundlePrefixes: ["us.zoom"],
            windowOwnerExact: ["zoom.us"], windowOwnerContains: [],
            titleMarkers: ["Meeting", "Webinar"], defaultTitle: "Zoom Meeting"),
        App(name: "Microsoft Teams", bundlePrefixes: ["com.microsoft.teams"],
            windowOwnerExact: ["MSTeams"], windowOwnerContains: ["Microsoft Teams"],
            titleMarkers: ["Meeting", "Call"], defaultTitle: "Teams Meeting"),
    ]

    /// Bundle-ID prefix match (first match wins), used to gate the cheap process-running
    /// check and to name the app behind an active Core Audio process.
    public static func appMatching(bundleID: String) -> App? {
        apps.first { app in app.bundlePrefixes.contains { bundleID.hasPrefix($0) } }
    }

    /// Window-tier matcher: (app name, meeting title) when owner+title indicate an
    /// ACTIVE meeting window; nil otherwise. Case-insensitive title markers.
    ///
    /// Reproduces `MeetingDetector.detectMeeting()`'s original per-window checks
    /// exactly, including one unreachable branch: `title.isEmpty ? defaultTitle : title`
    /// can never actually pick `defaultTitle`, because reaching this return already
    /// required `title` to contain one of `titleMarkers` (an empty string contains no
    /// marker). Preserved faithfully rather than "fixed" — see plan 041's STOP condition.
    public static func matchMeetingWindow(owner: String, title: String) -> (app: String, title: String)? {
        for app in apps {
            let ownerMatches = app.windowOwnerExact.contains(owner)
                || app.windowOwnerContains.contains { owner.localizedCaseInsensitiveContains($0) }
            guard ownerMatches else { continue }
            guard app.titleMarkers.contains(where: { title.localizedCaseInsensitiveContains($0) }) else { continue }
            return (app: app.name, title: title.isEmpty ? app.defaultTitle : title)
        }
        return nil
    }
}

/// Pure decision for the detector's two-tier polling.
public enum DetectorGate {
    /// Whether this tick should run the expensive window + Core Audio scans.
    /// Never skip mid-meeting: the audio reducer's .ended transition needs ticks.
    public static func shouldFullScan(hasDetectedWindow: Bool, isInMeeting: Bool, meetingAppRunning: Bool) -> Bool {
        hasDetectedWindow || isInMeeting || meetingAppRunning
    }
}
