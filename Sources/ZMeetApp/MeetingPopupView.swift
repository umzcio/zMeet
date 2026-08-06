import SwiftUI

/// The Zoom-style "meeting detected" banner shown in the floating panel.
struct MeetingPopupView: View {
    let appName: String
    let onStart: () -> Void
    let onDismiss: () -> Void
    let onHover: (Bool) -> Void

    var body: some View {
        HStack(spacing: 12) {
            // The detected app's real icon (Zoom/Teams), matching the Recent list.
            Image(nsImage: SourceAppIcons.icon(for: appName))
                .resizable()
                .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text("\(appName) meeting detected")
                    .font(.headline)
                Text("Record notes with zMeet?")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Button(action: onStart) {
                Text("Take notes")
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
        }
        .padding(14)
        .padding(.leading, 8)  // room for the close button
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
