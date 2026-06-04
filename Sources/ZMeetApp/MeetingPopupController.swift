import AppKit
import SwiftUI

/// Shows/hides a floating, non-activating panel near the top-right of the screen
/// hosting the meeting-detected banner. Works from a menu-bar (accessory) app.
@MainActor
final class MeetingPopupController {
    private var panel: NSPanel?
    private var autoDismiss: Timer?

    /// Whether the prompt is currently on screen (so callers don't stack a second one).
    var isVisible: Bool { panel != nil }

    func show(meeting: DetectedMeeting, onStart: @escaping () -> Void, onDismiss: @escaping () -> Void) {
        hide()

        let view = MeetingPopupView(
            appName: meeting.app,
            onStart: { [weak self] in onStart(); self?.hide() },
            onDismiss: { [weak self] in onDismiss(); self?.hide() }
        )

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 92),
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: view)

        positionTopRight(panel)
        panel.orderFrontRegardless()
        self.panel = panel

        // Auto-dismiss after 15s; the meeting can still be recorded from the menu.
        autoDismiss = Timer.scheduledTimer(withTimeInterval: 15, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.hide() }
        }
    }

    func hide() {
        autoDismiss?.invalidate()
        autoDismiss = nil
        panel?.orderOut(nil)
        panel = nil
    }

    private func positionTopRight(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        let origin = NSPoint(
            x: visible.maxX - size.width - 16,
            y: visible.maxY - size.height - 8
        )
        panel.setFrameOrigin(origin)
    }
}
