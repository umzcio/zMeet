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
    /// True between start() and stop(). Guards scanAndReschedule() against a
    /// straggler Task that was already queued on the main queue when stop() ran
    /// (the timer fired, invalidate() happened before the Task executed) — without
    /// this, that straggler would schedule a fresh timer and resurrect polling
    /// permanently even though detection was disabled.
    private var isRunning = false
    private(set) var current: DetectedMeeting?

    /// Consecutive scans with no meeting window before we drop the detected meeting.
    /// This now only governs the *prompt* (hide popup / re-arm), NOT auto-stop — the
    /// recording's lifecycle is driven by audio (see `audioActivity`).
    private let disappearThreshold = 6
    private var missCount = 0

    /// Consecutive idle ticks (no detected window, not in meeting) — drives the
    /// cadence backoff in `DetectorGate.nextInterval`. Resets on any activity.
    private var consecutiveIdleScans = 0

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
        guard !isRunning else { return }
        isRunning = true
        scanAndReschedule()
    }

    func stop() {
        isRunning = false
        timer?.invalidate()
        timer = nil
        missCount = 0
        current = nil
        audioActivity = MeetingAudioActivity()
        consecutiveIdleScans = 0
    }

    /// Runs one tick, then schedules the next at a cadence that eases off (4 s → 15 s)
    /// once a resident-but-idle meeting app has produced 15 consecutive idle ticks, and
    /// restores 4 s immediately on any detected window or in-meeting audio. The
    /// NSWorkspace "is a meeting app running" check is computed once here and shared
    /// between the scan gate and the cadence decision — don't re-query it in `scan()`.
    ///
    /// Guarded by `isRunning`: the timer closure hops to the main actor via `Task`, so
    /// if `stop()` runs after the timer fires but before that Task executes, this call
    /// must no-op instead of scheduling a fresh timer and resurrecting polling.
    private func scanAndReschedule() {
        guard isRunning else { return }
        let running = ProcessAudioProbe.meetingAppProcessRunning()
        scan(meetingAppRunning: running)
        let active = current != nil || audioActivity.isInMeeting
        consecutiveIdleScans = active ? 0 : consecutiveIdleScans + 1
        let interval = DetectorGate.nextInterval(
            hasDetectedWindow: current != nil,
            isInMeeting: audioActivity.isInMeeting,
            meetingAppRunning: running,
            consecutiveIdleScans: consecutiveIdleScans)
        scheduleNext(after: interval)
    }

    private func scheduleNext(after interval: TimeInterval) {
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.scanAndReschedule() }
        }
    }

    private func scan(meetingAppRunning: Bool) {
        // Cheap tier: skip the window + Core Audio IPC entirely when no meeting
        // app is even running and nothing is in flight. Never skip mid-meeting:
        // the audio reducer's .ended transition (auto-stop) needs its ticks.
        let shouldScan = DetectorGate.shouldFullScan(
            hasDetectedWindow: current != nil,
            isInMeeting: audioActivity.isInMeeting,
            meetingAppRunning: meetingAppRunning)
        if !shouldScan {
            _ = audioActivity.update(active: false)
            return
        }
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

            if let m = MeetingAppCatalog.matchMeetingWindow(owner: owner, title: title) {
                return DetectedMeeting(app: m.app, title: m.title)
            }
        }
        return nil
    }
}
