import SwiftUI
import ZMeetCore

struct MenuContentView: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            switch state.phase {
            case .idle:
                idleControls
            case .recording(let since):
                recordingControls(since: since)
            case .processing:
                Label("Processing…", systemImage: "gearshape.2")
                    .foregroundStyle(.secondary)
            }

            if let error = state.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()
            recentList
            Divider()

            Button("Quit ZMeet") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
        .padding(12)
        .frame(width: 320)
    }

    private var header: some View {
        HStack {
            Image(systemName: state.isRecording ? "record.circle.fill" : "mic")
                .foregroundStyle(state.isRecording ? .red : .primary)
            Text("ZMeet").font(.headline)
            Spacer()
        }
    }

    private var idleControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Meeting title", text: $state.draftTitle)
                .textFieldStyle(.roundedBorder)
            Button {
                state.startRecording()
            } label: {
                Label("Start Recording", systemImage: "record.circle")
            }
        }
    }

    private func recordingControls(since: Date) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            TimelineView(.periodic(from: since, by: 1)) { _ in
                Label(elapsed(since: since), systemImage: "record.circle.fill")
                    .foregroundStyle(.red)
                    .monospacedDigit()
            }
            Button(role: .destructive) {
                state.stopRecording()
            } label: {
                Label("Stop", systemImage: "stop.circle")
            }
        }
    }

    private var recentList: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Recent").font(.caption).foregroundStyle(.secondary)
            if state.recent.isEmpty {
                Text("No meetings yet").font(.caption).foregroundStyle(.tertiary)
            } else {
                ForEach(state.recent, id: \.id) { session in
                    Button {
                        if session.notePath != nil { state.revealNote(session) }
                    } label: {
                        HStack {
                            Text(statusGlyph(session.status))
                            Text(session.title).lineLimit(1)
                            Spacer()
                            Text(session.status.rawValue)
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func elapsed(since: Date) -> String {
        let total = Int(Date().timeIntervalSince(since))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    private func statusGlyph(_ status: SessionStatus) -> String {
        switch status {
        case .recording: return "●"
        case .recorded:  return "■"
        case .processed: return "✓"
        case .failed:    return "⚠"
        }
    }
}
