import Testing
@testable import ZMeetCore

private func feed(_ t: inout EchoLagTracker, far: [Float], mic: [Float], chunk: Int = 4_800) {
    var i = 0
    while i < far.count { let e = min(i + chunk, far.count); t.append(reference: Array(far[i..<e]), observed: Array(mic[i..<e])); i = e }
}

@Test func gccPhatFindsAPositiveLag() throws {
    let ref = Array(EchoTestSignals.speechLike(seconds: 2, seed: 7, rate: 16_000).prefix(16_384))
    let obs = EchoTestSignals.echo(of: ref, delayMs: 60, gainDB: -10, rate: 16_000)
    let e = try #require(GCCPhat.estimate(reference: ref, observed: obs, maxLagSamples: 9_600))
    #expect((958...962).contains(e.lagSamples))
    #expect(e.accepted)
}

@Test func gccPhatFindsANegativeLag() throws {
    let base = EchoTestSignals.speechLike(seconds: 3, seed: 8, rate: 16_000)
    let ref = Array(base[0..<16_384])
    let obs = Array(base[7_200..<(7_200 + 16_384)])  // observed leads by 450 ms
    let e = try #require(GCCPhat.estimate(reference: ref, observed: obs, maxLagSamples: 9_600))
    #expect((-7_202 ... -7_198).contains(e.lagSamples))
}

@Test func gccPhatReturnsNilForSilence() {
    let obs = Array(EchoTestSignals.speechLike(seconds: 2, seed: 9, rate: 16_000).prefix(16_384))
    #expect(GCCPhat.estimate(reference: [Float](repeating: 0, count: 16_384), observed: obs, maxLagSamples: 9_600) == nil)
}

@Test func gccPhatDoesNotAcceptUncorrelatedNoise() {
    let a = Array(EchoTestSignals.speechLike(seconds: 2, seed: 10, rate: 16_000).prefix(16_384))
    let b = Array(EchoTestSignals.speechLike(seconds: 2, seed: 11, rate: 16_000).prefix(16_384))
    #expect(GCCPhat.estimate(reference: a, observed: b, maxLagSamples: 9_600)?.accepted != true)
}

@Test func locksOntoAStableEcho() throws {
    var t = EchoLagTracker()
    let far = EchoTestSignals.speechLike(seconds: 8, seed: 3)
    feed(&t, far: far, mic: EchoTestSignals.echo(of: far, delayMs: 60, gainDB: -10))
    let lag = try #require(t.lockedLagMs)
    #expect(abs(lag - 60) <= 0.5)
}

@Test func holdsLockThroughSilence() throws {
    var t = EchoLagTracker()
    let far = EchoTestSignals.speechLike(seconds: 8, seed: 3)
    feed(&t, far: far, mic: EchoTestSignals.echo(of: far, delayMs: 60, gainDB: -10))
    let silence = [Float](repeating: 0, count: 6 * 48_000)
    feed(&t, far: silence, mic: silence)
    let lag = try #require(t.lockedLagMs)
    #expect(abs(lag - 60) <= 0.5)
}

@Test func movesDirectlyToANewConsistentLag() throws {
    var t = EchoLagTracker()
    let far1 = EchoTestSignals.speechLike(seconds: 8, seed: 3)
    feed(&t, far: far1, mic: EchoTestSignals.echo(of: far1, delayMs: 60, gainDB: -10))
    #expect(t.lockedLagMs != nil)
    let far2 = EchoTestSignals.speechLike(seconds: 8, seed: 4)
    let mic2 = EchoTestSignals.echo(of: far2, delayMs: 71, gainDB: -10)
    var i = 0
    while i < far2.count {
        let e = min(i + 4_800, far2.count)
        t.append(reference: Array(far2[i..<e]), observed: Array(mic2[i..<e]))
        #expect(t.lockedLagMs != nil)            // never drops to "no lock" while switching
        i = e
    }
    let lag = try #require(t.lockedLagMs)
    #expect(abs(lag - 71) <= 0.5)
}

@Test func neverLocksOnUncorrelatedNearEnd() {
    var t = EchoLagTracker()
    feed(&t, far: EchoTestSignals.speechLike(seconds: 8, seed: 4), mic: EchoTestSignals.speechLike(seconds: 8, seed: 5))
    #expect(t.lockedLagMs == nil)
}

@Test func resetClearsTheLock() {
    var t = EchoLagTracker()
    let far = EchoTestSignals.speechLike(seconds: 8, seed: 3)
    feed(&t, far: far, mic: EchoTestSignals.echo(of: far, delayMs: 60, gainDB: -10))
    t.reset()
    #expect(t.lockedLagMs == nil)
}
