import Foundation
import Testing
@testable import ZMeetCore

private let rate = 48_000.0
/// The recorder's priming, 300 ms: what each player's queue is kept at.
private let target = 14_400
/// The controller's default tolerance, 10 ms.
private let tolerance = 480

/// AVAudioPlayerNode as the recorder drives it, started at host time 0. Its sample position
/// runs at `framesPerSecond` whether or not anything is queued, and that position is what the
/// recorder reads (`nowFrames`). What's queued plays back to back; audio queued after the queue
/// has run dry starts at once.
private struct ModelPlayer {
    var framesPerSecond = rate
    /// Where the queue ends, in player frames.
    private var queueEnd = 0.0

    /// The position the recorder reads at host time `time`: whole frames played.
    func position(at time: Double) -> Int64 { Int64((time * framesPerSecond).rounded(.down)) }

    /// Queues `frames` at host time `time`; returns the host time the first of them plays.
    mutating func queue(_ frames: Int, at time: Double) -> Double {
        let start = max(queueEnd, time * framesPerSecond)
        queueEnd = start + Double(frames)
        return start / framesPerSecond
    }
}

/// One stream on its way to its player, as the recorder schedules it: the silence the
/// controller asks for, then the audio.
private struct Feed {
    var player = ModelPlayer()
    var controller = PlaybackQueueController()
    /// The silence asked for ahead of each buffer, in order.
    private(set) var silences: [Int] = []

    /// Schedules `frames` at host time `time` toward `targetFrames`; returns when the first
    /// of them plays.
    mutating func schedule(_ frames: Int, at time: Double, targetFrames: Int = target) -> Double {
        let silence = controller.silenceBefore(frames: frames, nowFrames: player.position(at: time),
                                               targetFrames: targetFrames)
        silences.append(silence)
        if silence > 0 { _ = player.queue(silence, at: time) }
        return player.queue(frames, at: time)
    }
}

/// Whether two host times are within a frame of each other: the player's position is whole
/// frames, so a time between two frames can come out a frame either way.
private func withinAFrame(_ a: Double, _ b: Double) -> Bool { abs(a - b) <= 1.000_001 / rate }

/// When each buffer of a stream arrives, in host seconds: `frames` each, made at
/// `framesPerSecond` from host time 0 (its own clock, independent of the player's), each
/// arriving 30 ms after its last frame was made. Buffers whose first frame falls in `quiet`
/// never arrive.
private func arrivals(frames: Int, framesPerSecond: Double = rate, until end: Double,
                      quiet: [Range<Double>] = []) -> [Double] {
    var times: [Double] = []
    var made = 0
    while Double(made) / framesPerSecond < end {
        let first = Double(made) / framesPerSecond
        made += frames
        if !quiet.contains(where: { $0.contains(first) }) {
            times.append(Double(made) / framesPerSecond + 0.03)
        }
    }
    return times
}

@Test func primesToTargetOnFirstBuffer() {
    // Before the player's first render the recorder reads no position, which counts as 0.
    var unrendered = PlaybackQueueController()
    #expect(unrendered.silenceBefore(frames: 1_024, nowFrames: nil, targetFrames: target) == 14_400)
    #expect(unrendered.scheduledEnd == 15_424)
    // Usually the player has been running a while: here 2 s, so its position is 96 000.
    var feed = Feed()
    let plays = feed.schedule(1_024, at: 2.0)
    #expect(feed.silences == [14_400])
    #expect(abs(plays - 2.3) < 1e-9)
    #expect(feed.controller.scheduledEnd == 111_424)
    #expect(feed.controller.depth(nowFrames: 96_000) == 15_424)
    #expect(feed.controller.insertions == 1)
    #expect(feed.controller.insertedFrames == 14_400)
}

@Test func addsNoSilenceAtTarget() {
    // A stream arriving as fast as its player plays, each buffer 0–9 ms late: the queue stays
    // within the tolerance of the target, so after the priming no silence goes in and every
    // buffer plays 300 ms after it was due.
    var feed = Feed()
    for (k, due) in arrivals(frames: 1_024, until: 10).enumerated() {
        let late = Double(k * 7 % 10) / 1_000
        #expect(withinAFrame(feed.schedule(1_024, at: due + late), due + 0.3))
    }
    #expect(feed.silences.first == 14_400)
    #expect(feed.silences.dropFirst().allSatisfy { $0 == 0 })
    // The edge: a queue exactly the tolerance short is left alone; one frame more and it's topped up.
    var edge = PlaybackQueueController()
    _ = edge.silenceBefore(frames: 1_024, nowFrames: 0, targetFrames: target)  // ends at 15 424
    #expect(edge.silenceBefore(frames: 1_024, nowFrames: 1_504, targetFrames: target) == 0)    // 13 920 queued
    #expect(edge.silenceBefore(frames: 1_024, nowFrames: 2_529, targetFrames: target) == 481)  // 13 919 queued
}

@Test func refillsAfterTheSourceGoesQuiet() {
    // Nothing arrives for 1.5 s (nothing sent during silence, or a stall): the player plays
    // out its 300 ms and runs dry. The first buffer after it gets the whole target again, so
    // it plays 300 ms after arriving, as every buffer before it did.
    var long = Feed()
    for time in arrivals(frames: 1_024, until: 6, quiet: [2.0..<3.5]) {
        #expect(withinAFrame(long.schedule(1_024, at: time), time + 0.3))
    }
    #expect(long.silences.filter { $0 > 0 } == [14_400, 14_400])
    #expect(long.controller.insertions == 2)
    #expect(long.controller.insertedFrames == 28_800)
    #expect(long.controller.depth(nowFrames: long.controller.scheduledEnd + 48_000) == 0)
    // 200 ms of nothing leaves 100 ms queued: the refill is exactly what didn't arrive.
    var short = Feed()
    let times = arrivals(frames: 1_024, until: 4, quiet: [2.0..<2.2])
    for time in times {
        #expect(withinAFrame(short.schedule(1_024, at: time), time + 0.3))
    }
    let missing = (arrivals(frames: 1_024, until: 4).count - times.count) * 1_024
    #expect(missing == 10_240)
    let refills = short.silences.dropFirst().filter { $0 > 0 }
    #expect(refills.count == 1)
    #expect(abs((refills.first ?? 0) - missing) <= 1, "refilled \(refills)")  // ±1: positions are whole frames
}

@Test func keepsASlowSourceAlignedUnderDrift() {
    // A mic whose clock runs 0.5% slower than the output's, for a minute: its player plays
    // 0.5% more than it gets, so the queue runs down by 300 ms over the minute. Topped up each
    // time it's more than the tolerance short, every buffer still plays within
    // target ± (tolerance + buffer) of arriving.
    var feed = Feed()
    let times = arrivals(frames: 1_024, framesPerSecond: rate * 0.995, until: 60)
    let delays = times.map { feed.schedule(1_024, at: $0) - $0 }
    let slack = Double(tolerance + 1_024) / rate
    #expect(delays.allSatisfy { abs($0 - 0.3) <= slack })
    // After the priming it was topped up, each time by more than the tolerance (never a click of
    // a few frames), and in all by what the source fell behind, less at most the tolerance it
    // may still be short at the end.
    #expect(feed.silences.first == 14_400)
    let refills = feed.silences.dropFirst().filter { $0 > 0 }
    #expect(refills.count > 0)
    #expect(feed.controller.insertions == 1 + refills.count)
    #expect(refills.allSatisfy { $0 > tolerance })
    let fellBehind = (times.last! - times.first!) * rate - Double((times.count - 1) * 1_024)
    let refilled = Double(refills.reduce(0, +))
    #expect(refilled <= fellBehind + 2 && refilled >= fellBehind - Double(tolerance) - 2,
            "refilled \(refilled) frames for \(fellBehind) behind")
}

@Test func neverTrimsAFastSource() {
    // A clock 0.5% fast: the queue grows by 300 ms over the minute and the stream drifts that
    // much later, as it does without the echo pipeline. Silence only ever goes in, so after
    // the priming none does.
    var feed = Feed()
    let times = arrivals(frames: 1_024, framesPerSecond: rate * 1.005, until: 60)
    let delays = times.map { feed.schedule(1_024, at: $0) - $0 }
    #expect(feed.silences.first == 14_400)
    #expect(feed.silences.dropFirst().allSatisfy { $0 == 0 })
    #expect(feed.controller.insertions == 1)
    #expect(feed.controller.insertedFrames == 14_400)
    // Nothing removed: the last buffer plays as much later as the source got ahead.
    let gotAhead = Double((times.count - 1) * 1_024) / rate - (times.last! - times.first!)
    #expect(gotAhead > 0.29)
    #expect(abs(delays.last! - (0.3 + gotAhead)) < 2 / rate)
}

@Test func micTargetSubtractsTheHold() {
    // The system audio and the mic arrive together every 10 ms. The system audio goes to its
    // player at once; the mic first waits in the echo pipeline for its reference, 150 ms for
    // the first buffer and 100–150 ms after. Then the mic stalls for 0.5 s while the system
    // audio keeps coming, and comes back held 120 ms. Its target is the priming less its
    // hold, so each mic buffer plays with the system buffer that arrived with it.
    var system = Feed()
    var mic = Feed()
    var released = 0.0
    var compared = 0
    for k in 0..<400 {
        let arrival = 0.05 + Double(k) * 0.01
        let systemPlays = system.schedule(480, at: arrival)
        guard !(200..<250).contains(k) else { continue }
        let wait = k == 0 ? 0.15 : k < 200 ? 0.10 + Double(k * 7 % 6) / 100 : 0.12
        released = max(released, arrival + wait)  // in order, as the pipeline releases
        let hold = released - arrival
        let micPlays = mic.schedule(480, at: released, targetFrames: max(0, target - Int((hold * rate).rounded())))
        #expect(abs(micPlays - systemPlays) <= Double(tolerance) / rate, "buffer \(k)")
        compared += 1
    }
    #expect(compared == 350)
    // The priming less the first hold, then, after the stall ran the player dry, the priming
    // less the new hold; the changing holds in between needed nothing.
    #expect(mic.silences.filter { $0 > 0 } == [7_200, 8_640])
}
