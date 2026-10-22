import Foundation
import Testing
@testable import ZMeetCore

final class FakeProcessor: EchoProcessing {
    var calls: [Character] = []; var renders: [[Float]] = []; var captures = 0; var failOnCapture: Int?
    func processRender(_ frame: [Float]) -> Bool { calls.append("R"); renders.append(frame); return true }
    func processCapture(_ frame: inout [Float]) -> Bool {
        calls.append("C"); captures += 1
        if captures == failOnCapture { return false }
        for i in frame.indices { frame[i] *= 0.5 }; return true
    }
}
struct FixedLagTracker: EchoLagTracking {
    var lockedLagMs: Double?
    mutating func append(reference: [Float], observed: [Float]) {}
    mutating func reset() {}
}
final class ManualClock { var t: TimeInterval = 0 }
private func ramp(_ from: Int, _ count: Int) -> [Float] { (from..<(from + count)).map(Float.init) }

private func makeAligner(_ processor: FakeProcessor, clock: ManualClock = ManualClock(),
                         config: EchoAlignerConfig = EchoAlignerConfig(), lock: Double? = nil) -> EchoAligner {
    EchoAligner(config: config, processor: processor, tracker: FixedLagTracker(lockedLagMs: lock), now: { clock.t })
}

private func zeros(_ count: Int) -> [Float] { [Float](repeating: 0, count: count) }

/// Tests 1 and 2: render ramp(0, 57 600) in 1 024-sample chunks, then 48 000 capture zeros in
/// repeating chunks of 441, 1 000 and 333, each chunk's pts its first sample / 48 000; then flush().
private func feedUnevenBuffers(_ a: EchoAligner) -> [Float] {
    var out: [Float] = []
    let render = ramp(0, 57_600)
    var i = 0
    while i < render.count {
        let e = min(i + 1_024, render.count)
        a.appendRender(Array(render[i..<e]), pts: Double(i) / 48_000)
        out += a.drainReady()
        i = e
    }
    let sizes = [441, 1_000, 333]
    var start = 0
    var k = 0
    while start < 48_000 {
        let n = min(sizes[k % sizes.count], 48_000 - start)
        a.appendCapture(zeros(n), pts: Double(start) / 48_000)
        out += a.drainReady()
        start += n
        k += 1
    }
    out += a.flush()
    return out
}

/// Tests 11 and 12: render available, then one 480-sample capture frame at pts 0.
private func statsAfterOneProcessedFrame(lock: Double) -> EchoAlignerStats {
    let p = FakeProcessor()
    let a = makeAligner(p, lock: lock)
    a.appendRender(zeros(5_280), pts: 0)
    _ = a.drainReady()
    a.appendCapture(zeros(480), pts: 0)
    _ = a.drainReady()
    #expect(p.captures == 1)
    return a.stats
}

/// Tests 14 and 15, through the real EchoCanceller and EchoLagTracker. The mic comes in
/// 480-sample chunks delivered at pts + 0.01 s; the system audio in 1 024-sample chunks delivered
/// at pts + duration + 0.03 s (30 ms late). Events run in delivery order (times in exact 48 kHz
/// sample units), the clock is set to each delivery time before its append, every append is
/// followed by drainReady(), and flush() ends the run.
private func runWithLateSystemAudio(far: [Float], mic: [Float]) throws -> [Float] {
    let canceller = try #require(EchoCanceller())
    let clock = ManualClock()
    let aligner = EchoAligner(processor: canceller, now: { clock.t })
    struct Delivery { var at: Int; var isRender: Bool; var start: Int; var end: Int }
    var deliveries: [Delivery] = []
    var s = 0
    while s < mic.count {
        let e = min(s + 480, mic.count)
        deliveries.append(Delivery(at: s + 480, isRender: false, start: s, end: e))
        s = e
    }
    s = 0
    while s < far.count {
        let e = min(s + 1_024, far.count)
        deliveries.append(Delivery(at: e + 1_440, isRender: true, start: s, end: e))
        s = e
    }
    deliveries.sort { ($0.at, $0.isRender ? 1 : 0) < ($1.at, $1.isRender ? 1 : 0) }
    var out: [Float] = []
    for d in deliveries {
        clock.t = Double(d.at) / 48_000
        let pts = Double(d.start) / 48_000
        if d.isRender {
            aligner.appendRender(Array(far[d.start..<d.end]), pts: pts)
        } else {
            aligner.appendCapture(Array(mic[d.start..<d.end]), pts: pts)
        }
        out += aligner.drainReady()
    }
    out += aligner.flush()
    return out
}

@Test func pairsUnevenBufferSizesOneToOne() {
    let p = FakeProcessor()
    let a = makeAligner(p)
    let out = feedUnevenBuffers(a)
    #expect(p.calls.enumerated().allSatisfy { $0.element == ($0.offset.isMultiple(of: 2) ? "R" : "C") })
    #expect(p.calls.filter { $0 == "R" }.count == 100)
    #expect(p.calls.filter { $0 == "C" }.count == 100)
    #expect(out.count == 48_000)
}

@Test func pairsCaptureFrameWithRenderLeadSamplesAhead() {
    let p = FakeProcessor()
    let a = makeAligner(p)
    _ = feedUnevenBuffers(a)
    #expect(p.renders.count == 100)
    #expect(p.renders.enumerated().allSatisfy { $0.element[0] == Float($0.offset * 480 + 4_800) })
}

@Test func holdsUntilRenderArrives() {
    let p = FakeProcessor()
    let a = makeAligner(p)
    a.appendCapture(zeros(480), pts: 0)
    #expect(a.drainReady().isEmpty)
    a.appendRender(ramp(0, 5_280), pts: 0)
    #expect(a.drainReady().count == 480)
}

@Test func treatsMissingRenderAsSilenceAfterMaxHold() {
    let p = FakeProcessor()
    let clock = ManualClock()
    let a = makeAligner(p, clock: clock)
    a.appendCapture(zeros(480), pts: 0)
    #expect(a.drainReady().isEmpty)
    clock.t = 0.249
    #expect(a.drainReady().isEmpty)
    clock.t = 0.251
    #expect(a.drainReady().count == 480)
    #expect(p.renders.first?.allSatisfy { $0 == 0 } == true)
    #expect(a.stats.owedFrames == 1)
    a.appendRender(ramp(0, 5_280), pts: 0)
    _ = a.drainReady()
    #expect(p.calls == ["R", "C"])
    #expect(a.stats.renderTrims == 1)
}

@Test func fillsRenderGapsFromPTS() throws {
    var config = EchoAlignerConfig()
    config.initialLeadMs = 0
    let p = FakeProcessor()
    let a = makeAligner(p, config: config)
    var out: [Float] = []
    a.appendRender([Float](repeating: 1, count: 480), pts: 0)
    out += a.drainReady()
    a.appendRender([Float](repeating: 1, count: 480), pts: 0.1)
    out += a.drainReady()
    a.appendCapture(zeros(5_280), pts: 0)
    out += a.drainReady()
    out += a.flush()
    #expect(a.stats.renderGapFills == 1)
    try #require(p.renders.count == 11)
    #expect(p.renders[1].allSatisfy { $0 == 0 })
    #expect(p.renders[10].allSatisfy { $0 == 1 })
}

@Test func trimsRenderOverlapFromPTS() throws {
    var config = EchoAlignerConfig()
    config.initialLeadMs = 0
    let p = FakeProcessor()
    let a = makeAligner(p, config: config)
    var out: [Float] = []
    a.appendRender(ramp(0, 4_800), pts: 0)
    out += a.drainReady()
    a.appendRender(ramp(4_320, 4_800), pts: 0.09)
    out += a.drainReady()
    a.appendCapture(zeros(9_600), pts: 0)
    out += a.drainReady()
    out += a.flush()
    #expect(a.stats.renderTrims == 1)
    try #require(p.renders.count == 20)
    #expect(p.renders[10][0] == 4_800)
}

@Test func followsRenderPTSUnderClockDrift() {
    let p = FakeProcessor()
    let a = makeAligner(p)
    var out: [Float] = []
    for k in 0..<500 {  // 5 s of capture; the render's pts run 1% fast
        a.appendRender(zeros(480), pts: Double(k) * 0.0101)
        out += a.drainReady()
        a.appendCapture(zeros(480), pts: Double(k) * 0.01)
        out += a.drainReady()
    }
    #expect(a.stats.renderGapFills >= 10)
    #expect(p.calls.filter { $0 == "R" }.count == p.calls.filter { $0 == "C" }.count)
}

@Test func boundsRenderWhenCaptureStalls() {
    let p = FakeProcessor()
    let clock = ManualClock()
    let a = makeAligner(p, clock: clock)
    var out: [Float] = []
    let ones = [Float](repeating: 1, count: 10 * 48_000)
    var i = 0
    while i < ones.count {
        let e = min(i + 1_024, ones.count)
        a.appendRender(Array(ones[i..<e]), pts: Double(i) / 48_000)
        out += a.drainReady()
        i = e
    }
    #expect(a.bufferedRenderSamples <= 96_000)
    clock.t = 10.0
    a.appendCapture(zeros(480), pts: 10.0)
    out += a.drainReady()
    clock.t += 0.251
    out += a.drainReady()
    #expect(out.count == 480)
    #expect(p.calls == ["R", "C"])
    #expect(a.stats.owedFrames == 1)
}

@Test func keepsReferenceAlignedAfterAMicStall() throws {
    // Review Focus 2 mid-recording: 1 s of mic, a 5 s mic stall while system audio keeps
    // flowing (30 ms late), then 1 s more mic. Every render sample's value is its own index,
    // so each reference must be the system audio from 100 ms (the lead) after its mic frame.
    let p = FakeProcessor()
    let clock = ManualClock()
    let a = makeAligner(p, clock: clock)
    struct Delivery { var at: Int; var isRender: Bool; var start: Int }  // times in 48 kHz samples
    var deliveries: [Delivery] = []
    for start in stride(from: 0, to: 7 * 48_000, by: 480) {
        deliveries.append(Delivery(at: start + 480 + 1_440, isRender: true, start: start))
        if start < 48_000 || start >= 6 * 48_000 {
            deliveries.append(Delivery(at: start + 480, isRender: false, start: start))
        }
    }
    deliveries.sort { ($0.at, $0.isRender ? 1 : 0) < ($1.at, $1.isRender ? 1 : 0) }
    var out: [Float] = []
    for d in deliveries {
        clock.t = Double(d.at) / 48_000
        if d.isRender {
            a.appendRender(ramp(d.start, 480), pts: Double(d.start) / 48_000)
        } else {
            a.appendCapture(zeros(480), pts: Double(d.start) / 48_000)
        }
        out += a.drainReady()
    }
    out += a.flush()
    #expect(out.count == 2 * 48_000)
    try #require(p.renders.count == 200)
    // Frames 0–99 are 0–1 s, frames 100–189 are 6–6.9 s; later frames' reference runs past the render's end.
    let micStarts = (0..<190).map { $0 < 100 ? $0 * 480 : 6 * 48_000 + ($0 - 100) * 480 }
    #expect(micStarts.indices.allSatisfy { p.renders[$0][0] == Float(micStarts[$0] + 4_800) })
    #expect(a.stats.owedFrames == 0)
    #expect(a.stats.referenceMoves == 1)
}

@Test func reportsHowLongTheReleasedMicWaited() {
    let p = FakeProcessor()
    let clock = ManualClock()
    let a = makeAligner(p, clock: clock)
    // A frame released by its reference arriving 0.15 s after it did.
    a.appendCapture(zeros(480), pts: 0)
    #expect(a.drainReady().isEmpty)
    clock.t = 0.15
    a.appendRender(ramp(0, 5_280), pts: 0)
    #expect(a.drainReady().count == 480)
    #expect(a.lastReleaseHoldSeconds == 0.15)
    // Two frames released together, which arrived at 0.2 and 0.22 s: the first one's wait.
    clock.t = 0.2
    a.appendCapture(zeros(480), pts: 0.01)
    #expect(a.drainReady().isEmpty)
    clock.t = 0.22
    a.appendCapture(zeros(480), pts: 0.02)
    #expect(a.drainReady().isEmpty)
    clock.t = 0.26
    a.appendRender(ramp(5_280, 960), pts: 0.11)
    #expect(a.drainReady().count == 960)
    #expect(abs(a.lastReleaseHoldSeconds - 0.06) < 1e-9)
    // A frame whose reference is already there goes straight out: it waited for nothing.
    a.appendRender(ramp(6_240, 480), pts: 0.13)
    #expect(a.drainReady().isEmpty)
    clock.t = 0.3
    a.appendCapture(zeros(480), pts: 0.03)
    #expect(a.drainReady().count == 480)
    #expect(a.lastReleaseHoldSeconds == 0)
}

@Test func flushReportsHowLongItsFirstFrameWaited() {
    let p = FakeProcessor()
    let clock = ManualClock()
    let a = makeAligner(p, clock: clock)
    // At stop: a frame still waiting for its reference, and a partial frame after it.
    clock.t = 1.0
    a.appendCapture(zeros(480 + 200), pts: 1.0)
    #expect(a.drainReady().isEmpty)
    clock.t = 1.2
    #expect(a.flush().count == 680)
    #expect(abs(a.lastReleaseHoldSeconds - 0.2) < 1e-9)
    // Only a partial frame left: it has waited since the buffer that brought its last sample.
    clock.t = 2.0
    a.appendCapture(zeros(300), pts: nil)
    #expect(a.drainReady().isEmpty)
    clock.t = 2.05
    #expect(a.flush().count == 300)
    #expect(abs(a.lastReleaseHoldSeconds - 0.05) < 1e-9)
}

@Test func flushReturnsEveryPendingSample() {
    let p = FakeProcessor()
    let a = makeAligner(p)
    a.appendCapture(zeros(1_000), pts: 0)
    _ = a.drainReady()
    #expect(a.flush().count == 1_000)
    #expect(p.captures == 3)
}

@Test func passesRawAudioThroughAfterProcessorFailure() {
    let p = FakeProcessor()
    p.failOnCapture = 3
    let a = makeAligner(p)
    var out: [Float] = []
    a.appendRender(zeros(7_200), pts: 0)
    out += a.drainReady()
    a.appendCapture([Float](repeating: 1, count: 5 * 480), pts: 0)
    out += a.drainReady()
    #expect(out.count == 5 * 480)
    #expect(out.prefix(2 * 480).allSatisfy { $0 == 0.5 })
    #expect(out.dropFirst(2 * 480).allSatisfy { $0 == 1.0 })
    #expect(a.stats.failed)
    #expect(p.captures == 3)
}

@Test func retargetsLeadWhenLockedDelayLeavesWindow() {
    let early = statsAfterOneProcessedFrame(lock: 10)
    #expect(early.leadMs == 200)
    #expect(early.leadChanges == 1)
    let late = statsAfterOneProcessedFrame(lock: 450)
    #expect(late.leadMs == -200)
}

@Test func keepsLeadInsideTheWorkingWindow() {
    let stats = statsAfterOneProcessedFrame(lock: 60)
    #expect(stats.leadMs == 100)
    #expect(stats.leadChanges == 0)
}

/// Reports a 10 ms lock until it's reset, then none, and counts the resets.
final class CountingLagTracker: EchoLagTracking {
    var lockedLagMs: Double? = 10
    var resetCount = 0
    func append(reference: [Float], observed: [Float]) {}
    func reset() { resetCount += 1; lockedLagMs = nil }
}

@Test func retargetResetsTheTracker() {
    let p = FakeProcessor()
    let tracker = CountingLagTracker()
    let a = EchoAligner(processor: p, tracker: tracker, now: { 0 })
    a.appendRender(zeros(12_000), pts: 0)  // reference for 3 frames, even at the 200 ms lead
    _ = a.drainReady()
    a.appendCapture(zeros(3 * 480), pts: 0)
    _ = a.drainReady()
    #expect(p.captures == 3)
    #expect(tracker.resetCount == 1)
    #expect(a.stats.leadChanges == 1)
}

@Test func monoMixAveragesChannels() {
    #expect(EchoAudio.monoMix([[1, 3], [3, 5]]) == [2, 4])
    #expect(EchoAudio.monoMix([[1, 2]]) == [1, 2])
}

@Test func cancelsEchoThroughAlignerWithLateSystemAudio() throws {
    let far = EchoTestSignals.speechLike(seconds: 12, seed: 11)
    let mic = EchoTestSignals.echo(of: far, delayMs: 60, gainDB: -10)
    let out = try runWithLateSystemAudio(far: far, mic: mic)
    try #require(out.count == mic.count)
    let tail = (6 * 48_000)..<(12 * 48_000)
    #expect(EchoTestSignals.rmsDB(mic[tail]) - EchoTestSignals.rmsDB(out[tail]) >= 20)
}

@Test func noEchoLeavesMicWithin1dB() throws {
    let far = EchoTestSignals.speechLike(seconds: 8, seed: 12)
    let mic = EchoTestSignals.tone(hz: 1_000, dbfs: -35, seconds: 8)
    let out = try runWithLateSystemAudio(far: far, mic: mic)
    try #require(out.count == mic.count)
    let window = (2 * 48_000)..<(8 * 48_000)
    #expect(abs(EchoTestSignals.rmsDB(out[window]) - EchoTestSignals.rmsDB(mic[window])) <= 1)
}
