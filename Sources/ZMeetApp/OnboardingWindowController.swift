import AppKit
import SwiftUI

/// Shows the first-run setup window. The app is a menu-bar agent (LSUIElement),
/// so we create and activate a standard window programmatically.
@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    static let didCompleteKey = "zmeet.onboarding.completed"

    private var window: NSWindow?

    /// Show onboarding if it hasn't been completed, or if any required
    /// permission is still missing.
    func showIfNeeded(state: AppState) {
        state.refreshPermissions()
        let completed = UserDefaults.standard.bool(forKey: Self.didCompleteKey)
        if completed && state.allPermissionsGranted { return }
        show(state: state)
    }

    func show(state: AppState) {
        // A menu-bar (.accessory) app can't bring a titled window to the front;
        // become a regular app while onboarding is open, then revert on close.
        NSApp.setActivationPolicy(.regular)

        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = OnboardingView(state: state, onFinish: { [weak self] in
            UserDefaults.standard.set(true, forKey: Self.didCompleteKey)
            self?.close()
        })

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 540),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.center()
        window.contentView = NSHostingView(rootView: view)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }

    func close() {
        window?.close()  // triggers windowWillClose -> cleanup
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        // Revert to a menu-bar–only agent (no Dock icon) once setup is dismissed.
        NSApp.setActivationPolicy(.accessory)
    }
}
