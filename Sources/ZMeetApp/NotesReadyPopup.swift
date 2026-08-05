import AppKit
import SwiftUI

/// "Meeting notes are ready" banner, shown after processing completes. Same
/// floating-panel style as the meeting-detected popup.
struct NotesReadyPopupView: View {
    let title: String
    let onView: () -> Void
    let onDismiss: () -> Void

    static let mint = Color(red: 0.180, green: 0.878, blue: 0.541)

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.largeTitle)
                .foregroundStyle(Self.mint)

            VStack(alignment: .leading, spacing: 2) {
                Text("Notes ready")
                    .font(.headline)
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Button(action: onView) {
                Text("View notes")
            }
            .buttonStyle(.borderedProminent)
            .tint(Self.mint)
        }
        .padding(14)
        .padding(.leading, 8)
        .frame(width: 360)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(alignment: .topLeading) {
            Button(action: onDismiss) {
                Image(systemName: "xmark.circle.fill")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .padding(7)
            .help("Dismiss")
        }
    }
}

@MainActor
final class NotesReadyPopupController {
    private var panel: NSPanel?
    private var autoDismiss: Timer?

    func show(title: String, onView: @escaping () -> Void) {
        hide()

        let view = NotesReadyPopupView(
            title: title,
            onView: { [weak self] in onView(); self?.hide() },
            onDismiss: { [weak self] in self?.hide() }
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

        if let screen = NSScreen.main {
            let v = screen.visibleFrame
            let s = panel.frame.size
            let origin = NSPoint(x: v.maxX - s.width - 16, y: v.maxY - s.height - 8)
            PanelAnimator.present(panel, at: origin)
        } else {
            panel.orderFrontRegardless()   // no screen info — show without motion
        }
        self.panel = panel

        autoDismiss = Timer.scheduledTimer(withTimeInterval: 15, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.hide() }
        }
    }

    func hide() {
        autoDismiss?.invalidate()
        autoDismiss = nil
        guard let panel = self.panel else { return }
        self.panel = nil   // re-entrant show() safe
        PanelAnimator.dismiss(panel) { }
    }
}
