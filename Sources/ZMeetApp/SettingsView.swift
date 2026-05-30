import SwiftUI
import AppKit
import ZMeetCore

struct SettingsView: View {
    @ObservedObject var state: AppState
    @State private var selection: Section = .general
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var inputDevices: [AudioInputs.Device] = []
    @State private var reclaimable: Int64 = 0
    @State private var confirmFreeUp = false

    // Mint-terminal palette
    static let mint = Color(red: 0.180, green: 0.878, blue: 0.541)
    static let bg = Color(red: 0.051, green: 0.067, blue: 0.059)
    static let sidebarBG = Color(red: 0.078, green: 0.094, blue: 0.086)
    static let card = Color(red: 0.118, green: 0.141, blue: 0.125)
    static let hairline = Color.white.opacity(0.07)

    enum Section: String, CaseIterable, Identifiable {
        case general = "General"
        case recording = "Recording"
        case meetings = "Meetings"
        case storage = "Storage"
        case permissions = "Permissions"
        case about = "About"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .general: return "gearshape.fill"
            case .recording: return "waveform"
            case .meetings: return "person.2.fill"
            case .storage: return "folder.fill"
            case .permissions: return "lock.shield.fill"
            case .about: return "info.circle.fill"
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(Self.hairline).frame(width: 1)
            content
        }
        .frame(width: 720, height: 500)
        .background(Self.bg)
        .preferredColorScheme(.dark)
        .tint(Self.mint)
        .onAppear { state.refreshPermissions() }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 1) {
                Text(" z").font(.custom("Dancing Script", size: 26)).foregroundStyle(Self.mint)
                Text("Meet").font(.system(size: 20, weight: .bold))
            }
            .padding(.leading, 12)
            .padding(.top, 38)
            .padding(.bottom, 14)

            ForEach(Section.allCases) { section in
                sidebarItem(section)
            }

            Spacer()

            HStack(spacing: 16) {
                sidebarMiniButton("arrow.triangle.2.circlepath", "Check for Updates…") {
                    state.updater.checkForUpdates()
                }
                sidebarMiniButton("folder", "Open notes folder") { state.openOutputFolder() }
                Spacer()
                sidebarMiniButton("power", "Quit zMeet") { NSApplication.shared.terminate(nil) }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 16)
        }
        .frame(width: 196)
        .frame(maxHeight: .infinity)
        .background(Self.sidebarBG)
    }

    private func sidebarItem(_ section: Section) -> some View {
        let selected = selection == section
        return Button {
            selection = section
        } label: {
            HStack(spacing: 10) {
                Image(systemName: section.icon)
                    .frame(width: 18)
                    .foregroundStyle(selected ? Color(red: 0.05, green: 0.09, blue: 0.07) : .secondary)
                Text(section.rawValue)
                    .fontWeight(selected ? .semibold : .regular)
                    .foregroundStyle(selected ? Color(red: 0.05, green: 0.09, blue: 0.07) : .primary)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(selected ? Self.mint : .clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 10)
    }

    private func sidebarMiniButton(_ icon: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: Content

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(selection.rawValue)
                    .font(.title2).fontWeight(.semibold)
                    .padding(.top, 34)

                switch selection {
                case .general: generalSection
                case .recording: recordingSection
                case .meetings: meetingsSection
                case .storage: storageSection
                case .permissions: permissionsSection
                case .about: aboutSection
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 26)
            .padding(.bottom, 26)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Sections

    private var generalSection: some View {
        card {
            toggleRow("Launch zMeet at login",
                      "Start automatically when you log in.",
                      Binding(get: { launchAtLogin },
                              set: { launchAtLogin = $0; LaunchAtLogin.set($0) }))
            divider
            toggleRow("Process automatically after stopping",
                      "Transcribe and summarize as soon as you stop recording.",
                      boolBinding(\.autoProcessOnStop))
        }
    }

    private var recordingSection: some View {
        card {
            row("Microphone", "Input device used to record.") {
                Picker("", selection: Binding<String?>(
                    get: { state.config.audio.micDeviceID },
                    set: { state.setMicDevice($0) }
                )) {
                    Text("System Default").tag(String?.none)
                    ForEach(inputDevices) { dev in
                        Text(dev.name).tag(String?.some(dev.id))
                    }
                }
                .labelsHidden()
                .frame(width: 200)
            }
            divider
            row("Audio quality", "Higher quality means larger files.") {
                Picker("", selection: bitrateBinding) {
                    Text("Standard").tag(128_000)
                    Text("High").tag(192_000)
                    Text("Maximum").tag(256_000)
                }
                .labelsHidden()
                .frame(width: 130)
            }
        }
        .onAppear { inputDevices = AudioInputs.available() }
    }

    private var meetingsSection: some View {
        card {
            toggleRow("Detect Zoom & Teams meetings",
                      "Show a “Take notes” prompt when a meeting starts.",
                      boolBinding(\.detectMeetings))
        }
    }

    private var storageSection: some View {
        VStack(spacing: 14) {
            card {
                row("Notes folder", displayPath(state.config.outputPath)) {
                    HStack(spacing: 8) {
                        Button("Change…") { chooseOutputFolder() }
                        Button("Reveal") { state.openOutputFolder() }
                    }
                }
            }
            card {
                row("Delete audio after",
                    "Transcripts and notes are always kept.") {
                    Picker("", selection: retentionBinding) {
                        Text("Never").tag(0)
                        Text("7 days").tag(7)
                        Text("30 days").tag(30)
                        Text("90 days").tag(90)
                    }
                    .labelsHidden()
                    .frame(width: 130)
                }
                divider
                row("Recorded audio", "Free up space by deleting audio for processed meetings.") {
                    Button(reclaimable > 0 ? "Free up \(formattedBytes(reclaimable))" : "Nothing to free") {
                        confirmFreeUp = true
                    }
                    .disabled(reclaimable == 0)
                }
            }
        }
        .onAppear { reclaimable = state.reclaimableAudioBytes() }
        .alert("Free up space?", isPresented: $confirmFreeUp) {
            Button("Cancel", role: .cancel) {}
            Button("Delete Audio", role: .destructive) {
                state.freeUpAllAudio()
                reclaimable = state.reclaimableAudioBytes()
            }
        } message: {
            Text("This deletes the recording for every processed meeting, keeping all transcripts and notes. This can't be undone.")
        }
    }

    private var permissionsSection: some View {
        VStack(spacing: 14) {
            card {
                permissionRow("Microphone", granted: state.micGranted)
                divider
                permissionRow("Screen Recording", granted: state.screenGranted)
                divider
                permissionRow("Speech Recognition", granted: state.speechGranted)
            }
            Button { state.openOnboarding() } label: {
                Text("Open Setup…").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).tint(Self.mint)
        }
    }

    private var aboutSection: some View {
        card {
            row("Version", appVersion) { EmptyView() }
            divider
            row("Updates", "Check for a newer version.") {
                Button("Check Now") { state.updater.checkForUpdates() }
            }
            divider
            row("Configuration", "Edit the raw config file.") {
                Button("Open config") { state.openConfigFile() }
            }
        }
    }

    // MARK: Building blocks

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0) { content() }
            .background(Self.card, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Self.hairline, lineWidth: 1))
    }

    private var divider: some View {
        Rectangle().fill(Self.hairline).frame(height: 1).padding(.leading, 16)
    }

    private func row<Control: View>(_ title: String, _ subtitle: String?, @ViewBuilder control: () -> Control) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            control()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func toggleRow(_ title: String, _ subtitle: String, _ binding: Binding<Bool>) -> some View {
        row(title, subtitle) {
            Toggle("", isOn: binding).labelsHidden().toggleStyle(.switch).tint(Self.mint)
        }
    }

    private func permissionRow(_ title: String, granted: Bool) -> some View {
        row(title, nil) {
            Label(granted ? "Granted" : "Not granted",
                  systemImage: granted ? "checkmark.circle.fill" : "xmark.circle")
                .foregroundStyle(granted ? Self.mint : .orange)
                .labelStyle(.titleAndIcon)
                .font(.callout)
        }
    }

    // MARK: Bindings + helpers

    private func boolBinding(_ kp: WritableKeyPath<ZMeetConfig, Bool>) -> Binding<Bool> {
        Binding(get: { state.config[keyPath: kp] },
                set: { v in state.updateConfig { $0[keyPath: kp] = v } })
    }

    private var bitrateBinding: Binding<Int> {
        Binding(get: { state.config.audio.bitrate },
                set: { v in state.updateConfig { $0.audio.bitrate = v } })
    }

    private var retentionBinding: Binding<Int> {
        Binding(get: { state.config.audioRetentionDays },
                set: { v in state.updateConfig { $0.audioRetentionDays = v } })
    }

    private func formattedBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func chooseOutputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.directoryURL = URL(fileURLWithPath: ZMeetPaths.expandTilde(state.config.outputPath))
        if panel.runModal() == .OK, let url = panel.url {
            state.updateConfig { $0.outputPath = url.path }
        }
    }

    private func displayPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }
}
