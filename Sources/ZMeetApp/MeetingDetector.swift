import Foundation
import AppKit
import CoreGraphics

/// A meeting that appears to be in progress, identified from an on-screen window.
struct DetectedMeeting: Equatable {
    let app: String      // human-readable, e.g. "Zoom" / "Microsoft Teams"
    let title: String    // the meeting window title (or a sensible default)

    var key: String { "\(app)|\(title)" }
}

/// Polls the window list for Zoom/Teams *meeting* windows (not just the app
/// being open) and reports changes. Reading window titles relies on the Screen
/// Recording permission zMeet already holds; without it, titles are empty and
/// detection simply stays quiet (no false positives).
@MainActor
final class MeetingDetector {
    private var timer: Timer?
    private(set) var current: DetectedMeeting?

    /// Called when the detected meeting changes (a meeting starts → non-nil,
    /// or ends → nil).
    var onChange: ((DetectedMeeting?) -> Void)?

    func start() {
        guard timer == nil else { return }
        scan()
        timer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.scan() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func scan() {
        let detected = Self.detectMeeting()
        if detected != current {
            current = detected
            onChange?(detected)
        }
    }

    private static func detectMeeting() -> DetectedMeeting? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        for window in windows {
            let owner = (window[kCGWindowOwnerName as String] as? String) ?? ""
            let title = (window[kCGWindowName as String] as? String) ?? ""

            // Zoom: meeting window is titled "Zoom Meeting" / "Zoom Webinar";
            // the idle app window is "Zoom" / "Zoom Workplace".
            if owner == "zoom.us" {
                if title.localizedCaseInsensitiveContains("Meeting")
                    || title.localizedCaseInsensitiveContains("Webinar") {
                    return DetectedMeeting(app: "Zoom", title: title.isEmpty ? "Zoom Meeting" : title)
                }
            }

            // Teams: a call/meeting opens a window whose title mentions Meeting/Call.
            if owner.localizedCaseInsensitiveContains("Microsoft Teams") || owner == "MSTeams" {
                if title.localizedCaseInsensitiveContains("Meeting")
                    || title.localizedCaseInsensitiveContains("Call") {
                    return DetectedMeeting(app: "Microsoft Teams", title: title.isEmpty ? "Teams Meeting" : title)
                }
            }
        }
        return nil
    }
}
