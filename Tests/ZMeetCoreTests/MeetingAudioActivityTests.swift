import Testing
@testable import ZMeetCore

// startTicks: 2, endTicks: 3 for compact tests.
private func tracker() -> MeetingAudioActivity { MeetingAudioActivity(startTicks: 2, endTicks: 3) }

@Test func startsOnlyAfterSustainedActivity() {
    var t = tracker()
    #expect(t.update(active: true) == nil)     // 1 active — not yet
    #expect(t.update(active: true) == .started) // 2 consecutive — started
    #expect(t.isInMeeting == true)
    #expect(t.update(active: true) == nil)      // already in meeting
}

@Test func aBriefBlipDoesNotStart() {
    var t = tracker()
    #expect(t.update(active: true) == nil)
    #expect(t.update(active: false) == nil)     // blip resets the active run
    #expect(t.update(active: true) == nil)      // run restarts at 1
    #expect(t.update(active: true) == .started) // now 2 consecutive
}

@Test func neverEndsBeforeStarting() {
    var t = tracker()
    // Activity that never sustains to "started" must never emit .ended.
    for _ in 0..<10 {
        #expect(t.update(active: false) == nil)
    }
    #expect(t.isInMeeting == false)
}

@Test func endsOnlyAfterSustainedInactivityOnceInMeeting() {
    var t = tracker()
    _ = t.update(active: true); #expect(t.update(active: true) == .started)
    #expect(t.update(active: false) == nil)  // 1 inactive
    #expect(t.update(active: false) == nil)  // 2 inactive
    #expect(t.update(active: false) == .ended) // 3 consecutive inactive — ended
    #expect(t.isInMeeting == false)
}

@Test func inMeetingSurvivesShortAudioDrops() {
    var t = tracker()
    _ = t.update(active: true); _ = t.update(active: true) // started
    #expect(t.update(active: false) == nil)
    #expect(t.update(active: false) == nil)
    #expect(t.update(active: true) == nil)   // audio came back before endTicks
    #expect(t.isInMeeting == true)
    // Inactive run reset, so it takes another full endTicks to end.
    #expect(t.update(active: false) == nil)
    #expect(t.update(active: false) == nil)
    #expect(t.update(active: false) == .ended)
}

@Test func canStartAgainAfterEnding() {
    var t = tracker()
    _ = t.update(active: true); _ = t.update(active: true)        // started
    _ = t.update(active: false); _ = t.update(active: false); _ = t.update(active: false) // ended
    #expect(t.update(active: true) == nil)
    #expect(t.update(active: true) == .started)                  // a new meeting
}
