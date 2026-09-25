import Foundation

/// A meeting that appears to be in progress.
public struct DetectedMeeting: Equatable, Sendable {
    public let app: String      // human-readable, e.g. "Zoom" / "Microsoft Teams"
    public let title: String    // the meeting window title (or a generic default)

    public init(app: String, title: String) {
        self.app = app
        self.title = title
    }

    public var key: String { "\(app)|\(title)" }
}

/// Whether a meeting is live right now, merging the detector's two signals. The
/// window signal carries the real meeting title but vanishes in a Teams lobby (and
/// never fires for subjects without "Meeting"/"Call"); the audio signal survives
/// the lobby but only knows the app. The meeting stays detected while EITHER holds,
/// preferring the window's title.
///
/// Deliberately independent of the "Take notes" banner: dismissing or missing the
/// banner never clears it, which is what lets the menu offer "Record" for the whole
/// meeting.
public struct DetectedMeetingTracker: Equatable, Sendable {
    public private(set) var windowMeeting: DetectedMeeting?
    public private(set) var audioApp: String?

    public init() {}

    public var current: DetectedMeeting? {
        windowMeeting ?? audioApp.map { DetectedMeeting(app: $0, title: "\($0) Meeting") }
    }

    public mutating func windowChanged(_ meeting: DetectedMeeting?) { windowMeeting = meeting }
    public mutating func audioStarted(app: String) { audioApp = app }
    public mutating func audioEnded() { audioApp = nil }
    public mutating func reset() { self = .init() }
}
