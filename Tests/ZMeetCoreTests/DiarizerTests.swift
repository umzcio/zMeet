import Testing
@testable import ZMeetCore

@Test func diarizerInterleavesByStartTime() {
    let you = [TranscriptSegment(text: "Hello team.", start: 0.0),
               TranscriptSegment(text: "Let's start.", start: 4.0)]
    let others = [TranscriptSegment(text: "Hi!", start: 2.0)]
    let out = Diarizer().merge(you: you, others: others)
    #expect(out == "**You:** Hello team.\n\n**Others:** Hi!\n\n**You:** Let's start.")
}

@Test func diarizerCoalescesConsecutiveSameSpeaker() {
    let you = [TranscriptSegment(text: "One.", start: 0.0),
               TranscriptSegment(text: "Two.", start: 1.0)]
    let others = [TranscriptSegment(text: "Three.", start: 2.0)]
    let out = Diarizer().merge(you: you, others: others)
    #expect(out == "**You:** One. Two.\n\n**Others:** Three.")
}

@Test func diarizerHandlesOneSideEmptyAndSkipsBlankSegments() {
    let you = [TranscriptSegment(text: "  ", start: 0.0),
               TranscriptSegment(text: "Real.", start: 1.0)]
    let out = Diarizer().merge(you: you, others: [])
    #expect(out == "**You:** Real.")
    #expect(Diarizer().merge(you: [], others: []) == "")
}
