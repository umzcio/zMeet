import Foundation

/// Where a primed player needs silence so that its stream keeps one steady delay.
///
/// With echo cancellation on, the recorder primes each of its two player nodes with
/// `primingFrames` of silence ahead of its first audio. The mic can then wait for its echo
/// reference without its player running dry, and both players carry the same delay. A
/// player plays what it has queued back to back. Unprimed, it has nothing queued when a
/// buffer arrives and starts it at once, so a gap in its stream (a stall, lost buffers,
/// silence nothing was sent for) stays a gap. Primed, it would close the gap and play the
/// audio after it early, by up to the priming, which moves that stream against the other
/// in the mix for the rest of the recording. So each gap goes back in as silence:
///
/// - A buffer whose PTS lands more than the tolerance past where the buffer before it
///   ended gets the gap as silence before it.
/// - If the gap outlasts what the player still had queued, the player ran dry and has
///   played silence for the rest of it already. The buffer then gets just enough silence
///   to start the priming after it arrived, as the first audio did.
/// - A buffer whose PTS lands more than the tolerance before where the buffer before it
///   ended still plays in full, after it, so the player runs that much late; the next
///   gap gets that much less silence. That also keeps a jittered PTS from adding up: the
///   silence a late stamp gets comes off the next gap.
/// - Smaller differences are left alone, and each PTS is compared with the buffer just
///   before it, so slow drift between the stream's clock and the host clock adds no
///   silence, as without priming.
///
/// Buffers are noted as they arrive and scheduled as they go to the player: the system
/// audio at once; the mic after the echo pipeline holds it, contiguous and in order, so
/// its silence goes in where each buffer started, and the hold counts against what the
/// priming leaves for the rest of a gap.
///
/// The first frame scheduled gets the priming, less any hold. Times are host seconds;
/// PTS and arrival times are only ever compared with their own kind.
public struct PrimedPlaybackSchedule: Sendable, Equatable {
    /// Silence for the player: `frames` of it before the scheduled frame at `offset`.
    public struct Silence: Sendable, Equatable {
        public var offset: Int
        public var frames: Int

        public init(offset: Int, frames: Int) {
            self.offset = offset
            self.frames = frames
        }
    }

    /// Gaps in the stream so far: PTS jumps forward past the tolerance.
    public private(set) var gaps = 0
    /// The silence those gaps got, in frames; the priming isn't counted.
    public private(set) var gapSilenceFrames = 0

    /// An arrived buffer whose first frame hasn't been scheduled yet.
    private struct Start: Sendable, Equatable {
        /// Its first frame's position in the stream.
        var index: Int
        /// How far its PTS landed past where the buffer before it ended, in frames.
        var jump: Int
        /// When it arrived.
        var arrival: TimeInterval
    }

    private let primingFrames: Int
    private let toleranceFrames: Int
    private let sampleRate: Double
    /// Where the next buffer's PTS falls if the stream runs on; nil before any PTS.
    private var nextPTS: TimeInterval?
    private var arrivedFrames = 0
    private var scheduledFrames = 0
    private var starts: [Start] = []
    private var primed = false
    /// How far the player runs behind its delay, from overlaps it played in full. At most
    /// the priming, so a PTS that jumps back further counts as a timestamp discontinuity,
    /// not as audio the player holds.
    private var lateFrames = 0

    /// `primingFrames`: the silence each player gets ahead of its first audio.
    /// `toleranceFrames`: the PTS difference left alone.
    public init(primingFrames: Int, toleranceFrames: Int, sampleRate: Double) {
        precondition(primingFrames >= 0 && toleranceFrames >= 0 && sampleRate > 0)
        self.primingFrames = primingFrames
        self.toleranceFrames = toleranceFrames
        self.sampleRate = sampleRate
    }

    /// A buffer of the stream arrived, in order: its length, the PTS of its first frame
    /// (nil if unknown: it then follows on from the buffer before), and the time it arrived.
    public mutating func arrive(frames: Int, pts: TimeInterval?, at time: TimeInterval) {
        guard frames > 0 else { return }
        let pts = pts.flatMap { $0.isFinite ? $0 : nil }
        var jump = 0
        if let pts, let nextPTS { jump = Self.frames(seconds: pts - nextPTS, rate: sampleRate) ?? 0 }
        starts.append(Start(index: arrivedFrames, jump: jump, arrival: time))
        if let from = pts ?? nextPTS { nextPTS = from + Double(frames) / sampleRate }
        arrivedFrames += frames
    }

    /// The stream's next `frames`, in order, go to the player at `time`. Returns the silence
    /// to queue among them, in order: the priming before the first frame, and each gap's
    /// silence before the frame after it.
    public mutating func schedule(frames: Int, at time: TimeInterval) -> [Silence] {
        guard frames > 0 else { return [] }
        let end = scheduledFrames + frames
        var silences: [Silence] = []
        var placed = 0
        while let start = starts.first, start.index < end {
            starts.removeFirst()
            let offset = max(start.index - scheduledFrames, 0)
            // If the player has run dry, everything queued now plays from now: this much
            // silence still starts this buffer the priming after it arrived.
            let room = max(primingFrames - held(since: start.arrival, now: time) - offset - placed, 0)
            let silence = silence(after: start.jump, room: room)
            if silence > 0 {
                silences.append(Silence(offset: offset, frames: silence))
                placed += silence
            }
        }
        scheduledFrames = end
        return silences
    }

    /// The silence for a buffer whose PTS jumped by `jump` frames.
    private mutating func silence(after jump: Int, room: Int) -> Int {
        guard primed else {
            primed = true
            return room
        }
        if jump > toleranceFrames {
            gaps += 1
            let wanted = max(jump - lateFrames, 0)
            let silence: Int
            if wanted > room {
                // The gap outlasted what the player had queued: it ran dry and starts again
                // at its delay, on time.
                silence = room
                lateFrames = 0
            } else {
                silence = wanted
                lateFrames = max(lateFrames - jump, 0)
            }
            gapSilenceFrames += silence
            return silence
        }
        if jump < -toleranceFrames {
            lateFrames = min(lateFrames - jump, primingFrames)
        }
        return 0
    }

    /// How long a buffer that arrived at `arrival` has waited by `now`, in frames, up to the priming.
    private func held(since arrival: TimeInterval, now: TimeInterval) -> Int {
        let waited = (now - arrival) * sampleRate
        guard waited.isFinite, waited > 0 else { return 0 }
        return Int(min(waited, Double(primingFrames)).rounded())
    }

    /// round(seconds · rate); nil past 2^53 frames (or NaN), so a corrupt PTS counts as none.
    private static func frames(seconds: TimeInterval, rate: Double) -> Int? {
        let count = (seconds * rate).rounded()
        guard abs(count) <= 9_007_199_254_740_992 else { return nil }
        return Int(count)
    }
}
