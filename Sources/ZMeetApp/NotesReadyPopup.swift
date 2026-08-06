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
    let onHover: (Bool) -> Void

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
            .tint(kind == .success ? ZMeetPalette.mint : Color.orange)
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
            .buttonStyle(PressableStyle())
            .padding(7)
            .help("Dismiss")
            .accessibilityLabel("Dismiss")
        }
        .onHover(perform: onHover)
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
                    .foregroundStyle(ZMeetPalette.mint)
                    .scaleEffect(shown || reduceMotion ? 1.0 : 0.9)
                    .onAppear {
                        // Starts as the panel's own 0.22s entrance settles; gate the
                        // ANIMATION (not just the value) so reduce-motion never
                        // regains a spring if more properties join `shown`.
                        withAnimation(reduceMotion ? nil : .spring(duration: 0.35, bounce: 0.15).delay(0.2)) {
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
        hide(animated: false)

        let view = OutcomePopupView(
            kind: kind,
            title: title,
            onAction: { [weak self] in onAction(); self?.hide() },
            onDismiss: { [weak self] in self?.hide() },
            onHover: { [weak self] hovering in
                guard let self, kind == .success else { return }
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

        if let screen = NSScreen.main {
            let v = screen.visibleFrame
            let s = panel.frame.size
            let origin = NSPoint(x: v.maxX - s.width - 16, y: v.maxY - s.height - 8)
            PanelAnimator.present(panel, at: origin)
        } else {
            panel.orderFrontRegardless()   // no screen info — show without motion
        }
        self.panel = panel

        // A failure isn't acknowledged just by fading out — it stays until the
        // user dismisses it or acts on it. Only success auto-dismisses.
        if kind == .success {
            scheduleAutoDismiss()
        }
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
        self.panel = nil   // re-entrant show() safe
        if animated {
            PanelAnimator.dismiss(panel) { }
        } else {
            PanelAnimator.dismissImmediately(panel)
        }
    }
}
