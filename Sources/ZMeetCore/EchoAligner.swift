import Foundation

/// Tuning for `EchoAligner`. The defaults are the design's starting values; real
/// captures (the recorder's debug tracks and `aec-probe`) are how they get tuned.
public struct EchoAlignerConfig: Sendable, Equatable {
    /// L₀: how far ahead of each mic frame its reference is read. AEC3 only finds
    /// an echo that trails its reference, so the reference has to lead the mic.
    public var initialLeadMs: Double = 100
    /// The longest a complete mic frame waits for its reference; after that the
    /// missing reference counts as silence.
    public var maxHoldMs: Double = 250
    /// Retargeting keeps the lead in here. A negative lead delays the reference
    /// instead of holding the mic.
    public var leadRangeMs: ClosedRange<Double> = -600...200
    /// AEC3's own delay estimator handles any locked echo delay in here, so the
    /// lead stays put.
    public var workingWindowMs: ClosedRange<Double> = 30...400
    /// When the locked delay leaves the working window, the lead moves so that
    /// the delay lands here.
    public var retargetDelayMs: Double = 150
    /// The most system audio kept for pairing; the oldest goes first.
    public var renderCapacityMs: Double = 2_000
    /// System audio whose PTS puts it within this distance of where the reference
    /// ends is appended contiguously; past it, the gap is filled or the overlap trimmed.
    public var placementToleranceMs: Double = 2

    public init() {}
}

/// What an `EchoAligner` has done so far, for the recorder's log line.
public struct EchoAlignerStats: Sendable, Equatable {
    /// Mic frames the processor cleaned.
    public var framesProcessed = 0
    /// Mic frames whose reference hadn't arrived when their hold ran out, so it was
    /// treated as silence.
    public var owedFrames = 0
    /// System-audio buffers that landed past a gap, which was filled with silence.
    public var renderGapFills = 0
    /// System-audio buffers whose start overlapped reference already placed (or
    /// owed), which was dropped.
    public var renderTrims = 0
    /// Times a mic PTS jump (a stall or lost mic buffers) moved the reference
    /// already placed, so that it kept its time position against the mic.
    public var referenceMoves = 0
    /// Times the lead moved because the locked delay left the working window.
    public var leadChanges = 0
    /// The current lead.
    public var leadMs: Double
    /// The tracker's lock as of the latest processed frame.
    public var lockedLagMs: Double?
    /// The processor failed, and the mic has passed through raw since.
    public var failed = false
}

/// Channel helpers for the echo pipeline, which runs mono.
public enum EchoAudio {
    /// The per-sample mean of equal-length channels, the downmix APM itself uses
    /// ((L + R) / 2 for stereo). One channel comes back unchanged; none gives [].
    public static func monoMix(_ channels: [[Float]]) -> [Float] {
        guard let first = channels.first else { return [] }
        guard channels.count > 1 else { return first }
        precondition(channels.allSatisfy { $0.count == first.count }, "channels must be the same length")
        var mono = first
        for channel in channels.dropFirst() {
            for i in mono.indices { mono[i] += channel[i] }
        }
        let count = Float(channels.count)
        for i in mono.indices { mono[i] /= count }
        return mono
    }
}

/// Pairs the mic with the system audio for AEC3, one 10 ms frame at a time.
///
/// Both inputs are mono 48 kHz, each buffer with the host-clock PTS (seconds) of
/// its first sample. Positions are mic sample indices, and index 0 is the first
/// PTS either stream showed. The mic is contiguous from its first sample. Each
/// system-audio buffer is placed by its PTS relative to the latest mic PTS, so
/// lost buffers, unsent silence and clock drift leave the reference where its echo
/// really is: a buffer landing more than 2 ms past the reference's end has the gap
/// filled with silence, and one landing more than 2 ms before it has the overlap
/// trimmed. When the mic's own PTS jumps by more than 2 ms (a stall or lost mic
/// buffers) and no complete mic frame from before the jump is still waiting, the
/// reference already placed moves with it, so it keeps its time position against
/// the mic.
///
/// Mic frame m (samples [m, m + 480)) is paired with the reference
/// [m + L, m + L + 480), L being the lead. A frame waits until that reference has
/// arrived, or until it has waited `maxHoldMs`; then the missing reference counts
/// as silence (an owed frame), and system audio that arrives for it later is
/// trimmed. Frames leave strictly in order, and each makes exactly one
/// `processRender` call, then one `processCapture` call.
///
/// The tracker measures the delay at which the echo appears behind the reference
/// fed. The lead changes only when the locked delay leaves the working window, in
/// one step that brings the delay to `retargetDelayMs`.
///
/// If the processor ever fails, the frame it failed on and every later one pass
/// through raw.
///
/// NOT thread-safe: one instance per recording, used from one queue.
public final class EchoAligner {
    public private(set) var stats: EchoAlignerStats
    /// How long the first frame of the latest release (a `drainReady()` or `flush()` that
    /// returned samples) waited between arriving and going out, in seconds; 0 if it waited
    /// for nothing. A frame arrives with the mic buffer that brings its last sample.
    public private(set) var lastReleaseHoldSeconds: Double = 0
    /// How old the first sample of the latest release is when it goes out, in seconds. A
    /// sample arrives with the mic buffer that brings it, plus its place in that buffer at
    /// 48 kHz: when it would have started playing had that buffer gone straight to a player.
    /// So this is the first frame's hold plus its wait for its later samples, and it is
    /// negative for a frame that starts partway into a buffer that has only just arrived. The
    /// recorder takes this off the mic player's target, so held mic plays as long after it
    /// arrived as the system audio does.
    public private(set) var lastReleaseAgeSeconds: Double = 0

    private static let sampleRate = Double(EchoCanceller.sampleRate)
    private static let frameSize = EchoCanceller.frameSize

    private let config: EchoAlignerConfig
    private let processor: any EchoProcessing
    private var tracker: any EchoLagTracking
    private let now: () -> TimeInterval
    /// `config.placementToleranceMs` in samples.
    private let tolerance: Int
    /// `stats.leadMs` in samples.
    private var lead: Int

    /// The first PTS either stream showed: index 0.
    private var origin: TimeInterval?
    /// The latest mic buffer with a PTS: that PTS and the index of its first sample.
    private var micAnchor: (pts: TimeInterval, index: Int)?

    /// Mic samples not yet released, the first at index `pendingStart`.
    private var pending: [Float] = []
    private var pendingStart = 0
    private var micStarted = false
    /// A complete frame in `pending`: when the mic buffer that completed it arrived, and when
    /// its first sample did (see `lastReleaseAgeSeconds`).
    private struct FrameArrival {
        var completed: TimeInterval
        var firstSample: TimeInterval
    }
    /// Each complete frame in `pending`, oldest first.
    private var arrivals: [FrameArrival] = []
    /// When the latest mic buffer arrived: the arrival of a partial frame at the end of `pending`.
    private var lastCaptureArrival: TimeInterval?
    /// When the first sample of the partial frame at the end of `pending` arrived; nil when
    /// there is none.
    private var partialFrameFirstSample: TimeInterval?

    /// The reference: the newest `renderCount` samples, at indices
    /// [renderEnd − renderCount, renderEnd), index i in slot
    /// (i + ringOffset) mod capacity. Everything else reads as silence.
    private var ring: [Float]
    /// nil until the first reference is placed or owed.
    private var renderEnd: Int?
    private var renderCount = 0
    /// Lets the whole reference move along the timeline without copying (`moveReference`).
    private var ringOffset = 0

    public init(config: EchoAlignerConfig = EchoAlignerConfig(), processor: any EchoProcessing,
                tracker: any EchoLagTracking = EchoLagTracker(), now: @escaping () -> TimeInterval) {
        let capacity = Self.samples(ms: config.renderCapacityMs)
        precondition(capacity >= Self.frameSize, "the render capacity must hold at least one frame")
        self.config = config
        self.processor = processor
        self.tracker = tracker
        self.now = now
        stats = EchoAlignerStats(leadMs: config.initialLeadMs)
        lead = Self.samples(ms: config.initialLeadMs)
        tolerance = Self.samples(ms: config.placementToleranceMs)
        ring = [Float](repeating: 0, count: capacity)
    }

    /// Reference samples held for pairing; never more than the render capacity.
    public var bufferedRenderSamples: Int { renderCount }

    /// System audio, the far end: mono 48 kHz, `pts` the host time of its first
    /// sample, or nil to append it where the reference ends.
    public func appendRender(_ samples: [Float], pts: TimeInterval?) {
        guard !samples.isEmpty else { return }
        let target = renderTarget(pts: pts)
        guard let end = renderEnd else {
            // The first reference starts where it belongs; before it is silence.
            renderEnd = target ?? 0
            writeRender(samples)
            return
        }
        let start = target ?? end
        if start > end + tolerance {
            stats.renderGapFills += 1
            writeSilence(start - end)
            writeRender(samples)
        } else if start < end - tolerance {
            stats.renderTrims += 1
            writeRender(samples.dropFirst(end - start))
        } else {
            writeRender(samples)
        }
    }

    /// The mic: mono 48 kHz, `pts` the host time of its first sample, or nil.
    public func appendCapture(_ samples: [Float], pts: TimeInterval?) {
        guard !samples.isEmpty else { return }
        let arrival = now()
        lastCaptureArrival = arrival
        let pts = Self.usable(pts)
        if let pts, origin == nil { origin = pts }
        let first: Int
        if micStarted {
            first = pendingStart + pending.count
            if let pts, let anchor = micAnchor, arrivals.isEmpty,
               let expected = Self.samples(seconds: pts - anchor.pts).map({ anchor.index + $0 }),
               abs(expected - first) > tolerance {
                // The mic's PTS jumped (a stall or lost buffers) with no frame left from
                // before it: the reference moves with the mic's new PTS placement.
                moveReference(by: first - expected)
            }
        } else {
            // The mic starts at its PTS after the origin; without one, its sample count alone places it.
            if let pts, let origin { first = Self.samples(seconds: pts - origin) ?? 0 } else { first = 0 }
            pendingStart = first
            micStarted = true
        }
        if let pts { micAnchor = (pts, first) }
        let before = pending.count
        pending.append(contentsOf: samples)
        // When the sample at `offset` in `pending` arrived: this buffer's arrival plus the
        // sample's place in it, or, for the partial frame that was already waiting, when that
        // frame's first sample arrived.
        func arrived(_ offset: Int) -> TimeInterval {
            offset >= before ? arrival + Double(offset - before) / Self.sampleRate
                : partialFrameFirstSample ?? arrival
        }
        for frame in (before / Self.frameSize)..<(pending.count / Self.frameSize) {
            arrivals.append(FrameArrival(completed: arrival, firstSample: arrived(frame * Self.frameSize)))
        }
        let partial = pending.count / Self.frameSize * Self.frameSize
        partialFrameFirstSample = partial < pending.count ? arrived(partial) : nil
    }

    /// The cleaned mic samples releasable now, in order (possibly none): every
    /// complete frame whose reference has arrived or whose hold has run out, up to
    /// the first that has to keep waiting.
    public func drainReady() -> [Float] {
        var out: [Float] = []
        let time = now()
        while let arrival = arrivals.first {
            if !stats.failed {
                let needed = pendingStart + lead + Self.frameSize
                if renderEnd.map({ $0 < needed }) ?? true {
                    guard (time - arrival.completed) * 1_000 >= config.maxHoldMs else { break }
                    oweRender(upTo: needed)
                }
            }
            if out.isEmpty {
                lastReleaseHoldSeconds = max(time - arrival.completed, 0)
                lastReleaseAgeSeconds = time - arrival.firstSample
            }
            out += releaseNextFrame()
        }
        return out
    }

    /// Everything still pending, cleaned with whatever reference exists (silence
    /// where none arrived). A partial last frame is zero-padded for the processor
    /// and trimmed back to its real length.
    public func flush() -> [Float] {
        let time = now()
        if let first = arrivals.first?.completed ?? (pending.isEmpty ? nil : lastCaptureArrival) {
            lastReleaseHoldSeconds = max(time - first, 0)
        }
        if let first = arrivals.first?.firstSample ?? (pending.isEmpty ? nil : partialFrameFirstSample) {
            lastReleaseAgeSeconds = time - first
        }
        var out: [Float] = []
        while !arrivals.isEmpty { out += releaseNextFrame() }
        if !pending.isEmpty {
            let count = pending.count
            let start = pendingStart
            let padded = pending + [Float](repeating: 0, count: Self.frameSize - count)
            pending.removeAll()
            pendingStart += count
            out += process(padded, at: start).prefix(count)
        }
        partialFrameFirstSample = nil
        return out
    }

    // MARK: - Pairing

    /// Releases the oldest complete mic frame, cleaned (or raw once the processor has failed).
    private func releaseNextFrame() -> [Float] {
        let start = pendingStart
        let raw = Array(pending[..<Self.frameSize])
        pending.removeFirst(Self.frameSize)
        arrivals.removeFirst()
        pendingStart += Self.frameSize
        return process(raw, at: start)
    }

    /// One AEC3 step for the mic frame starting at index `start`: its reference,
    /// then the frame, then the tracker.
    private func process(_ raw: [Float], at start: Int) -> [Float] {
        guard !stats.failed else { return raw }
        let reference = renderFrame(at: start + lead)
        var cleaned = raw
        guard processor.processRender(reference), processor.processCapture(&cleaned) else {
            stats.failed = true
            return raw
        }
        stats.framesProcessed += 1
        tracker.append(reference: reference, observed: raw)
        stats.lockedLagMs = tracker.lockedLagMs
        retargetIfOutsideWindow()
        return cleaned
    }

    /// Moves the lead so the locked delay lands on `retargetDelayMs`, but only
    /// when that delay has left the working window.
    private func retargetIfOutsideWindow() {
        guard let lock = stats.lockedLagMs, !config.workingWindowMs.contains(lock) else { return }
        let range = config.leadRangeMs
        let leadMs = min(max(stats.leadMs + (config.retargetDelayMs - lock), range.lowerBound), range.upperBound)
        guard leadMs != stats.leadMs else { return }
        stats.leadMs = leadMs
        stats.leadChanges += 1
        lead = Self.samples(ms: leadMs)
        tracker.reset()
    }

    // MARK: - Reference timeline

    /// Where system audio with this PTS starts: placed by the latest mic PTS, or
    /// by the origin before any. nil without a usable PTS.
    private func renderTarget(pts: TimeInterval?) -> Int? {
        guard let pts = Self.usable(pts) else { return nil }
        let origin = self.origin ?? pts
        self.origin = origin
        let anchor = micAnchor ?? (pts: origin, index: 0)
        return Self.samples(seconds: pts - anchor.pts).map { anchor.index + $0 }
    }

    /// Moves every reference sample by `shift` indices, so system audio placed
    /// under the mic's previous PTS keeps its time position against the mic.
    private func moveReference(by shift: Int) {
        guard let end = renderEnd else { return }
        stats.referenceMoves += 1
        renderEnd = end + shift
        ringOffset = Self.modulo(ringOffset - shift, ring.count)
    }

    /// The hold ran out before the reference up to `index` arrived: it counts as silence.
    private func oweRender(upTo index: Int) {
        stats.owedFrames += 1
        guard let end = renderEnd else {
            renderEnd = index
            return
        }
        if index > end { writeSilence(index - end) }
    }

    /// The reference [start, start + 480): the retained samples, silence elsewhere.
    private func renderFrame(at start: Int) -> [Float] {
        var frame = [Float](repeating: 0, count: Self.frameSize)
        guard let end = renderEnd else { return frame }
        let lower = max(start, end - renderCount)
        let upper = min(start + Self.frameSize, end)
        guard lower < upper else { return frame }
        var slot = self.slot(lower)
        for index in lower..<upper {
            frame[index - start] = ring[slot]
            slot = slot + 1 == ring.count ? 0 : slot + 1
        }
        return frame
    }

    /// Appends at `renderEnd`, keeping only the newest `ring.count` samples.
    private func writeRender(_ samples: some Collection<Float>) {
        guard let end = renderEnd, !samples.isEmpty else { return }
        var slot = self.slot(end)
        for sample in samples {
            ring[slot] = sample
            slot = slot + 1 == ring.count ? 0 : slot + 1
        }
        renderEnd = end + samples.count
        renderCount = min(renderCount + samples.count, ring.count)
    }

    private func writeSilence(_ count: Int) {
        guard let end = renderEnd, count > 0 else { return }
        guard count < ring.count else {
            // The silence alone fills the ring: nothing older stays, and silence needs no storage.
            renderEnd = end + count
            renderCount = 0
            return
        }
        writeRender(repeatElement(Float(0), count: count))
    }

    private func slot(_ index: Int) -> Int { Self.modulo(index + ringOffset, ring.count) }

    private static func modulo(_ value: Int, _ divisor: Int) -> Int {
        let remainder = value % divisor
        return remainder < 0 ? remainder + divisor : remainder
    }

    // MARK: - Units

    /// A PTS that can be placed: finite.
    private static func usable(_ pts: TimeInterval?) -> TimeInterval? {
        pts.flatMap { $0.isFinite ? $0 : nil }
    }

    /// round(seconds · 48 000); nil when that isn't a usable sample offset, so a
    /// corrupt PTS is treated as a missing one instead of trapping.
    private static func samples(seconds: TimeInterval) -> Int? {
        let count = (seconds * sampleRate).rounded()
        guard abs(count) <= 9_007_199_254_740_992 else { return nil }  // 2^53; false for NaN
        return Int(count)
    }

    private static func samples(ms: Double) -> Int {
        Int((ms * sampleRate / 1_000).rounded())
    }
}
