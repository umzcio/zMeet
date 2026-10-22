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
