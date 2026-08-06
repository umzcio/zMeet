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
                .frame(minHeight: 64, alignment: .top)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .animation(ZMeetMotion.exit, value: state.phase)

            VStack(spacing: 0) {
                if state.phase == .idle, state.isProcessing {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(processingStatusText).font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
                    .transition(.opacity)
                }
            }
            // Moved out of the `if` (was on the HStack, where it can't see the
            // row's own insertion/removal) so the transition actually animates
            // instead of popping — see plan 056.
            .animation(ZMeetMotion.exit, value: state.isProcessing)

            if let notice = state.notice {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: icon(for: notice.kind))
                        .font(.caption)
                        .foregroundStyle(color(for: notice.kind))
                    Text(notice.message)
                        .font(.caption)
                        .foregroundStyle(notice.kind == .error ? .red : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Button { state.dismissNotice() } label: {
                        Image(systemName: "xmark.circle.fill").font(.caption).foregroundStyle(.tertiary)
                    }
                    .buttonStyle(PressableStyle())
                    .accessibilityLabel("Dismiss notice")
                }
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
            OpenAppRow(subtitle: meetingCountText) { openLibrary() }
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

    private var header: some View {
        HStack(spacing: 8) {
            // Wordmark: cursive z (Dancing Script) + mono "Meet".
            // Baseline-aligned, with extra bottom room for the z's descender tail.
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                // Leading space insets the glyph inside its own text box so the
                // cursive z's entry swash isn't clipped at the frame's left edge.
                Text(" z")
                    .font(.custom("Dancing Script", size: 23))
                    .foregroundStyle(ZMeetPalette.mint)
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

    /// The processing status row's text: the single meeting's stage when only
    /// one is processing, else a count — per-meeting stage text would be
    /// ambiguous with more than one in flight.
    private var processingStatusText: String {
        let stages = state.processingStages
        if stages.count > 1 { return "Processing \(stages.count) meetings…" }
        return stages.values.first ?? "Processing…"
    }

    private var statusText: String {
        if state.isRecording { return "Recording" }
        if state.isProcessing { return "Processing…" }
        return "Ready"
    }

    // MARK: Primary action — Start (idle) / timer + Stop (recording)

    @ViewBuilder
    private var primarySection: some View {
        switch state.phase {
        case .recording(let since):
            // Recording always wins the primary slot, even while a different
            // meeting is being (re)processed in the background — the Stop button
            // must never disappear behind a "Processing…" row.
            VStack(alignment: .leading, spacing: 10) {
                TimelineView(.periodic(from: since, by: 1)) { _ in
                    HStack(spacing: 8) {
                        RecordingDot()
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
            .transition(.opacity)

        case .idle:
            // Always shows the title field + Start, even while a background
            // (re)process is running — a background job must never take away
            // the ability to start recording. See the status row in `body`.
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
            .transition(.opacity)
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

    // MARK: Notice presentation — icon + color by feedback kind

    private func icon(for kind: AppState.UserNotice.Kind) -> String {
        switch kind {
        case .info: return "info.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "exclamationmark.octagon.fill"
        }
    }

    private func color(for kind: AppState.UserNotice.Kind) -> Color {
        switch kind {
        case .info: return .secondary
        case .warning: return .orange
        case .error: return .red
        }
    }
}

private struct RecordingDot: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        Group {
            if reduceMotion {
                Circle().fill(.red)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { tl in
                    // 1.2s sine pulse between 0.65 and 1.0 opacity — a pulse,
                    // not a breath. TimelineView pauses off-screen, so nothing
                    // animates behind a closed menu.
                    let t = tl.date.timeIntervalSinceReferenceDate
                    let phase = (sin(t * 2 * .pi / 1.2) + 1) / 2
                    Circle().fill(.red).opacity(0.65 + 0.35 * phase)
                }
            }
        }
        .frame(width: 9, height: 9)
        .accessibilityHidden(true)
    }
}

private struct ToolbarIcon: View {
    let systemName: String
    let help: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.body)
                .foregroundStyle(hover ? Color.primary : Color.secondary)
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .onHover { hover = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

// MARK: Open the app — single row into the Library (the meeting browser)

private struct OpenAppRow: View {
    let subtitle: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "rectangle.stack")
                    .font(.body)
                    .foregroundStyle(ZMeetPalette.mint)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Open zMeet").fontWeight(.medium)
                    Text(subtitle)
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(hover ? ZMeetPalette.hairline : .clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .onHover { hover = $0 }
    }
}
