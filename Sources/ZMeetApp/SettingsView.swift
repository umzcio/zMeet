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
    @State private var apiKeyInput = ""
    @State private var keyTestResult: KeyTestResult?
    @State private var testingKey = false
    /// Typed values, committed to config on Return, on picking from the list, before
    /// Test/Reload, on provider switch, and when the section disappears.
    @State private var modelInput = ""
    @State private var ollamaAddressInput = ""
    /// Model lists fetched this session, per provider.
    @State private var modelLists: [AIProvider: [String]] = [:]
    @State private var loadingModels = false
    @State private var modelListError: String?
    @State private var obsidianVaults: [ObsidianVaults.Vault] = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Outcome of Test connection. A typed result so the success styling isn't
    /// driven by comparing display strings.
    enum KeyTestResult: Equatable {
        case ok(String)
        case failure(String)
        var label: String {
            switch self {
            case .ok(let message), .failure(let message): message
            }
        }
        var isOK: Bool { if case .ok = self { true } else { false } }
    }
    // Mint-terminal palette. mint/bg/card now come from ZMeetPalette (Library's
    // canonical shades); Settings previously used slightly darker values here.
    /// The Settings window's content size; SettingsWindowController uses it too.
    /// Taller than the original 500pt so the AI section fits without crowding.
    static let windowSize = CGSize(width: 720, height: 580)
    static let sidebarBG = Color(red: 0.078, green: 0.094, blue: 0.086)
    static let hairline = Color.white.opacity(0.07)

    enum Section: String, CaseIterable, Identifiable {
        case general = "General"
        case ai = "AI"
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
            case .ai: return "sparkles"
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
                        let menuWidth: CGFloat = (id == .obsidianVault || id == .aiModel) ? 260 : (id == .microphone ? 230 : 160)
                        ZStack(alignment: .topLeading) {
                            Color.black.opacity(0.001)
                                .contentShape(Rectangle())
                                .onTapGesture { state.settingsMenu = nil }
                            dropdownMenu(for: id)
                                .frame(width: menuWidth)
                                .offset(x: min(max(8, rect.maxX - menuWidth), Self.windowSize.width - menuWidth - 8),
                                        y: rect.maxY + 4)
                                .transition(reduceMotion
                                    ? AnyTransition.opacity
                                    : .scale(scale: 0.97, anchor: .top).combined(with: .opacity))
                        }
                    }
                }
                .animation(ZMeetMotion.enter, value: state.settingsMenu)
            }

            if state.settingsConfirmFreeUp {
                DialogScaffold(onDismiss: { state.settingsConfirmFreeUp = false }) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Free up space?")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.primary)
                        Text("This moves the recording for every processed meeting to the Trash, keeping all transcripts and notes.")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 10) {
                            Spacer()
                            DialogButton(title: "Cancel", kind: .secondary) { state.settingsConfirmFreeUp = false }
                                .keyboardShortcut(.cancelAction)
                            // Return is deliberately unbound here: HIG makes the safe
                            // button the default in destructive dialogs, and SwiftUI
                            // can't give one button both roles — Esc→Cancel plus an
                            // unbound Return is the correct shape, not an omission.
                            DialogButton(title: "Delete Audio", kind: .destructive) {
                                state.freeUpAllAudio()
                                reclaimable = state.reclaimableAudioBytes()
                                state.settingsConfirmFreeUp = false
                            }
                        }
                    }
                }
            }
        }
        .frame(width: Self.windowSize.width, height: Self.windowSize.height)
        .background(ZMeetPalette.bg)
        .preferredColorScheme(.dark)
        .tint(ZMeetPalette.mint)
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
        case .aiProvider:
            return AIProvider.allCases.map { provider in
                MenuItem(label: provider.displayName, selected: provider == state.config.aiProvider) {
                    commitAIFields()
                    state.updateConfig { $0.aiProvider = provider }
                    apiKeyInput = ""
                    keyTestResult = nil
                    modelListError = nil
                    state.settingsMenu = nil
                }
            }
        case .aiModel:
            let list = modelLists[state.config.aiProvider] ?? []
            guard !list.isEmpty else {
                return [MenuItem(label: "No models loaded", selected: false) { state.settingsMenu = nil }]
            }
            let current = modelInput.trimmingCharacters(in: .whitespacesAndNewlines)
            return list.map { model in
                MenuItem(label: model, selected: model == current) {
                    modelInput = model
                    commitAIFields()
                    keyTestResult = nil
                    state.settingsMenu = nil
                }
            }
        }
    }

    private func currentLabel(for id: AppState.SettingsMenuKind) -> String {
        if id == .aiModel { return "" }   // icon-only trigger beside the model field
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
            .frame(width: id == .aiModel ? 44 : ((id == .microphone || id == .obsidianVault) ? 190 : 140))
            .background(ZMeetPalette.card, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Self.hairline, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel(id == .aiModel ? "Choose from the model list" : currentLabel(for: id))
        .anchorPreference(key: DropdownAnchorKey.self, value: .bounds) { [id: $0] }
    }

    /// The floating dark menu list for a dropdown.
    private func dropdownMenu(for id: AppState.SettingsMenuKind) -> some View {
        let items = menuItems(for: id)
        let list = VStack(spacing: 0) {
            ForEach(items.indices, id: \.self) { i in
                DropdownMenuRow(label: items[i].label, selected: items[i].selected, action: items[i].select)
            }
        }
        .padding(.vertical, 5)
        // Long lists (OpenAI's models) scroll instead of running off the window.
        return Group {
            if items.count > 8 {
                ScrollView { list }.frame(height: 280)
            } else {
                list
            }
        }
        .background(ZMeetPalette.field, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Self.hairline, lineWidth: 1))
        .shadow(color: .black.opacity(0.4), radius: 20, y: 10)
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 1) {
                Text(" z").font(.custom("Dancing Script", size: 26)).foregroundStyle(ZMeetPalette.mint)
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
            .background(selected ? ZMeetPalette.mint : .clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        // Rows/tabs don't depress (PressableStyle is for discrete controls) — hover carries the affordance.
        .buttonStyle(.plain)
        .padding(.horizontal, 10)
    }

    private func sidebarMiniButton(_ icon: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).foregroundStyle(.secondary)
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .help(help)
        .accessibilityLabel(help)
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
                case .ai: aiSection
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

    // MARK: AI provider

    private var aiProvider: AIProvider { state.config.aiProvider }

    private var aiSection: some View {
        VStack(spacing: 14) {
            card {
                row("Provider", "Which AI writes your notes, auto-titles, and Obsidian links.") {
                    dropdownTrigger(.aiProvider)
                }
            }
            if aiProvider != .onDevice {
                card {
                    if aiProvider == .ollama {
                        row("Server address", "This Mac, or another machine on your network.") {
                            TextField(AIProvider.defaultOllamaAddress, text: $ollamaAddressInput)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 230)
                                .onSubmit { commitAIFields(); refreshModels() }
                        }
                        divider
                    }
                    row(aiProvider == .ollama ? "API key (optional)" : "\(aiProvider.displayName) API key", keySubtitle) {
                        EmptyView()
                    }
                    HStack(spacing: 8) {
                        SecureField(keyPlaceholder, text: $apiKeyInput)
                            .textFieldStyle(.roundedBorder)
                        Button("Save") {
                            state.saveKey(apiKeyInput, for: aiProvider)
                            apiKeyInput = ""
                            keyTestResult = nil
                            refreshModels()
                        }
                        .disabled(apiKeyInput.trimmingCharacters(in: .whitespaces).isEmpty)
                        Button("Clear") {
                            state.clearKey(for: aiProvider)
                            apiKeyInput = ""
                            keyTestResult = nil
                        }
                        .disabled(!state.savedKeys.contains(aiProvider))
                    }
                    .padding(.horizontal, 16).padding(.bottom, 12)
                    divider
                    row("Model", modelSubtitle) {
                        HStack(spacing: 6) {
                            TextField(aiProvider == .ollama ? "llama3.1:8b" : "model name", text: $modelInput)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 180)
                                .onSubmit { commitAIFields() }
                            dropdownTrigger(.aiModel)
                            Button { refreshModels() } label: {
                                Group {
                                    if loadingModels {
                                        ProgressView().controlSize(.small)
                                    } else {
                                        Image(systemName: "arrow.clockwise").foregroundStyle(.secondary)
                                    }
                                }
                                .frame(width: 24, height: 24)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(PressableStyle())
                            .disabled(loadingModels)
                            .help("Reload the model list")
                            .accessibilityLabel("Reload the model list")
                        }
                    }
                    divider
                    row("Test connection", "Checks the address or key, and that the model exists. Generates nothing.") {
                        HStack(spacing: 8) {
                            if let keyTestResult {
                                Text(keyTestResult.label)
                                    .font(.caption)
                                    .foregroundStyle(keyTestResult.isOK ? ZMeetPalette.mint : .orange)
                                    .multilineTextAlignment(.trailing)
                                    .frame(maxWidth: 220, alignment: .trailing)
                            }
                            Button(testingKey ? "Testing…" : "Test") {
                                commitAIFields()
                                testingKey = true
                                keyTestResult = nil
                                Task {
                                    let result = await state.testAIConnection()
                                    keyTestResult = result.ok ? .ok(result.message) : .failure(result.message)
                                    testingKey = false
                                }
                            }
                            .disabled(testingKey)
                        }
                    }
                }
            }
            card {
                row("Privacy", AICopy.privacyNote(provider: aiProvider, ollamaAddress: state.config.ollamaAddress)) {
                    EmptyView()
                }
            }
        }
        // Runs on appear and on every provider switch: load that provider's saved
        // values, then its model list if one can be fetched and none is loaded yet.
        .task(id: aiProvider) {
            syncAIInputs()
            if modelLists[aiProvider] == nil, canListModels { refreshModels() }
        }
        .onDisappear { commitAIFields() }
    }

    private var keySubtitle: String {
        if state.savedKeys.contains(aiProvider) { return "A key is saved in your Keychain." }
        return aiProvider == .ollama
            ? "Only needed if your server requires one."
            : "Paste your \(aiProvider.displayName) API key (stored in the Keychain)."
    }

    private var keyPlaceholder: String {
        if state.savedKeys.contains(aiProvider) { return "•••• saved — paste to replace" }
        switch aiProvider {
        case .anthropic: return "sk-ant-…"
        case .openAI: return "sk-…"
        case .ollama, .onDevice: return "Optional"
        }
    }

    private var modelSubtitle: String {
        if let modelListError { return modelListError }
        if let list = modelLists[aiProvider], !list.isEmpty {
            return "\(list.count) available. You can also type any model name."
        }
        return "Type a model name, or reload the list."
    }

    /// Whether a model-list request can be made without more input.
    private var canListModels: Bool {
        switch aiProvider {
        case .onDevice: false
        case .ollama: OllamaAddress.normalized(state.config.ollamaAddress) != nil
        case .openAI, .anthropic: state.savedKeys.contains(aiProvider)
        }
    }

    /// Loads the selected provider's saved model and address into the fields.
    private func syncAIInputs() {
        modelInput = aiProvider == .onDevice ? "" : state.config.model(for: aiProvider)
        ollamaAddressInput = state.config.ollamaAddress
    }

    /// Saves the typed model (for the selected provider) and Ollama address.
    private func commitAIFields() {
        let provider = state.config.aiProvider
        let model = modelInput
        let address = ollamaAddressInput.trimmingCharacters(in: .whitespacesAndNewlines)
        state.updateConfig {
            if provider != .onDevice { $0.setModel(model, for: provider) }
            if !address.isEmpty { $0.ollamaAddress = address }
        }
    }

    private func refreshModels() {
        commitAIFields()
        let provider = state.config.aiProvider
        loadingModels = true
        modelListError = nil
        Task {
            let (models, error) = await state.fetchAIModels()
            loadingModels = false
            // The user may have switched providers while this ran; drop a stale result.
            guard state.config.aiProvider == provider else { return }
            if let error {
                modelListError = error
                return
            }
            modelLists[provider] = models
            if modelInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let first = models.first {
                modelInput = first
                commitAIFields()
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
                    row("Backfill", "Publish all existing meetings into the vault. Reuses each meeting's saved transcript and notes." + (AICopy.backfillWarning(provider: state.config.aiProvider, ollamaAddress: state.config.ollamaAddress) ?? "")) {
                        if let progress = state.obsidianBackfill {
                            Text("Publishing \(progress.done) of \(progress.total)…")
                                .font(.system(size: 13)).foregroundStyle(.secondary)
                                .contentTransition(reduceMotion ? .identity : .numericText())
                                .animation(ZMeetMotion.exit, value: progress.done)
                        } else {
                            VStack(alignment: .trailing, spacing: 4) {
                                Button("Publish all to vault") { state.publishAllToObsidian() }
                                    .disabled(state.config.obsidianVaultPath?.isEmpty != false)
                                if let message = state.obsidianBackfillMessage {
                                    Text(message).font(.caption).foregroundStyle(ZMeetPalette.mint)
                                        .multilineTextAlignment(.trailing)
                                }
                            }
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
                        state.settingsConfirmFreeUp = true
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
            .buttonStyle(.borderedProminent).tint(ZMeetPalette.mint)
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
            .background(ZMeetPalette.card, in: RoundedRectangle(cornerRadius: 12))
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
            Toggle("", isOn: binding).labelsHidden().toggleStyle(.switch).tint(ZMeetPalette.mint)
        }
    }

    private func permissionRow(_ title: String, granted: Bool) -> some View {
        row(title, nil) {
            Label(granted ? "Granted" : "Not granted",
                  systemImage: granted ? "checkmark.circle.fill" : "xmark.circle")
                .foregroundStyle(granted ? ZMeetPalette.mint : .orange)
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
                    .foregroundStyle(selected ? ZMeetPalette.mint : Color.primary)
                Spacer(minLength: 8)
                if selected {
                    Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(ZMeetPalette.mint)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(hover ? ZMeetPalette.hairline : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .onHover { hover = $0 }
        .padding(.horizontal, 5)
    }
}
