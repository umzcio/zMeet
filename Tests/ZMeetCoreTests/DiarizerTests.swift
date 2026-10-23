import Testing
@testable import ZMeetCore

@Test func diarizerInterleavesByStartTime() {
    let you = [TranscriptSegment(text: "Hello team.", start: 0.0),
               TranscriptSegment(text: "Let's start.", start: 4.0)]
    let others = [TranscriptSegment(text: "Hi!", start: 2.0)]
    let out = Diarizer().merge(you: you, others: others)
    #expect(out == "**You:** [0:00] Hello team.\n\n**Others:** [0:02] Hi!\n\n**You:** [0:04] Let's start.")
}

@Test func diarizerCoalescesConsecutiveSameSpeaker() {
    let you = [TranscriptSegment(text: "One.", start: 0.0),
               TranscriptSegment(text: "Two.", start: 1.0)]
    let others = [TranscriptSegment(text: "Three.", start: 2.0)]
    let out = Diarizer().merge(you: you, others: others)
    #expect(out == "**You:** [0:00] One. Two.\n\n**Others:** [0:02] Three.")
}

@Test func diarizerHandlesOneSideEmptyAndSkipsBlankSegments() {
    let you = [TranscriptSegment(text: "  ", start: 0.0),
               TranscriptSegment(text: "Real.", start: 1.0)]
    let out = Diarizer().merge(you: you, others: [])
    #expect(out == "**You:** [0:01] Real.")
    #expect(Diarizer().merge(you: [], others: []) == "")
}

@Test func diarizerBreaksEqualStartTiesDeterministicallyYouFirst() {
    let you = [TranscriptSegment(text: "You side.", start: 0.0)]
    let others = [TranscriptSegment(text: "Others side.", start: 0.0)]
    // Same inputs, many runs: the merge must consistently put You before
    // Others when both start at the same offset, regardless of sort stability.
    for _ in 0..<20 {
        let out = Diarizer().merge(you: you, others: others)
        #expect(out == "**You:** [0:00] You side.\n\n**Others:** [0:00] Others side.")
    }
}
