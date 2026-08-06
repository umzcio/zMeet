import SwiftUI

struct OnboardingView: View {
    @ObservedObject var state: AppState
    let onFinish: () -> Void

    /// Polls permission state so the rows update live as the user grants access
    /// (especially Screen Recording, which is toggled in System Settings).
    private let poll = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.4)

            VStack(spacing: 14) {
                permissionRow(
                    icon: "mic.fill",
                    title: "Microphone",
                    detail: "Record your voice during meetings.",
                    granted: state.micGranted,
                    action: state.grantMicrophone
                )
                permissionRow(
                    icon: "macwindow",
                    title: "Screen Recording",
                    detail: "Capture the other participants' audio. macOS may ask you to enable zMeet in Settings and relaunch.",
                    granted: state.screenGranted,
                    action: state.grantScreenRecording
                )
                permissionRow(
                    icon: "waveform",
                    title: "Speech Recognition",
                    detail: "Transcribe recordings on-device. Nothing is uploaded.",
                    granted: state.speechGranted,
                    action: state.grantSpeech
                )
            }
            .padding(20)

            Spacer(minLength: 0)
            footer
        }
        .frame(width: 460, height: 540)
        .background(Color(red: 0.051, green: 0.067, blue: 0.059))
        .onAppear { state.refreshPermissions() }
        // Live poll while the user is looking at System Settings — the moment a
        // permission flips is the one high-emotion beat in onboarding, so the
        // checkmark/border swap crossfades instead of teleporting. Opacity/color
        // only, reduce-motion-safe by construction.
        .onReceive(poll) { _ in withAnimation(ZMeetMotion.enter) { state.refreshPermissions() } }
    }

    private var header: some View {
        VStack(spacing: 10) {
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 46))
                .foregroundStyle(ZMeetPalette.mint)
                .padding(.top, 8)
            HStack(spacing: 0) {
                Text(" z").font(.custom("Dancing Script", size: 34)).foregroundStyle(ZMeetPalette.mint)
                Text("Meet").font(.system(size: 30, weight: .bold))
            }
            Text("Private, on-device meeting notes.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("zMeet needs a few permissions to record and transcribe your meetings. Everything stays on your Mac.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 36)
                .padding(.bottom, 6)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
    }

    private func permissionRow(icon: String, title: String, detail: String, granted: Bool, action: @escaping () -> Void) -> some View {
        HStack(alignment: .center, spacing: 13) {
            Image(systemName: icon)
                .font(.title3)
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(granted ? ZMeetPalette.mint : .secondary)
                .frame(width: 28, height: 28, alignment: .center)

            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            if granted {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(ZMeetPalette.mint)
            } else {
                Button("Grant", action: action)
                    .buttonStyle(.borderedProminent)
                    .tint(ZMeetPalette.mint)
                    .controlSize(.small)
            }
        }
        .padding(14)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(granted ? ZMeetPalette.mint.opacity(0.4) : Color.white.opacity(0.06), lineWidth: 1)
        )
    }

    private var footer: some View {
        VStack(spacing: 10) {
            Divider().opacity(0.4)
            HStack {
                if !state.allPermissionsGranted {
                    Text("You can grant the rest later from the menu.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Button(state.allPermissionsGranted ? "Get Started" : "Continue") {
                    onFinish()
                }
                .buttonStyle(.borderedProminent)
                .tint(ZMeetPalette.mint)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
    }
}
