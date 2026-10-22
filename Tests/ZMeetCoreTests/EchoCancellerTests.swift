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
