import Foundation

/// Decides what a click on the menu-bar icon does to its popover. A transient
/// NSPopover closes itself on mouse-down *outside* it — and the icon counts as
/// outside — so a click meant to close the popover first closes it, then the
/// icon's action (fired on mouse-up) sees "not shown" and would reopen it. A
/// click arriving within `reopenGuard` of a close is that same click.
public enum StatusPopoverToggle {
    public enum Action: Equatable, Sendable { case open, close, ignore }

    public static let reopenGuard: TimeInterval = 0.3

    public static func action(isShown: Bool, lastClosedAt: Date?, now: Date) -> Action {
        if isShown { return .close }
        if let lastClosedAt, now.timeIntervalSince(lastClosedAt) < reopenGuard { return .ignore }
        return .open
    }
}
