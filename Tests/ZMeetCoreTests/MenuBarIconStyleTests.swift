import Testing
@testable import ZMeetCore

@Test func idleIsThePlainIcon() {
    #expect(MenuBarIconStyle.style(for: .idle) == .plain)
}

/// A glanceable hint that there's a meeting you can record — for when you
/// missed the banner.
@Test func meetingDetectedAddsTheGreenDot() {
    #expect(MenuBarIconStyle.style(for: .meetingDetected) == .plainWithDot)
}

@Test func recordingTurnsTheZGreen() {
    #expect(MenuBarIconStyle.style(for: .recording) == .greenZ)
}

/// Deliberate: processing runs in the background — the menu shows
/// "Processing…" and the "Notes ready" banner announces completion — so the
/// icon stays plain rather than competing with the recording look.
@Test func processingStaysPlain() {
    #expect(MenuBarIconStyle.style(for: .processing) == .plain)
}
