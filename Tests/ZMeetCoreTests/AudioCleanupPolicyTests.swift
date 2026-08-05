import Foundation
import Testing
@testable import ZMeetCore

@Test func mayReplaceOriginalAllowsCompletedEqualLength() {
    #expect(AudioCleanupPolicy.mayReplaceOriginal(
        sourceFrames: 48_000, renderedFrames: 48_000,
        loopCompleted: true, toleranceFrames: 48_000
    ) == true)
}

@Test func mayReplaceOriginalRejectsCompletedButTooShort() {
    #expect(AudioCleanupPolicy.mayReplaceOriginal(
        sourceFrames: 48_000 * 60, renderedFrames: 10,
        loopCompleted: true, toleranceFrames: 48_000
    ) == false)
}

@Test func mayReplaceOriginalRejectsIncompleteLoopEvenAtFullLength() {
    #expect(AudioCleanupPolicy.mayReplaceOriginal(
        sourceFrames: 48_000 * 60, renderedFrames: 48_000 * 60,
        loopCompleted: false, toleranceFrames: 48_000
    ) == false)
}

@Test func mayReplaceOriginalAllowsWithinTolerance() {
    #expect(AudioCleanupPolicy.mayReplaceOriginal(
        sourceFrames: 48_000 * 60, renderedFrames: 47_999 * 60,
        loopCompleted: true, toleranceFrames: 48_000
    ) == true)
}
