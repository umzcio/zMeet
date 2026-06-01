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

    /// Consecutive scans with no meeting detected before we treat it as ended.
    /// At the 4s scan interval this is ~24s, so transient gaps (Teams password /
    /// waiting room, brief title changes) don't stop a detection-started recording.
    private let disappearThreshold = 6
    private var missCount = 0

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
        missCount = 0
    }

    private func scan() {
        let detected = Self.detectMeeting()
        if let detected {
            missCount = 0
            if detected != current {
                current = detected
                onChange?(detected)
            }
        } else if current != nil {
            missCount += 1
            if missCount >= disappearThreshold {
                current = nil
                missCount = 0
                onChange?(nil)
            }
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
