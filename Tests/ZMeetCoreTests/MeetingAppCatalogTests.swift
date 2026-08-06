import Testing
@testable import ZMeetCore

// MARK: - DetectorGate truth table

@Test func detectorGateSkipsOnlyWhenAllThreeFalse() {
    let rows: [(hasDetectedWindow: Bool, isInMeeting: Bool, meetingAppRunning: Bool, expected: Bool)] = [
        (false, false, false, false), // the only skip
        (true,  false, false, true),
        (false, true,  false, true),
        (false, false, true,  true),
        (true,  true,  false, true),
        (true,  false, true,  true),
        (false, true,  true,  true),
        (true,  true,  true,  true),
    ]
    for row in rows {
        let result = DetectorGate.shouldFullScan(
            hasDetectedWindow: row.hasDetectedWindow,
            isInMeeting: row.isInMeeting,
            meetingAppRunning: row.meetingAppRunning)
        #expect(result == row.expected, "hasDetectedWindow=\(row.hasDetectedWindow) isInMeeting=\(row.isInMeeting) meetingAppRunning=\(row.meetingAppRunning)")
    }
}

// MARK: - matchMeetingWindow

@Test func zoomExactOwnerWithMeetingTitleMatches() {
    let m = MeetingAppCatalog.matchMeetingWindow(owner: "zoom.us", title: "Zoom Meeting")
    #expect(m?.app == "Zoom")
    #expect(m?.title == "Zoom Meeting")
}

@Test func zoomIdleWindowTitleDoesNotMatch() {
    #expect(MeetingAppCatalog.matchMeetingWindow(owner: "zoom.us", title: "Zoom Workplace") == nil)
}

@Test func zoomEmptyTitleHasNoMarkerSoNoMatch() {
    // Empty title can never contain a marker, so this can't match — and, by the
    // same logic, `defaultTitle` can never actually be selected by matchMeetingWindow:
    // reaching the return already requires a marker match, which requires non-empty
    // title. This mirrors the original detectMeeting()'s dead `title.isEmpty ? … : …`
    // branch faithfully (see plan 041's STOP condition) rather than "fixing" it.
    #expect(MeetingAppCatalog.matchMeetingWindow(owner: "zoom.us", title: "") == nil)
}

@Test func teamsExactOwnerMSTeamsWithCallTitleMatches() {
    let m = MeetingAppCatalog.matchMeetingWindow(owner: "MSTeams", title: "Weekly Call")
    #expect(m?.app == "Microsoft Teams")
    #expect(m?.title == "Weekly Call")
}

@Test func teamsOwnerContainsMicrosoftTeamsWithMeetingTitleMatches() {
    let m = MeetingAppCatalog.matchMeetingWindow(owner: "Microsoft Teams helper", title: "Standup Meeting")
    #expect(m?.app == "Microsoft Teams")
    #expect(m?.title == "Standup Meeting")
}

@Test func unrelatedOwnerWithMeetingLikeTitleDoesNotMatch() {
    #expect(MeetingAppCatalog.matchMeetingWindow(owner: "Safari", title: "Zoom Meeting tips") == nil)
}

@Test func titleMarkerMatchIsCaseInsensitive() {
    let m = MeetingAppCatalog.matchMeetingWindow(owner: "zoom.us", title: "zoom webinar")
    #expect(m?.app == "Zoom")
    #expect(m?.title == "zoom webinar")
}

// MARK: - appMatching

@Test func appMatchingPrefixMatchesTeamsHelperBundleIDs() {
    #expect(MeetingAppCatalog.appMatching(bundleID: "com.microsoft.teams2")?.name == "Microsoft Teams")
}

@Test func appMatchingPrefixMatchesZoomHelperBundleIDs() {
    #expect(MeetingAppCatalog.appMatching(bundleID: "us.zoom.xos")?.name == "Zoom")
}

@Test func appMatchingReturnsNilForUnrelatedBundleID() {
    #expect(MeetingAppCatalog.appMatching(bundleID: "com.apple.dt.Xcode") == nil)
}
