import Testing
@testable import ZMeetCore

private let weekly = DetectedMeeting(app: "Microsoft Teams", title: "Weekly Sync | Microsoft Teams")

@Test func trackerStartsEmpty() {
    #expect(DetectedMeetingTracker().current == nil)
}

@Test func windowSignalAloneIsDetectedWithRealTitle() {
    var t = DetectedMeetingTracker()
    t.windowChanged(weekly)
    #expect(t.current == weekly)
}

/// Teams meetings whose subject lacks "Meeting"/"Call" never match a window —
/// audio is the only signal, so it must stand alone with a generic title.
@Test func audioSignalAloneIsDetectedWithGenericTitle() {
    var t = DetectedMeetingTracker()
    t.audioStarted(app: "Microsoft Teams")
    #expect(t.current == DetectedMeeting(app: "Microsoft Teams", title: "Microsoft Teams Meeting"))
}

@Test func windowTitleWinsWhenBothSignalsPresent() {
    var t = DetectedMeetingTracker()
    t.audioStarted(app: "Microsoft Teams")
    t.windowChanged(weekly)
    #expect(t.current == weekly)
}

/// A Teams lobby has no meeting window, yet the call is live — the meeting
/// must stay detected (and recordable) through it.
@Test func meetingStaysDetectedThroughLobbyWhileAudioLive() {
    var t = DetectedMeetingTracker()
    t.windowChanged(weekly)
    t.audioStarted(app: "Microsoft Teams")
    t.windowChanged(nil)
    #expect(t.current?.app == "Microsoft Teams")
}

@Test func meetingStaysDetectedWhileWindowUpAfterAudioEnds() {
    var t = DetectedMeetingTracker()
    t.windowChanged(weekly)
    t.audioStarted(app: "Microsoft Teams")
    t.audioEnded()
    #expect(t.current == weekly)
}

@Test func meetingClearsOnlyWhenBothSignalsGone() {
    var t = DetectedMeetingTracker()
    t.windowChanged(weekly)
    t.audioStarted(app: "Microsoft Teams")
    t.windowChanged(nil)
    #expect(t.current != nil)
    t.audioEnded()
    #expect(t.current == nil)
}

@Test func resetClearsBothSignals() {
    var t = DetectedMeetingTracker()
    t.windowChanged(weekly)
    t.audioStarted(app: "Zoom")
    t.reset()
    #expect(t.current == nil)
}
