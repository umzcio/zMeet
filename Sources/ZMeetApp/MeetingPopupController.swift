import AppKit
import SwiftUI

/// Shows/hides a floating, non-activating panel near the top-right of the screen
/// hosting the meeting-detected banner. Works from a menu-bar (accessory) app.
@MainActor
final class MeetingPopupController {
    private var panel: NSPanel?

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
    }

    func hide() {
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
