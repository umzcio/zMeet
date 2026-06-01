import AppKit

/// Coordinates the app's activation policy so it shows a Dock icon (and is
/// ⌘-Tab-able) only while a real window is open, then returns to a menu-bar-only
/// accessory once the last window closes.
@MainActor
enum AppActivation {
    private static var windowCount = 0

    /// Call when a real window (Library/Settings/Onboarding) is first shown.
    static func windowOpened() {
        if windowCount == 0 {
            NSApp.setActivationPolicy(.regular)
        }
        windowCount += 1
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Call from the window's `windowWillClose`.
    static func windowClosed() {
        windowCount = max(0, windowCount - 1)
        if windowCount == 0 {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
