import Foundation
import Testing
@testable import ZMeetCore

private let rate = 48_000.0
private let priming = 14_400  // 300 ms, the recorder's priming

/// AVAudioPlayerNode as the recorder uses it: what's queued plays back to back, and audio
/// queued after the player has run dry starts at once.
private struct QueuedPlayer {
    private(set) var end = 0.0
    /// Queues `frames` at clock time `time` and returns when they start playing.
    mutating func queue(_ frames: Int, at time: Double) -> Double {
        let start = max(end, time)
        end = start + Double(frames) / rate
        return start
    }
}

/// One buffer of a stream: when its first frame was captured (host seconds), its length,
/// and its PTS (the capture time unless a test changes it).
private struct StreamBuffer {
    var capture: Double
    var frames: Int
    var pts: Double?
}

/// Contiguous buffers of `frames` from `start` up to `end` seconds, except those starting
/// inside `gaps` (a stall, lost buffers, or audio nothing was sent for).
private func stream(frames: Int, from start: Double = 0, to end: Double, gaps: [Range<Double>] = []) -> [StreamBuffer] {
    var buffers: [StreamBuffer] = []
    var index = Int((start * rate).rounded())
    while index < Int((end * rate).rounded()) {
        let capture = Double(index) / rate
        if !gaps.contains(where: { $0.contains(capture) }) {
            buffers.append(StreamBuffer(capture: capture, frames: frames, pts: capture))
        }
        index += frames
    }
    return buffers
}

private struct Playback {
    /// For each buffer, how long after its capture its first frame played.
    var delays: [Double]
    var schedule: PrimedPlaybackSchedule
    /// Every silence the schedule asked for, in order.
    var silences: [PrimedPlaybackSchedule.Silence]
}

/// Plays `buffers` through a primed player the way the recorder does. Each buffer arrives
/// `delay` after its last frame was captured, and its frames reach the player `hold` after
/// that: whole buffers (the system audio), or, given `piece`, pieces of that many frames of
/// the contiguous stream, each `hold` after the buffer that completes it arrived (the echo
/// pipeline's mic frames).
private func play(_ buffers: [StreamBuffer], delay: Double, hold: Double = 0, piece: Int? = nil) -> Playback {
    var schedule = PrimedPlaybackSchedule(primingFrames: priming, toleranceFrames: 96, sampleRate: rate)
    var player = QueuedPlayer()
    var starts: [Int] = []
    var arrivals: [Double] = []
    var total = 0
    for buffer in buffers {
        starts.append(total)
        arrivals.append(buffer.capture + Double(buffer.frames) / rate + delay)
        total += buffer.frames
    }
    var releases: [(time: Double, frames: Int)] = []
    if let piece {
        var from = 0
        var last = 0  // the buffer that completes the piece
        while from < total {
            let to = min(from + piece, total)
            while starts[last] + buffers[last].frames < to { last += 1 }
            releases.append((arrivals[last] + hold, to - from))
            from = to
        }
    } else {
        releases = buffers.indices.map { (arrivals[$0] + hold, buffers[$0].frames) }
    }
    var delays = [Double](repeating: .nan, count: buffers.count)
    var silences: [PrimedPlaybackSchedule.Silence] = []
    var arrived = 0
    var scheduled = 0
    var nextStart = 0
    for release in releases {
        while arrived < buffers.count, arrivals[arrived] <= release.time {
            schedule.arrive(frames: buffers[arrived].frames, pts: buffers[arrived].pts, at: arrivals[arrived])
            arrived += 1
        }
        let asked = schedule.schedule(frames: release.frames, at: release.time)
        silences += asked
        var segment = 0
        for silence in asked + [PrimedPlaybackSchedule.Silence(offset: release.frames, frames: 0)] {
            if silence.offset > segment {
                let begins = player.queue(silence.offset - segment, at: release.time)
                while nextStart < buffers.count, starts[nextStart] < scheduled + silence.offset {
                    let into = Double(starts[nextStart] - scheduled - segment) / rate
                    delays[nextStart] = begins + into - buffers[nextStart].capture
                    nextStart += 1
                }
                segment = silence.offset
            }
            if silence.frames > 0 { _ = player.queue(silence.frames, at: release.time) }
        }
        scheduled += release.frames
    }
    return Playback(delays: delays, schedule: schedule, silences: silences)
}

/// How far, in ms, any buffer's playback delay strays from the first buffer's.
private func strayMs(_ delays: [Double]) -> Double {
    guard let first = delays.first else { return 0 }
    return delays.map { abs($0 - first) * 1_000 }.max() ?? 0
}

@Test func primedScheduleQueuesThePrimingAheadOfTheFirstAudio() {
    var system = PrimedPlaybackSchedule(primingFrames: priming, toleranceFrames: 96, sampleRate: rate)
    system.arrive(frames: 1_024, pts: 5, at: 5.05)
    #expect(system.schedule(frames: 1_024, at: 5.05) == [.init(offset: 0, frames: 14_400)])
    system.arrive(frames: 1_024, pts: 5 + 1_024 / rate, at: 5.05 + 1_024 / rate)
    #expect(system.schedule(frames: 1_024, at: 5.05 + 1_024 / rate).isEmpty)
    // The mic reaches its player after the echo pipeline's hold, which counts against the priming.
    var mic = PrimedPlaybackSchedule(primingFrames: priming, toleranceFrames: 96, sampleRate: rate)
    mic.arrive(frames: 480, pts: 5, at: 5.02)
    #expect(mic.schedule(frames: 480, at: 5.17) == [.init(offset: 0, frames: 14_400 - 7_200)])
}

@Test func primedScheduleKeepsTheMixAlignedAsWithoutPriming() {
    // The review's real-player run: system audio 30 ms late with a 1.5 s gap (nothing sent),
    // mic 10 ms late, held 150 ms, with a 500 ms stall. Unprimed, each buffer plays as it
    // arrives, so mic minus system is (480 − 1 024) / 48 000 + (0.01 − 0.03) s throughout.
    let systemBuffers = stream(frames: 1_024, to: 7, gaps: [2.6..<4.1])
    let micBuffers = stream(frames: 480, to: 7, gaps: [5.0..<5.5])
    let system = play(systemBuffers, delay: 0.03)
    let mic = play(micBuffers, delay: 0.01, hold: 0.15)
    let unprimed = (480 - 1_024) / rate + (0.01 - 0.03)
    var offsetsMs: [Double] = []
    for (s, buffer) in systemBuffers.enumerated() {
        // Where buffers of both streams start together (every 320 ms).
        guard let m = micBuffers.firstIndex(where: { $0.capture == buffer.capture }) else { continue }
        offsetsMs.append(((mic.delays[m] - system.delays[s]) - unprimed) * 1_000)
    }
    #expect(offsetsMs.count >= 12)
    #expect(offsetsMs.allSatisfy { abs($0) < 0.5 }, "mix offset change by capture time (ms): \(offsetsMs)")
}

@Test func primedScheduleKeepsTheDelayThroughAShortGap() {
    let p = play(stream(frames: 1_024, to: 5, gaps: [2.6..<2.8]), delay: 0.03)
    #expect(strayMs(p.delays) < 0.5)
    #expect(p.schedule.gaps == 1)
}

@Test func primedScheduleKeepsTheDelayThroughGapsLongerThanThePriming() {
    // One sound, then nothing until the call starts; later a 1.5 s pause with nothing sent.
    let p = play(stream(frames: 1_024, to: 9, gaps: [0.4..<3.0, 5.0..<6.5]), delay: 0.03)
    #expect(strayMs(p.delays) < 0.5)
    // Each gap outlasted what the player had queued, so each got the priming's worth, once.
    #expect(p.silences.map(\.frames) == [14_400, 14_400, 14_400])
}

@Test func primedScheduleKeepsTheHeldMicDelayThroughAStall() {
    let p = play(stream(frames: 480, to: 5, gaps: [2.6..<3.1]), delay: 0.01, hold: 0.15)
    #expect(strayMs(p.delays) < 0.5)
}

@Test func primedScheduleKeepsTheHeldMicDelayThroughLostBuffers() {
    // 40 ms lost while the player still has plenty queued: the gap goes back in full.
    let p = play(stream(frames: 480, to: 3, gaps: [1.0..<1.04]), delay: 0.01, hold: 0.15)
    #expect(strayMs(p.delays) < 0.5)
    #expect(p.silences.last == .init(offset: 0, frames: 1_920))
}

@Test func primedSchedulePutsTheSilenceWhereTheJumpLandsInsideAPiece() {
    // The echo pipeline releases the mic in 480-frame frames, so a buffer's start can fall
    // inside a released piece; the silence has to go exactly there.
    let p = play(stream(frames: 1_024, to: 5, gaps: [1.0..<1.03, 2.0..<2.5]), delay: 0.01, hold: 0.12, piece: 480)
    #expect(strayMs(p.delays) < 0.5)
    #expect(p.silences.dropFirst().allSatisfy { $0.offset > 0 })
    #expect(p.schedule.gaps == 2)
}

@Test func primedScheduleCountsAnOverlapAgainstTheNextGap() {
    // A 480-frame buffer repeating the last 10 ms plays in full, so the player runs 10 ms
    // late until the next gap, which gets 10 ms less silence.
    var buffers = stream(frames: 1_024, to: 3, gaps: [2.0..<2.05])
    let k = 40
    let repeated = StreamBuffer(capture: buffers[k].capture - 480 / rate, frames: 480, pts: buffers[k].capture - 480 / rate)
    buffers.insert(repeated, at: k)
    let p = play(buffers, delay: 0.03)
    let gap = buffers.firstIndex { $0.capture >= 2.0 }!
    let base = p.delays[0]
    #expect(p.delays[(k + 1)..<gap].allSatisfy { abs($0 - base - 0.01) < 0.000_5 })
    #expect(p.delays[gap...].allSatisfy { abs($0 - base) < 0.000_5 })
    #expect(p.silences.last == .init(offset: 0, frames: 3 * 1_024 - 480))
}

@Test func primedScheduleDoesNotLetJitterAddUp() {
    // Every 50th system buffer is stamped 3 ms late; the next is back on time. Only the first
    // gets silence: after it the player is 3 ms late, which absorbs every later one.
    var buffers = stream(frames: 1_024, to: 30)
    for k in stride(from: 25, to: buffers.count, by: 50) { buffers[k].pts! += 0.003 }
    let p = play(buffers, delay: 0.03)
    #expect(p.schedule.gaps >= 25)
    #expect(p.schedule.gapSilenceFrames == 144)
    #expect(strayMs(p.delays) < 3.01)
}

@Test func primedScheduleLeavesClockDriftAlone() {
    // A stream whose clock runs 100 ppm slow or fast against the host clock its PTS use:
    // it drifts 6 ms in a minute, never 2 ms between two buffers, and gets no silence.
    for ppm in [100.0, -100.0] {
        var buffers = stream(frames: 1_024, to: 60)
        for k in buffers.indices { buffers[k].pts = buffers[k].capture * (1 + ppm / 1_000_000) }
        let p = play(buffers, delay: 0.03)
        #expect(p.schedule.gaps == 0)
        #expect(p.silences == [.init(offset: 0, frames: 14_400)])
    }
}

@Test func primedScheduleTreatsMissingPTSAsContiguous() {
    var buffers = stream(frames: 1_024, to: 3, gaps: [1.0..<1.5])
    for k in buffers.indices { buffers[k].pts = nil }
    let p = play(buffers, delay: 0.03)
    #expect(p.silences == [.init(offset: 0, frames: 14_400)])
    #expect(p.schedule.gaps == 0)
}

@Test func primedScheduleForgetsTheLatenessWhenThePlayerRunsDry() {
    // An overlap leaves the player 10 ms late; a gap longer than it has queued runs it dry,
    // which plays that out too, so the gap after that gets its silence in full.
    var buffers = stream(frames: 1_024, to: 5, gaps: [2.0..<3.5, 4.0..<4.05])
    let repeated = StreamBuffer(capture: buffers[40].capture - 480 / rate, frames: 480, pts: buffers[40].capture - 480 / rate)
    buffers.insert(repeated, at: 40)
    let p = play(buffers, delay: 0.03)
    let afterLongGap = buffers.firstIndex { $0.capture >= 3.5 }!
    #expect(p.delays[afterLongGap...].allSatisfy { abs($0 - p.delays[0]) < 0.000_5 })
    let lost = stream(frames: 1_024, to: 5).count - stream(frames: 1_024, to: 5, gaps: [4.0..<4.05]).count
    #expect(lost == 2)
    #expect(p.silences.last == .init(offset: 0, frames: lost * 1_024))
}

@Test func primedScheduleRecoversFromACorruptTimestamp() {
    // One buffer stamped 10 s late: its "gap" costs at most the priming, and the jump back
    // can't stop later gaps from being filled; the next long one restores the delay.
    var buffers = stream(frames: 1_024, to: 6, gaps: [3.0..<4.5])
    buffers[50].pts! += 10
    let p = play(buffers, delay: 0.03)
    let afterGap = buffers.firstIndex { $0.capture >= 4.5 }!
    #expect(p.delays[afterGap...].allSatisfy { abs($0 - p.delays[0]) < 0.000_5 })
    #expect(p.schedule.gapSilenceFrames <= 2 * 14_400)
}

@Test func primedScheduleLeavesJumpsWithinTheToleranceAlone() {
    var buffers = stream(frames: 1_024, to: 3)
    for k in 40..<buffers.count { buffers[k].pts! += 91 / rate }        // 1.9 ms: left alone
    for k in 80..<buffers.count { buffers[k].pts! += 101 / rate }       // 2.1 ms more: a gap
    let p = play(buffers, delay: 0.03)
    #expect(p.silences == [.init(offset: 0, frames: 14_400), .init(offset: 0, frames: 101)])
}
