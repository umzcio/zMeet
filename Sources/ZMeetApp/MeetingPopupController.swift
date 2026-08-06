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
        hide(animated: false)

        let view = MeetingPopupView(
            appName: meeting.app,
            onStart: { [weak self] in onStart(); self?.hide() },
            onDismiss: { [weak self] in onDismiss(); self?.hide() },
            onHover: { [weak self] hovering in
                guard let self else { return }
                if hovering {
                    self.autoDismiss?.invalidate()
                    self.autoDismiss = nil
                } else {
                    self.scheduleAutoDismiss()
                }
            }
        )

        let host = NSHostingView(rootView: view)
        let size = host.fittingSize
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
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
        panel.contentView = host

        if let origin = topRightOrigin(for: panel) {
            PanelAnimator.present(panel, at: origin)
        } else {
            panel.orderFrontRegardless()   // no screen info — show without motion
        }
        self.panel = panel

        // Auto-dismiss after 15s; the meeting can still be recorded from the menu.
        scheduleAutoDismiss()
    }

    private func scheduleAutoDismiss() {
        autoDismiss?.invalidate()
        autoDismiss = Timer.scheduledTimer(withTimeInterval: 15, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.hide() }
        }
    }

    func hide(animated: Bool = true) {
        autoDismiss?.invalidate()
        autoDismiss = nil
        guard let panel = self.panel else { return }
        self.panel = nil   // isVisible false immediately; re-entrant show() safe
        if animated {
            PanelAnimator.dismiss(panel) { }
        } else {
            PanelAnimator.dismissImmediately(panel)
        }
    }

    private func topRightOrigin(for panel: NSPanel) -> NSPoint? {
        guard let screen = NSScreen.main else { return nil }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        return NSPoint(
            x: visible.maxX - size.width - 16,
            y: visible.maxY - size.height - 8
        )
    }
}
