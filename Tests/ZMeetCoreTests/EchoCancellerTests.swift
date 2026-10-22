import Foundation
import Testing
@testable import ZMeetCore

@Test func frameSizeIsTenMillisecondsAt48k() {
    #expect(EchoCanceller.sampleRate == 48_000)
    #expect(EchoCanceller.frameSize == 480)
}

@Test func cancelsSyntheticSpeakerEcho() throws {
    let canceller = try #require(EchoCanceller())
    let far = EchoTestSignals.speechLike(seconds: 12, seed: 1)
    let mic = EchoTestSignals.echo(of: far, delayMs: 60, gainDB: -10)
    let out = EchoTestSignals.runCanceller(canceller, mic: mic, far: far)
    let tail = (6 * 48_000)..<(12 * 48_000)
    #expect(EchoTestSignals.rmsDB(mic[tail]) - EchoTestSignals.rmsDB(out[tail]) >= 25)
}

@Test func leavesNearEndAloneWhenFarEndIsSilent() throws {
    let canceller = try #require(EchoCanceller())
    let mic = EchoTestSignals.tone(hz: 1_000, dbfs: -35, seconds: 4)
    let out = EchoTestSignals.runCanceller(canceller, mic: mic, far: [Float](repeating: 0, count: mic.count))
    let window = 48_000..<(4 * 48_000)
    #expect(abs(EchoTestSignals.rmsDB(out[window]) - EchoTestSignals.rmsDB(mic[window])) <= 1)
}

@Test func returnsEachMicSampleCaptureLatencySamplesLater() throws {
    // APM's band split and AEC3's 4 ms blocks hand each mic sample back a fixed 430 samples
    // (about 9 ms) after it went in, wherever it falls in the 10 ms frame and whether the
    // reference is silent or not. The recorder takes this off the mic player's target, so the
    // cleaned mic keeps its place in the mix.
    #expect(EchoCanceller.captureLatencySamples == 430)
    let silence = [Float](repeating: 0, count: 48_000)
    for offset in [0, 1, 97, 191, 300, 479] {
        let canceller = try #require(EchoCanceller())
        var mic = silence
        mic[24_000 + offset] = 0.5
        let out = EchoTestSignals.runCanceller(canceller, mic: mic, far: silence)
        let peak = try #require(out.indices.max { abs(out[$0]) < abs(out[$1]) })
        #expect(peak - (24_000 + offset) == EchoCanceller.captureLatencySamples,
                "impulse \(offset) samples into its frame")
    }
    // While the far end talks (with no echo of it in the mic), a 100 ms noise burst of the
    // user's comes back just as late: its cross-correlation with the output peaks there.
    let canceller = try #require(EchoCanceller())
    let far = EchoTestSignals.speechLike(seconds: 2, seed: 5)
    var generator = SeededGenerator(seed: 99)
    var mic = [Float](repeating: 0, count: far.count)
    let burst = 48_000..<52_800
    for i in burst {
        let window = 0.5 - 0.5 * cos(2 * Double.pi * Double(i - burst.lowerBound) / Double(burst.count))
        let uniform = Double(generator.next() >> 11) / Double(UInt64(1) << 53)
        mic[i] = Float(window * 0.3 * (2 * uniform - 1))
    }
    let out = EchoTestSignals.runCanceller(canceller, mic: mic, far: far)
    let scores = (0...960).map { lag in burst.reduce(0.0) { $0 + Double(mic[$1]) * Double(out[$1 + lag]) } }
    let lag = try #require(scores.indices.max { scores[$0] < scores[$1] })
    #expect(lag == EchoCanceller.captureLatencySamples)
}

@Test func statisticsAreEmptyOnlyBeforeTheFirstCaptureFrame() throws {
    let canceller = try #require(EchoCanceller())
    #expect(canceller.statistics == EchoStatistics())
    let silence = [Float](repeating: 0, count: EchoCanceller.frameSize)
    _ = EchoTestSignals.runCanceller(canceller, mic: silence, far: silence)
    let stats = canceller.statistics
    #expect(stats.echoReturnLossDB != nil)
    #expect(stats.echoReturnLossEnhancementDB != nil)
    #expect(stats.delayMs != nil)
}

@Test func statisticsDescribeTheConvergedCanceller() throws {
    let canceller = try #require(EchoCanceller())
    let far = EchoTestSignals.speechLike(seconds: 12, seed: 1)
    let mic = EchoTestSignals.echo(of: far, delayMs: 60, gainDB: -10)
    _ = EchoTestSignals.runCanceller(canceller, mic: mic, far: far)
    let stats = canceller.statistics
    let erle = try #require(stats.echoReturnLossEnhancementDB)
    let delay = try #require(stats.delayMs)
    #expect(erle >= 15)
    #expect((40...72).contains(delay))
}

@Test func statisticsStayCurrentAfterAnEarlierRead() throws {
    let far = EchoTestSignals.speechLike(seconds: 12, seed: 1)
    let mic = EchoTestSignals.echo(of: far, delayMs: 60, gainDB: -10)
    let split = 3 * 48_000  // whole 10 ms frames, so the two runs feed exactly the frames of one
    let polled = try #require(EchoCanceller())
    _ = EchoTestSignals.runCanceller(polled, mic: Array(mic[..<split]), far: Array(far[..<split]))
    let early = polled.statistics
    _ = EchoTestSignals.runCanceller(polled, mic: Array(mic[split...]), far: Array(far[split...]))
    let unpolled = try #require(EchoCanceller())
    _ = EchoTestSignals.runCanceller(unpolled, mic: mic, far: far)
    let late = polled.statistics
    #expect(late == unpolled.statistics)
    #expect(late != early)
}
