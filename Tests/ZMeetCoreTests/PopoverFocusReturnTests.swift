import Testing
@testable import ZMeetCore

private typealias W = PopoverFocusReturn.WindowTraits
private let library = W(isVisible: true, isOwnChrome: false, isNonactivatingPanel: false, isTitled: true)
/// The Remote/Hybrid/In-person picker: a titled non-activating panel.
private let modePicker = W(isVisible: true, isOwnChrome: false, isNonactivatingPanel: true, isTitled: true)
/// "Meeting detected" / outcome banners: untitled non-activating panels.
private let banner = W(isVisible: true, isOwnChrome: false, isNonactivatingPanel: true, isTitled: false)
private let statusBarWindow = W(isVisible: true, isOwnChrome: true, isNonactivatingPanel: false, isTitled: false)
private let closedLibrary = W(isVisible: false, isOwnChrome: false, isNonactivatingPanel: false, isTitled: true)

/// The everyday case: glance at the popover from Teams, press Esc, keep typing.
@Test func focusReturnsWhenNothingElseIsOpen() {
    #expect(PopoverFocusReturn.shouldReturnFocus(appIsActive: true, hasPreviousApp: true,
                                                 windows: [statusBarWindow, closedLibrary]))
}

/// Banners work without zMeet being active, so they must not trap focus.
@Test func focusReturnsPastABanner() {
    #expect(PopoverFocusReturn.shouldReturnFocus(appIsActive: true, hasPreviousApp: true, windows: [banner]))
}

@Test func focusStaysWhileAWindowIsOpen() {
    #expect(!PopoverFocusReturn.shouldReturnFocus(appIsActive: true, hasPreviousApp: true, windows: [library]))
}

/// Start Recording closes the popover by clicking the mode picker — yanking focus
/// away mid-click could break the picker.
@Test func focusStaysWhileTheModePickerIsUp() {
    #expect(!PopoverFocusReturn.shouldReturnFocus(appIsActive: true, hasPreviousApp: true, windows: [modePicker]))
}

/// Closed by clicking into another app: that app already has focus.
@Test func focusIsLeftAloneWhenZMeetIsNotActive() {
    #expect(!PopoverFocusReturn.shouldReturnFocus(appIsActive: false, hasPreviousApp: true, windows: []))
}

@Test func focusIsLeftAloneWithNoPreviousApp() {
    #expect(!PopoverFocusReturn.shouldReturnFocus(appIsActive: true, hasPreviousApp: false, windows: []))
}
