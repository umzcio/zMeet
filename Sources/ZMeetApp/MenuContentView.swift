import SwiftUI
import AppKit
import ZMeetCore

struct MenuContentView: View {
    @ObservedObject var state: AppState

    /// Closes the MenuBarExtra popover. The window-style popover doesn't dismiss
    /// itself when we bring another window forward, so close it explicitly.
    private func dismissMenuBar() {
        for window in NSApp.windows where "\(type(of: window))".contains("MenuBarExtra") {
            window.close()
        }
    }

    private func openLibrary(select id: String? = nil) {
        dismissMenuBar()
        state.openLibrary(select: id)
    }

    private func openSettings() {
        dismissMenuBar()
        state.openSettings()
    }

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
            openAppRow
                .padding(.horizontal, 10)
                .padding(.vertical, 8)

            Divider()
            toolbar
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
        }
        .frame(width: 300)
        .onAppear { state.refreshPermissions() }
    }

    // MARK: Header — app icon + name, status on the right (OneDrive-style)

    /// Brand mint (#2EE08A).
    private static let mint = Color(red: 0.180, green: 0.878, blue: 0.541)

    private var header: some View {
        HStack(spacing: 8) {
            // Wordmark: cursive z (Dancing Script) + mono "Meet".
            // Baseline-aligned, with extra bottom room for the z's descender tail.
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                // Leading space insets the glyph inside its own text box so the
                // cursive z's entry swash isn't clipped at the frame's left edge.
                Text(" z")
                    .font(.custom("Dancing Script", size: 23))
                    .foregroundStyle(Self.mint)
                Text("Meet")
                    .font(.headline)
            }
            .padding(.bottom, 5)
            Spacer()
            Text(statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.top, 11)
        .padding(.bottom, 12)
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
                    state.requestManualStart()
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
            Button("Set up") { dismissMenuBar(); state.openOnboarding() }
                .font(.caption)
        }
    }

    // MARK: Open the app — single row into the Library (the meeting browser)

    private var openAppRow: some View {
        Button { openLibrary() } label: {
            HStack(spacing: 10) {
                Image(systemName: "rectangle.stack")
                    .font(.body)
                    .foregroundStyle(Self.mint)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Open zMeet").fontWeight(.medium)
                    Text(meetingCountText)
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var meetingCountText: String {
        switch state.allSessions.count {
        case 0:  return "No meetings yet"
        case 1:  return "1 meeting"
        case let n: return "\(n) meetings"
        }
    }

    // MARK: Toolbar — compact icon buttons (open notes / settings / quit)

    private var toolbar: some View {
        HStack(spacing: 18) {
            ToolbarIcon(systemName: "gearshape", help: "Settings") {
                openSettings()
            }
            ToolbarIcon(systemName: "folder", help: "Open zMeet folder") {
                state.openOutputFolder()
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
