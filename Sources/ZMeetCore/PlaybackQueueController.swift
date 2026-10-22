import Foundation

/// Keeps one of the recorder's players a set distance ahead of what it's playing, by
/// measuring what the player still has queued, while the echo pipeline runs.
///
/// The echo pipeline holds the mic until its reference arrives, and the canceller adds its
/// own latency, so the mic reaches its player later than it arrived. Each player is therefore
/// kept `targetFrames` ahead: a buffer then plays that long after it's scheduled. The system
/// player's target is the priming; the mic player's is the priming less how much later the
/// mic got there. Both streams then play the priming after they arrived, and stay as aligned
/// in the mix as without the pipeline.
///
/// Before each buffer goes to the player, the controller compares what the player still has
/// queued, counted from its own position, with the target. A queue more than the tolerance
/// short gets the difference as silence first. That covers:
/// - the first buffer: the priming;
/// - a gap in the stream: nothing sent, a stall, lost buffers;
/// - a player that ran dry;
/// - a source whose clock runs slower than the player's.
///
/// Smaller differences (jitter) are left alone. So is a queue that is too long: audio is
/// never removed, so a source faster than its player drifts late, as it does without the
/// pipeline.
///
/// Positions are the player's sample time: `AVAudioPlayerNode.playerTime(forNodeTime:)` of
/// its `lastRenderTime`. Before the player's first render there is none, and that counts as 0.
public struct PlaybackQueueController: Sendable, Equatable {
    /// The player position where everything scheduled through this controller ends.
    public private(set) var scheduledEnd: Int64 = 0
    /// How many times silence went in, the priming included.
    public private(set) var insertions = 0
    /// All the silence that went in, in frames, the priming included.
    public private(set) var insertedFrames: Int64 = 0

    private let toleranceFrames: Int64

    /// `toleranceFrames`: how far short of its target a queue may run before it's topped up.
    /// The default, 480, is 10 ms at 48 kHz.
    public init(toleranceFrames: Int = 480) {
        precondition(toleranceFrames >= 0, "the tolerance can't be negative")
        self.toleranceFrames = Int64(toleranceFrames)
    }

    /// Call right before scheduling `frames` on the player. nowFrames = the player's current
    /// sample position (nil before its first render → 0). Returns silence frames to schedule first.
    public mutating func silenceBefore(frames: Int, nowFrames: Int64?, targetFrames: Int) -> Int {
        let now = nowFrames ?? 0
        let end = max(scheduledEnd, now)
        let shortfall = Int64(targetFrames) - (end - now)
        let silence = shortfall > toleranceFrames ? shortfall : 0
        if silence > 0 {
            insertions += 1
            insertedFrames += silence
        }
        scheduledEnd = end + silence + Int64(frames)
        return Int(silence)
    }

    /// What the player still has queued at `nowFrames`: max(scheduledEnd, now) − now, with
    /// nil counting as 0.
    public func depth(nowFrames: Int64?) -> Int64 {
        let now = nowFrames ?? 0
        return max(scheduledEnd, now) - now
    }
}
