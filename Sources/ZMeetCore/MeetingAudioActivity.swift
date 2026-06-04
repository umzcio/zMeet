/// Tracks whether a meeting is in progress from a stream of "is the meeting app
/// moving audio?" ticks (one per detector scan). This is the reliable signal that a
/// window title can't give: it can only report a meeting **ended** after first
/// confirming it **started** (sustained audio) — so a Teams lobby, which has no call
/// audio yet, can never be mistaken for an ended meeting and trigger an auto-stop.
public struct MeetingAudioActivity: Equatable, Sendable {
    public enum Event: Equatable, Sendable { case started, ended }

    /// Consecutive active ticks required to treat a meeting as started (so a brief
    /// notification sound doesn't trigger it).
    private let startTicks: Int
    /// Consecutive inactive ticks required to treat a meeting as ended (rides over
    /// short audio drops mid-meeting).
    private let endTicks: Int

    private var inMeeting = false
    private var activeRun = 0
    private var inactiveRun = 0

    public init(startTicks: Int = 2, endTicks: Int = 6) {
        self.startTicks = max(1, startTicks)
        self.endTicks = max(1, endTicks)
    }

    public var isInMeeting: Bool { inMeeting }

    /// Feed one observation. Returns `.started` / `.ended` exactly on the transition,
    /// otherwise nil.
    public mutating func update(active: Bool) -> Event? {
        if active {
            activeRun += 1
            inactiveRun = 0
        } else {
            inactiveRun += 1
            activeRun = 0
        }

        if inMeeting {
            if !active && inactiveRun >= endTicks {
                inMeeting = false
                return .ended
            }
        } else {
            if active && activeRun >= startTicks {
                inMeeting = true
                return .started
            }
        }
        return nil
    }
}
