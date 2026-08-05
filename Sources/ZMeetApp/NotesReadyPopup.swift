import AppKit
import SwiftUI

/// Outcome banner shown after processing finishes — either "Notes ready" (success)
/// or "Couldn't create notes" (failure). Same floating-panel style as the
/// meeting-detected popup.
struct OutcomePopupView: View {
    enum Kind {
        case success
        case failure
    }

    let kind: Kind
    let title: String
    let onAction: () -> Void
    let onDismiss: () -> Void

    static let mint = Color(red: 0.180, green: 0.878, blue: 0.541)

    var body: some View {
        HStack(spacing: 12) {
            OutcomePopupIcon(kind: kind)

            VStack(alignment: .leading, spacing: 2) {
                Text(kind == .success ? "Notes ready" : "Couldn't create notes")
                    .font(.headline)
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Button(action: onAction) {
                Text(kind == .success ? "View notes" : "Open in Library")
            }
            .buttonStyle(.borderedProminent)
            .tint(kind == .success ? Self.mint : Color.orange)
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

private struct OutcomePopupIcon: View {
    let kind: OutcomePopupView.Kind
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            switch kind {
            case .success:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(OutcomePopupView.mint)
                    .scaleEffect(shown || reduceMotion ? 1.0 : 0.5)
                    .onAppear {
                        withAnimation(.spring(duration: 0.45, bounce: 0.35).delay(0.1)) {
                            shown = true
                        }
                    }
            case .failure:
                // A failure isn't a delight moment — no celebratory spring pop,
                // just the warning rendered at full size.
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color.orange)
            }
        }
        .font(.largeTitle)
    }
}

@MainActor
final class NotesReadyPopupController {
    private var panel: NSPanel?
    private var autoDismiss: Timer?

    func show(kind: OutcomePopupView.Kind = .success, title: String, onAction: @escaping () -> Void) {
        hide()

        let view = OutcomePopupView(
            kind: kind,
            title: title,
            onAction: { [weak self] in onAction(); self?.hide() },
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
