import AppKit
import SwiftUI
import ZMeetCore

/// Asked after a manual "Start Recording": is this a remote/hybrid meeting or an
/// in-person one? (Detected Zoom/Teams meetings skip this — they're remote.)
// A dimming scrim behind the panel is deliberately NOT added: this is a
// nonactivating NSPanel, and a scrim would require a second full-screen
// panel behind it. The content-scale appear below is the materialization
// cue instead.
struct ModeChoiceView: View {
    let onChoose: (RecordingMode) -> Void
    let onCancel: () -> Void

    static let bg = Color(red: 0.051, green: 0.067, blue: 0.059)
    static let card = Color(red: 0.118, green: 0.141, blue: 0.125)

    @State private var appeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 16) {
            VStack(spacing: 4) {
                Text("How are you meeting?").font(.headline)
                Text("Pick how zMeet should capture this recording.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.top, 22)

            HStack(spacing: 14) {
                choiceCard(
                    mode: .remote,
                    icon: "wifi",
                    title: "Remote",
                    detail: "You're at your desk. Capture the other participants (system audio) and your microphone."
                )
                choiceCard(
                    mode: .hybrid,
                    icon: "person.2.wave.2.fill",
                    title: "Hybrid",
                    detail: "You're in a room with remote participants. Capture system audio and the room mic."
                )
                choiceCard(
                    mode: .inPerson,
                    icon: "person.2.fill",
                    title: "In-person",
                    detail: "Everyone's in the room. Capture the room through the microphone only."
                )
            }
            .padding(.horizontal, 22)

            Button("Cancel", action: onCancel)
                .buttonStyle(PressableStyle())
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.bottom, 18)
        }
        .frame(width: 680)
        .background(Self.bg)
        .preferredColorScheme(.dark)
        .scaleEffect(appeared ? 1 : 0.97)
        .onAppear {
            withAnimation(reduceMotion ? nil : ZMeetMotion.enter) { appeared = true }
        }
    }

    private func choiceCard(mode: RecordingMode, icon: String, title: String, detail: String) -> some View {
        Button {
            onChoose(mode)
        } label: {
            VStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 30))
                    .foregroundStyle(ZMeetPalette.mint)
                    .frame(height: 34)
                Text(title).font(.headline)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: 150)
            .padding(.horizontal, 12)
            .background(Self.card, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(0.08), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(ModeCardButtonStyle())
    }
}

/// Subtle press/hover feedback for the choice cards.
private struct ModeCardButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .overlay(RoundedRectangle(cornerRadius: 14)
                .stroke(ZMeetPalette.mint, lineWidth: configuration.isPressed ? 2 : 0))
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.9 : 1)
            .animation(ZMeetMotion.press, value: configuration.isPressed)
    }
}

@MainActor
final class ModeChoicePopupController {
    private var panel: NSPanel?

    func show(onChoose: @escaping (RecordingMode) -> Void) {
        hide()
        let view = ModeChoiceView(
            onChoose: { [weak self] mode in self?.hide(); onChoose(mode) },
            onCancel: { [weak self] in self?.hide() }
        )
        let host = NSHostingView(rootView: view)
        let size = host.fittingSize

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.nonactivatingPanel, .titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.contentView = host
        panel.center()
        PanelAnimator.present(panel, at: panel.frame.origin, slide: 0, duration: 0.18)
        NSApp.activate(ignoringOtherApps: true)
        self.panel = panel
    }

    func hide() {
        guard let panel = self.panel else { return }
        self.panel = nil   // re-entrant show() safe
        PanelAnimator.dismiss(panel, slide: 0, duration: 0.15) { }
    }
}
