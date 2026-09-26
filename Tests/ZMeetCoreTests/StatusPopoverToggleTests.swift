import Foundation
import Testing
@testable import ZMeetCore

private let now = Date(timeIntervalSinceReferenceDate: 1_000_000)

@Test func toggleClosesWhenShown() {
    #expect(StatusPopoverToggle.action(isShown: true, lastClosedAt: nil, now: now) == .close)
}

@Test func toggleOpensWhenNeverShown() {
    #expect(StatusPopoverToggle.action(isShown: false, lastClosedAt: nil, now: now) == .open)
}

/// A transient popover closes itself on the icon click's mouse-down (the icon is
/// "outside" the popover). That same click's mouse-up must not reopen it.
@Test func toggleIgnoresTheClickThatJustClosedIt() {
    let closed = now.addingTimeInterval(-0.1)
    #expect(StatusPopoverToggle.action(isShown: false, lastClosedAt: closed, now: now) == .ignore)
}

@Test func toggleOpensOnALaterClick() {
    let closed = now.addingTimeInterval(-1)
    #expect(StatusPopoverToggle.action(isShown: false, lastClosedAt: closed, now: now) == .open)
}

@Test func toggleReopensAtTheGuardBoundary() {
    let closed = now.addingTimeInterval(-StatusPopoverToggle.reopenGuard)
    #expect(StatusPopoverToggle.action(isShown: false, lastClosedAt: closed, now: now) == .open)
}
