import SwiftUI

/// The Zoom-style "meeting detected" banner shown in the floating panel.
struct MeetingPopupView: View {
    let appName: String
    let onStart: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "waveform.circle.fill")
                .font(.largeTitle)
                .foregroundStyle(.red)

            VStack(alignment: .leading, spacing: 2) {
                Text("\(appName) meeting detected")
                    .font(.headline)
                Text("Record notes with zMeet?")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            VStack(spacing: 6) {
                Button(action: onStart) {
                    Text("Take notes").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)

                Button("Dismiss", action: onDismiss)
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 96)
        }
        .padding(14)
        .frame(width: 360)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}
