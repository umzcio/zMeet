import Testing
@testable import ZMeetCore

@Test func admitsUpToCapacityExactly() {
    var bp = MixWriteBackpressure(capacity: 3)
    let a1 = bp.admit()
    let a2 = bp.admit()
    let a3 = bp.admit()
    #expect(a1)
    #expect(a2)
    #expect(a3)
    #expect(bp.pending == 3)
    #expect(bp.dropped == 0)
}

@Test func admitPastCapacityFailsAndCountsDrop() {
    var bp = MixWriteBackpressure(capacity: 2)
    let a1 = bp.admit()
    let a2 = bp.admit()
    let a3 = bp.admit()
    #expect(a1)
    #expect(a2)
    #expect(!a3)
    #expect(bp.pending == 2)
    #expect(bp.dropped == 1)
}

@Test func releaseRestoresCapacity() {
    var bp = MixWriteBackpressure(capacity: 2)
    let a1 = bp.admit()
    let a2 = bp.admit()
    let a3 = bp.admit()
    #expect(a1)
    #expect(a2)
    #expect(!a3)
    bp.release()
    #expect(bp.pending == 1)
    let a4 = bp.admit()
    #expect(a4)
    #expect(bp.pending == 2)
}

@Test func releaseDroppingRestoresCapacityAndCountsDrop() {
    var bp = MixWriteBackpressure(capacity: 2)
    let a1 = bp.admit()
    #expect(a1)
    #expect(bp.dropped == 0)
    bp.releaseDropping()
    #expect(bp.pending == 0)
    #expect(bp.dropped == 1)
}

@Test func droppedIsMonotonicAcrossAdmitReleaseCycles() {
    var bp = MixWriteBackpressure(capacity: 1)
    let a1 = bp.admit()
    let a2 = bp.admit()
    #expect(a1)
    #expect(!a2)
    #expect(bp.dropped == 1)
    bp.release()
    let a3 = bp.admit()
    let a4 = bp.admit()
    #expect(a3)
    #expect(!a4)
    #expect(bp.dropped == 2)
}

@Test func releaseNeverGoesBelowZero() {
    var bp = MixWriteBackpressure(capacity: 2)
    bp.release()
    bp.release()
    #expect(bp.pending == 0)
}

@Test func resetZeroesBoth() {
    var bp = MixWriteBackpressure(capacity: 1)
    let a1 = bp.admit()
    let a2 = bp.admit()
    #expect(a1)
    #expect(!a2)
    bp.reset()
    #expect(bp.pending == 0)
    #expect(bp.dropped == 0)
}
