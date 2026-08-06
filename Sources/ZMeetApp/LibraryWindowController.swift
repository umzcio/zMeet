import AppKit
import SwiftUI

/// Shows the Library / Reader window — the conversation-rail view of past
/// meetings. The app stays a menu-bar agent (.accessory) — no Dock icon — and the
/// window is brought to the front via activation.
@MainActor
final class LibraryWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?

    func show(state: AppState) {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            return
        }

        let view = LibraryView(state: state)
        let window = EscClosableWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "zMeet"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.center()
        // Esc dismisses an open in-app dialog or menu first; only closes the
        // window when none is showing.
        window.onEsc = { [weak state] in
            guard let state else { return false }
            if state.libraryDialog != nil { state.libraryDialog = nil; return true }
            if state.showLibraryActions || state.libraryContextSession != nil {
                state.showLibraryActions = false
                state.libraryContextSession = nil
                return true
            }
            if !state.libraryQuery.isEmpty { state.libraryQuery = ""; return true }
            return false
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
