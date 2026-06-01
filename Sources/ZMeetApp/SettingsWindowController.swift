import AppKit
import SwiftUI

/// Shows the Settings window. The app stays a menu-bar agent (.accessory) — no
/// Dock icon — and the window is brought to the front via activation.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?

    func show(state: AppState) {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            return
        }

        let view = SettingsView(state: state)
        let window = EscClosableWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 500),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "zMeet Settings"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.center()
        window.onEsc = { [weak state] in
            guard let state, state.settingsMenu != nil else { return false }
            state.settingsMenu = nil
            return true
        }
        window.contentView = NSHostingView(rootView: view)
        window.isReleasedWhenClosed = false
        window.delegate = self
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        self.window = window
        AppActivation.windowOpened()
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        AppActivation.windowClosed()
    }
}
