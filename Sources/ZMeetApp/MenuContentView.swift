import SwiftUI
import ZMeetCore

struct MenuContentView: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            primarySection
                .padding(.horizontal, 14)
                .padding(.vertical, 12)

            if let error = state.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
            }

            if state.phase == .idle, !(state.micGranted && state.screenGranted) {
                Divider()
                permissionHint
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
            }

            Divider()
            recentSection
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

            Divider()
            toolbar
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
        }
        .frame(width: 300)
        .onAppear { state.refreshPermissions() }
    }

    // MARK: Header — app icon + name, status on the right (OneDrive-style)

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "waveform.circle.fill")
                .font(.title2)
                .foregroundStyle(state.isRecording ? .red : .accentColor)
            Text("zMeet").font(.headline)
            Spacer()
            Text(statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var statusText: String {
        switch state.phase {
        case .idle:        return "Ready"
        case .recording:   return "Recording"
        case .processing:  return "Processing…"
        }
    }

    // MARK: Primary action — Start (idle) / timer + Stop (recording)

    @ViewBuilder
    private var primarySection: some View {
        switch state.phase {
        case .idle:
            VStack(alignment: .leading, spacing: 8) {
                TextField("Meeting title", text: $state.draftTitle)
                    .textFieldStyle(.roundedBorder)
                Button {
                    state.startRecording()
                } label: {
                    Label("Start Recording", systemImage: "record.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }

        case .recording(let since):
            VStack(alignment: .leading, spacing: 10) {
                TimelineView(.periodic(from: since, by: 1)) { _ in
                    HStack(spacing: 8) {
                        Circle().fill(.red).frame(width: 9, height: 9)
                        Text("Recording")
                        Spacer()
                        Text(elapsed(since: since)).monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .font(.subheadline)
                }
                Button(role: .destructive) {
                    state.stopRecording()
                } label: {
                    Label("Stop", systemImage: "stop.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }

        case .processing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Processing…").foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Permission hint — only shown when something is missing

    private var permissionHint: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.shield.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text("Permissions needed").font(.caption).fontWeight(.medium)
                Text("Microphone & Screen Recording")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Grant") { state.grantPermissions() }
                .font(.caption)
        }
    }

    // MARK: Recent — short, tidy list with a chevron affordance

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("RECENT")
                .font(.caption2).fontWeight(.semibold)
                .foregroundStyle(.tertiary)

            if state.recent.isEmpty {
                Text("No meetings yet")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(state.recent.prefix(3), id: \.id) { session in
                    RecentRow(session: session) { state.revealNote(session) }
                }
            }
        }
    }

    // MARK: Toolbar — compact icon buttons (open notes / settings / quit)

    private var toolbar: some View {
        HStack(spacing: 18) {
            ToolbarIcon(systemName: "folder", help: "Open notes folder") {
                state.openNotesFolder()
            }
            ToolbarIcon(systemName: "gearshape", help: "Edit configuration") {
                state.openConfigFile()
            }
            Spacer()
            ToolbarIcon(systemName: "power", help: "Quit zMeet") {
                NSApplication.shared.terminate(nil)
            }
        }
    }

    private func elapsed(since: Date) -> String {
        let total = Int(Date().timeIntervalSince(since))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

private struct RecentRow: View {
    let session: MeetingSession
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: glyph)
                    .foregroundStyle(tint)
                    .font(.caption)
                Text(session.title).lineLimit(1)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var glyph: String {
        switch session.status {
        case .recording: return "record.circle"
        case .recorded:  return "stop.circle"
        case .processed: return "checkmark.circle.fill"
        case .failed:    return "exclamationmark.triangle.fill"
        }
    }

    private var tint: Color {
        switch session.status {
        case .processed: return .green
        case .failed:    return .orange
        default:         return .secondary
        }
    }
}

private struct ToolbarIcon: View {
    let systemName: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.body)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
