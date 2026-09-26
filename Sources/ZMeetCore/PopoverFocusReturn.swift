/// Whether closing the menu-bar popover should hand keyboard focus back to the app
/// that was frontmost before it opened. Opening the popover activates zMeet (so its
/// title field can take typing); without handing focus back, closing it by Esc or
/// an icon click leaves zMeet active with no key window and your next keystrokes
/// in Teams/Zoom go nowhere. The old SwiftUI panel avoided this by never
/// activating the app at all.
public enum PopoverFocusReturn {
    /// What the decision needs to know about one of zMeet's windows. The app layer
    /// fills this in from AppKit; the rule stays here, under test.
    public struct WindowTraits: Equatable, Sendable {
        public var isVisible: Bool
        /// The status item's own window or the popover's window.
        public var isOwnChrome: Bool
        public var isNonactivatingPanel: Bool
        public var isTitled: Bool

        public init(isVisible: Bool, isOwnChrome: Bool, isNonactivatingPanel: Bool, isTitled: Bool) {
            self.isVisible = isVisible
            self.isOwnChrome = isOwnChrome
            self.isNonactivatingPanel = isNonactivatingPanel
            self.isTitled = isTitled
        }
    }

    /// A window that still needs zMeet active: visible, not the status item or popover
    /// itself, and not a banner. Banners are untitled non-activating panels and work
    /// without zMeet being active; the mode picker is a titled one and does not —
    /// handing focus away mid-click could break it.
    public static func blocksFocusReturn(_ window: WindowTraits) -> Bool {
        window.isVisible && !window.isOwnChrome && !(window.isNonactivatingPanel && !window.isTitled)
    }

    /// Hand focus back only if zMeet is still active (the popover wasn't closed by
    /// clicking into another app, which already has focus), there's an app to return
    /// to, and no zMeet window still needs it.
    public static func shouldReturnFocus(appIsActive: Bool, hasPreviousApp: Bool, windows: [WindowTraits]) -> Bool {
        appIsActive && hasPreviousApp && !windows.contains(where: blocksFocusReturn)
    }
}
