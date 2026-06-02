import SwiftUI
import AppKit
import ZMeetCore

struct SettingsView: View {
    @ObservedObject var state: AppState
    @State private var selection: Section = .general
    @State private var editingMode: RecordingMode = .remote
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var inputDevices: [AudioInputs.Device] = []
    @State private var reclaimable: Int64 = 0
    @State private var confirmFreeUp = false
    @State private var apiKeyInput = ""
    @State private var keyTestResult: KeyTestResult?
    @State private var testingKey = false
    @State private var obsidianVaults: [ObsidianVaults.Vault] = []

    /// Outcome of the "Test key" check. A typed result so the success styling
    /// isn't driven by comparing display strings.
    enum KeyTestResult: Equatable {
        case ok
        case failure(String)
        var label: String {
            switch self {
            case .ok: "Key works."
            case .failure(let message): message
            }
        }
        var isOK: Bool { self == .ok }
    }
    // Mint-terminal palette
    static let mint = Color(red: 0.180, green: 0.878, blue: 0.541)
    static let bg = Color(red: 0.051, green: 0.067, blue: 0.059)
    static let sidebarBG = Color(red: 0.078, green: 0.094, blue: 0.086)
    static let card = Color(red: 0.118, green: 0.141, blue: 0.125)
    static let hairline = Color.white.opacity(0.07)

    enum Section: String, CaseIterable, Identifiable {
        case general = "General"
        case summaries = "Summaries"
        case obsidian = "Obsidian"
        case recording = "Recording"
        case meetings = "Meetings"
        case storage = "Storage"
        case permissions = "Permissions"
        case about = "About"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .general: return "gearshape.fill"
            case .summaries: return "sparkles"
            case .obsidian: return "point.3.connected.trianglepath.dotted"
            case .recording: return "waveform"
            case .meetings: return "person.2.fill"
            case .storage: return "folder.fill"
            case .permissions: return "lock.shield.fill"
            case .about: return "info.circle.fill"
            }
        }
    }

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                sidebar
                Rectangle().fill(Self.hairline).frame(width: 1)
                content
            }
            // Floating dropdown menus, positioned at their trigger via anchor
            // preferences, above everything with a tap-catcher to dismiss.
            .overlayPreferenceValue(DropdownAnchorKey.self) { anchors in
                GeometryReader { proxy in
                    if let id = state.settingsMenu, let anchor = anchors[id] {
                        let rect = proxy[anchor]
                        let menuWidth: CGFloat = id == .obsidianVault ? 260 : (id == .microphone ? 230 : 160)
                        ZStack(alignment: .topLeading) {
                            Color.black.opacity(0.001)
                                .contentShape(Rectangle())
                                .onTapGesture { state.settingsMenu = nil }
                            dropdownMenu(for: id)
                                .frame(width: menuWidth)
                                .offset(x: min(max(8, rect.maxX - menuWidth), 720 - menuWidth - 8),
                                        y: rect.maxY + 4)
                        }
                    }
                }
            }

            if confirmFreeUp {
                DialogScaffold(onDismiss: { confirmFreeUp = false }) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Free up space?")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.primary)
                        Text("This deletes the recording for every processed meeting, keeping all transcripts and notes. This can't be undone.")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 10) {
                            Spacer()
                            DialogButton(title: "Cancel", kind: .secondary) { confirmFreeUp = false }
                            DialogButton(title: "Delete Audio", kind: .destructive) {
                                state.freeUpAllAudio()
                                reclaimable = state.reclaimableAudioBytes()
                                confirmFreeUp = false
                            }
                        }
                    }
                }
            }
        }
        .frame(width: 720, height: 500)
        .background(Self.bg)
        .preferredColorScheme(.dark)
        .tint(Self.mint)
        .onAppear { state.refreshPermissions() }
    }

    private static let retentionOptions: [(String, Int)] =
        [("Never", 0), ("7 days", 7), ("30 days", 30), ("90 days", 90)]
    private static let qualityOptions: [(String, Int)] =
        [("Standard", 128_000), ("High", 192_000), ("Maximum", 256_000)]
    static let gainOptions: [(String, Float)] = [
        ("Normal", 1.0),
        ("+6 dB", 2.0),
        ("+12 dB", 4.0),
    ]

    /// One selectable row in a dropdown: label, whether it's the current value,
    /// and the action to apply it.
    private struct MenuItem { let label: String; let selected: Bool; let select: () -> Void }

    private func menuItems(for id: AppState.SettingsMenuKind) -> [MenuItem] {
        switch id {
        case .retention:
            let cur = state.config.audioRetentionDays
            return Self.retentionOptions.map { opt in
                MenuItem(label: opt.0, selected: opt.1 == cur) {
                    state.updateConfig { $0.audioRetentionDays = opt.1 }; state.settingsMenu = nil
                }
            }
        case .quality:
            let cur = state.config.audio.bitrate
            return Self.qualityOptions.map { opt in
                MenuItem(label: opt.0, selected: opt.1 == cur) {
                    state.updateConfig { $0.audio.bitrate = opt.1 }; state.settingsMenu = nil
                }
            }
        case .captureMode:
            return Self.modeOptions.map { opt in
                MenuItem(label: opt.0, selected: opt.1 == editingMode) {
                    editingMode = opt.1; state.settingsMenu = nil
                }
            }
        case .microphone:
            let cur = state.config.profiles[editingMode].micDeviceID
            var items = [MenuItem(label: "System Default", selected: cur == nil) {
                state.updateConfig { $0.profiles[editingMode].micDeviceID = nil }; state.settingsMenu = nil
            }]
            for dev in inputDevices {
                items.append(MenuItem(label: dev.name, selected: cur == dev.id) {
                    state.updateConfig { $0.profiles[editingMode].micDeviceID = dev.id }; state.settingsMenu = nil
                })
            }
            return items
        case .micGain:
            let cur = state.config.profiles[editingMode].micGain
            return Self.gainOptions.map { opt in
                MenuItem(label: opt.0, selected: opt.1 == cur) {
                    state.updateConfig { $0.profiles[editingMode].micGain = opt.1 }; state.settingsMenu = nil
                }
            }
        case .obsidianVault:
            let cur = state.config.obsidianVaultPath
            var items = obsidianVaults.map { vault in
                MenuItem(label: vault.name, selected: vault.path == cur) {
                    state.updateConfig { $0.obsidianVaultPath = vault.path }; state.settingsMenu = nil
                }
            }
            items.append(MenuItem(label: "Choose manually…", selected: false) {
                state.chooseObsidianVault()
            })
            return items
        }
    }

    private func currentLabel(for id: AppState.SettingsMenuKind) -> String {
        if id == .obsidianVault {
            guard let p = state.config.obsidianVaultPath, !p.isEmpty else { return "Choose…" }
            return (p as NSString).lastPathComponent
        }
        return menuItems(for: id).first { $0.selected }?.label ?? "—"
    }

    /// The app-styled trigger button that opens a dropdown.
    private func dropdownTrigger(_ id: AppState.SettingsMenuKind) -> some View {
        Button { state.settingsMenu = (state.settingsMenu == id ? nil : id) } label: {
            HStack(spacing: 8) {
                Text(currentLabel(for: id)).font(.system(size: 13))
                    .lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 8)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .frame(width: (id == .microphone || id == .obsidianVault) ? 190 : 140)
            .background(Self.card, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Self.hairline, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .anchorPreference(key: DropdownAnchorKey.self, value: .bounds) { [id: $0] }
    }

    /// The floating dark menu list for a dropdown.
    private func dropdownMenu(for id: AppState.SettingsMenuKind) -> some View {
        let items = menuItems(for: id)
        return VStack(spacing: 0) {
            ForEach(items.indices, id: \.self) { i in
                DropdownMenuRow(label: items[i].label, selected: items[i].selected, action: items[i].select)
            }
        }
        .padding(.vertical, 5)
        .background(Color(red: 0.118, green: 0.137, blue: 0.129), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Self.hairline, lineWidth: 1))
        .shadow(color: .black.opacity(0.4), radius: 20, y: 10)
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
                case .summaries: summariesSection
                case .obsidian: obsidianSection
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

    private var summariesSection: some View {
        VStack(spacing: 14) {
            card {
                toggleRow("Use Claude for summaries (cloud)",
                          "Higher-quality notes via the Claude API. Falls back to on-device automatically if it can't run.",
                          boolBinding(\.useCloudSummaries))
            }
            if state.config.useCloudSummaries {
                card {
                    row("Anthropic API key",
                        state.hasAPIKey ? "A key is saved in your Keychain." : "Paste your Anthropic API key (stored in the Keychain).") {
                        EmptyView()
                    }
                    divider
                    HStack(spacing: 8) {
                        SecureField(state.hasAPIKey ? "•••• saved — paste to replace" : "sk-ant-…", text: $apiKeyInput)
                            .textFieldStyle(.roundedBorder)
                        Button("Save") {
                            state.saveAPIKey(apiKeyInput)
                            apiKeyInput = ""
                            keyTestResult = nil
                        }
                        .disabled(apiKeyInput.trimmingCharacters(in: .whitespaces).isEmpty)
                        Button("Clear") {
                            state.clearAPIKey()
                            apiKeyInput = ""
                            keyTestResult = nil
                        }
                        .disabled(!state.hasAPIKey)
                    }
                    .padding(.horizontal, 16).padding(.bottom, 12)
                    divider
                    row("Test key", "Send one request to verify the key works.") {
                        HStack(spacing: 8) {
                            if let keyTestResult {
                                Text(keyTestResult.label)
                                    .font(.caption)
                                    .foregroundStyle(keyTestResult.isOK ? Self.mint : .orange)
                            }
                            Button(testingKey ? "Testing…" : "Test") {
                                testingKey = true
                                keyTestResult = nil
                                Task {
                                    let err = await state.testAPIKey()
                                    keyTestResult = err.map(KeyTestResult.failure) ?? .ok
                                    testingKey = false
                                }
                            }
                            .disabled(testingKey || !state.hasAPIKey)
                        }
                    }
                }
                card {
                    row("Privacy", "When on, your transcript text and meeting title are sent to Anthropic to generate the summary. Your audio always stays on your Mac.") {
                        EmptyView()
                    }
                }
            }
        }
    }

    private var obsidianSection: some View {
        VStack(spacing: 14) {
            card {
                toggleRow("Publish notes to Obsidian",
                          "Write a linked copy of each meeting (notes + transcript) into an Obsidian vault, so your graph becomes a network of people, projects, and topics.",
                          boolBinding(\.publishToObsidian))
            }
            if state.config.publishToObsidian {
                card {
                    row("Vault", state.config.obsidianVaultPath.map(displayPath) ?? "No vault selected") {
                        dropdownTrigger(.obsidianVault)
                    }
                    divider
                    row("Backfill", "Publish all existing meetings into the vault. Reuses each meeting's saved transcript and notes.") {
                        if let progress = state.obsidianBackfill {
                            Text("Publishing \(progress.done) of \(progress.total)…")
                                .font(.system(size: 13)).foregroundStyle(.secondary)
                        } else {
                            Button("Publish all to vault") { state.publishAllToObsidian() }
                                .disabled(state.config.obsidianVaultPath?.isEmpty != false)
                        }
                    }
                }
            }
        }
        .onAppear { obsidianVaults = ObsidianVaults.detected() }
    }

    private var recordingSection: some View {
        card {
            row("Mode", "Settings below apply to this mode; pick a mode when you start recording.") {
                dropdownTrigger(.captureMode)
            }
            divider
            toggleRow("Capture system audio",
                      "Record the other participants (off for fully in-person meetings).",
                      profileBool(\.captureSystemAudio))
            divider
            row("Microphone", "Input device used to record.") {
                dropdownTrigger(.microphone)
            }
            divider
            row("Mic gain", "Boost a quiet microphone for in-person recordings. High levels can clip a loud mic.") {
                dropdownTrigger(.micGain)
            }
            divider
            toggleRow("Reduce background noise",
                      "Cleans up steady background noise (fans, hum) after each meeting.",
                      profileBool(\.noiseSuppression))
            divider
            row("Audio quality", "Higher quality means larger files. (Applies to all modes.)") {
                dropdownTrigger(.quality)
            }
            divider
            toggleRow("Label speakers (You vs Others)",
                      "Tags who spoke in remote/hybrid transcripts (your mic vs the other participants). Adds processing time.",
                      boolBinding(\.labelSpeakers))
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
                    dropdownTrigger(.retention)
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

    private func profileBool(_ kp: WritableKeyPath<CaptureProfile, Bool>) -> Binding<Bool> {
        Binding(get: { state.config.profiles[editingMode][keyPath: kp] },
                set: { v in state.updateConfig { $0.profiles[editingMode][keyPath: kp] = v } })
    }
    private static let modeOptions: [(String, RecordingMode)] = [
        ("Remote", .remote), ("Hybrid", .hybrid), ("In-person", .inPerson),
    ]

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

// MARK: - In-app dropdown plumbing

/// Carries each open-able trigger's on-screen bounds up to the body, so the
/// floating menu can be positioned right under it.
private struct DropdownAnchorKey: PreferenceKey {
    static let defaultValue: [AppState.SettingsMenuKind: Anchor<CGRect>] = [:]
    static func reduce(value: inout Value, nextValue: () -> Value) {
        value.merge(nextValue()) { _, new in new }
    }
}

private struct DropdownMenuRow: View {
    let label: String
    let selected: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(label)
                    .font(.system(size: 13))
                    .foregroundStyle(selected ? SettingsView.mint : Color.primary)
                Spacer(minLength: 8)
                if selected {
                    Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(SettingsView.mint)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(hover ? Color.white.opacity(0.06) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .padding(.horizontal, 5)
    }
}
