import Foundation
import AppKit
import CoreGraphics
import ZMeetCore

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

    /// Consecutive scans with no meeting window before we drop the detected meeting.
    /// This now only governs the *prompt* (hide popup / re-arm), NOT auto-stop — the
    /// recording's lifecycle is driven by audio (see `audioActivity`).
    private let disappearThreshold = 6
    private var missCount = 0

    /// Audio-based "are we actually in a call" tracker — the reliable signal for
    /// starting/stopping a recording, independent of window titles (and lobbies).
    private let audioProbe = ProcessAudioProbe()
    private var audioActivity = MeetingAudioActivity()

    /// Called when the detected meeting *window* changes (appears → non-nil, or is
    /// gone → nil). Drives the "Take notes" prompt and its reset.
    var onChange: ((DetectedMeeting?) -> Void)?
    /// A meeting's audio actually started (you're in the call) — app name. Drives an
    /// audio-based prompt for meetings the window detector misses.
    var onAudioMeetingStarted: ((String) -> Void)?
    /// A meeting's audio ended after having started — drives auto-stop.
    var onAudioMeetingEnded: (() -> Void)?

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
        current = nil
        audioActivity = MeetingAudioActivity()
    }

    private func scan() {
        scanWindows()
        scanAudio()
    }

    private func scanWindows() {
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

    private func scanAudio() {
        let app = audioProbe.activeMeetingApp()
        switch audioActivity.update(active: app != nil) {
        case .started: onAudioMeetingStarted?(app ?? "Microsoft Teams")  // app is non-nil on .started
        case .ended:   onAudioMeetingEnded?()
        case nil:      break
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
