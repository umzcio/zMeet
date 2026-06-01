import Foundation
import SwiftUI
import AVFoundation
import ZMeetCore

@MainActor
final class AppState: ObservableObject {
    enum Phase: Equatable {
        case idle
        case recording(since: Date)
        case processing
    }

    @Published private(set) var phase: Phase = .idle
    /// The meeting currently being (re)processed, if any. Drives the Library's
    /// per-meeting processing spinner and triggers a reader refresh on completion.
    @Published private(set) var processingSessionID: String?
    /// Whether an Anthropic API key is stored in the Keychain. Kept in sync on
    /// save/clear so the Settings UI observes it without a per-render Keychain read.
    @Published private(set) var hasAPIKey: Bool = false
    @Published private(set) var recent: [MeetingSession] = []
    /// Every meeting, newest first — backs the Library window.
    @Published private(set) var allSessions: [MeetingSession] = []
    /// Currently-selected meeting in the Library window (nil = newest).
    @Published var librarySelectedID: String?
    /// Which in-app dialog (if any) is open in the Library window. Held here so the
    /// window can intercept Esc and dismiss the dialog instead of closing.
    @Published var libraryDialog: LibraryDialog?

    enum LibraryDialog: Equatable { case rename, delete, deleteAudio }
    @Published var showLibraryActions = false
    @Published var libraryContextSession: MeetingSession?
    @Published var settingsMenu: SettingsMenuKind?

    enum SettingsMenuKind: Hashable { case retention, quality, microphone, micGain, captureMode }
    @Published var draftTitle: String = ""
    @Published private(set) var lastError: String?
    @Published private(set) var micGranted: Bool = false
    @Published private(set) var screenGranted: Bool = false
    @Published private(set) var speechGranted: Bool = false

    private let store = ConfigStore()
    private let secretStore: SecretStore = KeychainSecretStore()
    private let recorder: MeetingRecorder
    @Published private(set) var config: ZMeetConfig
    private var manager: SessionManager
    private let detector = MeetingDetector()
    private let meetingPopup = MeetingPopupController()
    private let notesReadyPopup = NotesReadyPopupController()
    private let modeChoicePopup = ModeChoicePopupController()
    private let onboarding = OnboardingWindowController()
    private let settingsWindow = SettingsWindowController()
    private let libraryWindow = LibraryWindowController()
    let updater = UpdaterController()
    private var dismissedMeetingKeys: Set<String> = []
    /// True when the current recording was started from a detected meeting, so it
    /// can be auto-stopped when that meeting ends.
    private var recordingFromDetection = false

    init(recorder: MeetingRecorder = StubRecorder()) {
        // Load config, or bootstrap a fresh one if missing/old-schema.
        let loaded: ZMeetConfig
        if let existing = try? store.load() {
            loaded = existing
        } else {
            loaded = (try? store.bootstrap()) ?? ZMeetConfig.default()
        }
        self.recorder = recorder
        self.config = loaded
        self.manager = SessionManager(config: loaded, recorder: recorder)

        // Finalize any session interrupted by a previous crash/quit.
        _ = try? manager.recoverInterruptedSessions()
        reloadRecent()
        manager.purgeExpiredAudio()
        refreshHasAPIKey()
        refreshPermissions()
        if config.detectMeetings { startMeetingDetection() }

        // Show first-run setup (or whenever a required permission is missing).
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.onboarding.showIfNeeded(state: self)
        }
    }

    /// Re-open the setup window on demand (from the menu's permission hint).
    func openOnboarding() {
        onboarding.show(state: self)
    }

    func openSettings() {
        settingsWindow.show(state: self)
    }

    /// Open the Library/Reader window, optionally selecting a specific meeting.
    func openLibrary(select id: String? = nil) {
        reloadRecent()
        if let id { librarySelectedID = id }
        libraryWindow.show(state: self)
        Task { await reconcileSearchIndex() }
    }

    /// Rename a meeting's display title, then refresh the lists.
    func renameMeeting(id: String, to newTitle: String) {
        _ = try? manager.setTitle(id: id, to: newTitle)
        reloadRecent()
    }

    /// Delete a meeting (folder + record), then refresh the lists.
    func deleteMeeting(id: String) {
        try? manager.delete(id: id)
        reloadRecent()
    }

    /// Manually purge a single meeting's audio (keeps transcript + notes).
    func deleteAudio(id: String) {
        try? manager.deleteAudio(id: id)
        reloadRecent()
    }

    /// Purge audio for ALL processed meetings (the Settings "Free up space now").
    func freeUpAllAudio() {
        for session in allSessions where session.status == .processed {
            try? manager.deleteAudio(id: session.id)
        }
        reloadRecent()
    }

    /// Bytes of audio reclaimable right now (processed meetings).
    func reclaimableAudioBytes() -> Int64 {
        manager.reclaimableAudioBytes()
    }

    /// Reads a meeting's note file for the reader. File IO is small and local.
    func readNote(_ session: MeetingSession) -> String? {
        guard let path = session.notePath,
              let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        return text
    }

    func readTranscript(_ session: MeetingSession) -> String? {
        guard let path = session.transcriptPath,
              let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        return text
    }

    /// Full-text search over processed meetings. Runs off the main thread; results
    /// are returned on the main actor.
    func searchMeetings(_ query: String) async -> [SearchHit] {
        guard let store = manager.searchStore else { return [] }
        let q = query
        return await Task.detached(priority: .userInitiated) {
            store.search(q, limit: 50)
        }.value
    }

    /// Backfill/clean the search index from the meeting files. Cheap after the
    /// first run (already-indexed meetings are skipped). File IO + indexing run off
    /// the main thread. Notes files are reduced to their title-free body so the
    /// index matches what fresh processing stores.
    func reconcileSearchIndex() async {
        guard let store = manager.searchStore else { return }
        let docs = manager.searchIndexDocuments()
        await Task.detached(priority: .utility) {
            store.reconcile(documents: docs) { path in
                guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
                return path.hasSuffix("notes.md") ? ZMeetText.noteSearchBody(text) : text
            }
        }.value
    }

    /// Mutate + persist config, then apply side-effects (recorder uses the new
    /// config; meeting detection turns on/off).
    func updateConfig(_ mutate: (inout ZMeetConfig) -> Void) {
        let oldAppData = config.appDataPath
        let oldOutput = config.outputPath
        mutate(&config)
        try? store.write(config)
        if config.appDataPath != oldAppData || config.outputPath != oldOutput {
            // Storage layout / search DB location changed — rebuild the manager.
            manager = SessionManager(config: config, recorder: recorder)
        } else {
            manager.updateConfig(config)
        }
        if config.detectMeetings {
            startMeetingDetection()
        } else {
            detector.stop()
            meetingPopup.hide()
        }
    }

    // MARK: Cloud-summary API key (Keychain-backed)

    /// Mirrors whether a key is in the Keychain, kept in sync on save/clear so the
    /// Settings UI observes it (and doesn't hit the Keychain on every render).
    private func refreshHasAPIKey() {
        hasAPIKey = (secretStore.read(account: SecretAccount.anthropicAPIKey)?.isEmpty == false)
    }

    func saveAPIKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try? secretStore.write(trimmed, account: SecretAccount.anthropicAPIKey)
        refreshHasAPIKey()
    }

    func clearAPIKey() {
        try? secretStore.delete(account: SecretAccount.anthropicAPIKey)
        refreshHasAPIKey()
    }

    /// Verifies the stored key against the zero-cost `GET /v1/models` endpoint.
    /// Returns nil on success or a short error message on failure. Used by the
    /// Settings "Test key" button.
    func testAPIKey() async -> String? {
        guard let key = secretStore.read(account: SecretAccount.anthropicAPIKey), !key.isEmpty else {
            return "No API key saved."
        }
        do {
            try await CloudSummarizer(apiKey: key).validateKey()
            return nil
        } catch let CloudSummaryError.http(status) {
            return status == 401 ? "Key rejected (401)." : "Request failed (HTTP \(status))."
        } catch CloudSummaryError.network {
            return "Network error — check your connection."
        } catch {
            return "Test failed: \(error.localizedDescription)"
        }
    }

    private func startMeetingDetection() {
        detector.onChange = { [weak self] meeting in
            guard let self else { return }
            guard let meeting else {
                // Meeting ended: hide the popup and allow future meetings to prompt again.
                self.meetingPopup.hide()
                self.dismissedMeetingKeys.removeAll()
                // Auto-stop a recording that was started from this detected meeting.
                if self.isRecording, self.recordingFromDetection {
                    self.stopRecording()
                }
                return
            }
            // Don't prompt while already recording, or for a meeting already dismissed.
            guard !self.isRecording, !self.dismissedMeetingKeys.contains(meeting.key) else { return }
            self.meetingPopup.show(
                meeting: meeting,
                onStart: {
                    self.draftTitle = meeting.title
                    // Detected meetings are remote — no need to ask.
                    self.startRecording(mode: .remote, sourceApp: meeting.app)
                },
                onDismiss: {
                    self.dismissedMeetingKeys.insert(meeting.key)
                }
            )
        }
        detector.start()
    }

    var isRecording: Bool {
        if case .recording = phase { return true }
        return false
    }

    /// Manual start: ask remote vs in-person first, then record.
    func requestManualStart() {
        modeChoicePopup.show { [weak self] mode in
            self?.startRecording(mode: mode, sourceApp: nil)
        }
    }

    func startRecording(mode: RecordingMode, sourceApp: String? = nil) {
        lastError = nil
        meetingPopup.hide()
        Task {
            let ok = await requestPermissions()
            guard ok else {
                lastError = "Microphone and Screen Recording permission are required. Grant them in System Settings → Privacy & Security, then try again."
                Permissions.openScreenRecordingSettings()
                return
            }
            // Permissions confirmed — apply the chosen mode's capture profile to
            // the live config (system audio, mic device, gain, noise suppression)
            // and persist it.
            updateConfig {
                let p = $0.profiles[mode]
                $0.recordingMode = mode
                $0.audio.captureSystemAudio = p.captureSystemAudio
                $0.audio.micDeviceID = p.micDeviceID
                $0.audio.micGain = p.micGain
                $0.noiseSuppression = p.noiseSuppression
                $0.audio.separateTracks = ($0.labelSpeakers && p.captureSystemAudio)
            }
            do {
                _ = try manager.start(title: draftTitle, sourceApp: sourceApp, mode: mode)
                phase = .recording(since: Date())
                recordingFromDetection = (sourceApp != nil)
                draftTitle = ""
                reloadRecent()
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    func refreshPermissions() {
        micGranted = Permissions.microphoneAuthorized()
        screenGranted = Permissions.hasScreenRecording()
        speechGranted = Permissions.speechAuthorized()
    }

    /// All permissions zMeet needs to record + process are granted.
    var allPermissionsGranted: Bool {
        micGranted && screenGranted && speechGranted
    }

    // MARK: Per-permission grant actions (used by the first-run setup window)

    func grantMicrophone() {
        if Permissions.micNeedsSettings() {
            Permissions.openMicrophoneSettings()
            return
        }
        Task { _ = await Permissions.ensureMicrophone(); refreshPermissions() }
    }

    func grantSpeech() {
        if Permissions.speechNeedsSettings() {
            Permissions.openSpeechSettings()
            return
        }
        Task { _ = await Permissions.ensureSpeech(); refreshPermissions() }
    }

    func grantScreenRecording() {
        // First request shows the prompt; once decided, macOS requires a manual
        // toggle in Settings + relaunch, so always also open the pane.
        Permissions.requestScreenRecording()
        Permissions.openScreenRecordingSettings()
        refreshPermissions()
    }

    /// Request both permissions; returns true only if both end up granted.
    func requestPermissions() async -> Bool {
        let mic = await Permissions.ensureMicrophone()
        if !Permissions.hasScreenRecording() {
            Permissions.requestScreenRecording()
        }
        refreshPermissions()
        return mic && Permissions.hasScreenRecording()
    }

    func grantPermissions() {
        Task { _ = await requestPermissions() }
    }

    func stopRecording() {
        // Ignore a stop when we're not recording. Because the actual stop now
        // runs asynchronously, leaving `.recording` set here would let a second
        // Stop click — or the detector's auto-stop firing concurrently — spawn a
        // duplicate `manager.stop()` that finds no active session and surfaces a
        // spurious error. Flipping phase synchronously closes that window.
        guard isRecording else { return }
        lastError = nil
        recordingFromDetection = false
        phase = .processing
        Task {
            do {
                let stopped = try await manager.stop()
                // Best-effort offline noise cleanup (in place). A failure keeps the
                // original recording and must never block notes or surface an error.
                if config.noiseSuppression {
                    do {
                        try await AudioCleanup().clean(fileURL: URL(fileURLWithPath: stopped.audioPath))
                    } catch {
                        print("AudioCleanup failed, keeping original: \(error)")
                    }
                }
                reloadRecent()
                if config.autoProcessOnStop {
                    process(id: stopped.id)
                } else {
                    phase = .idle
                }
            } catch {
                phase = .idle
                lastError = error.localizedDescription
                reloadRecent()
            }
        }
    }

    func process(id: String) {
        lastError = nil
        phase = .processing
        // Track the specific meeting so the Library can show a per-row/reader
        // spinner and refresh the open note when this finishes — re-processing an
        // already-`.processed` meeting doesn't change its status, so the Library
        // can't detect completion from status alone.
        processingSessionID = id
        Task {
            do {
                // The async Apple speech/LLM work runs off the main actor; the
                // synchronous Core write happens back on the main actor.
                let session = try manager.session(id: id)
                let audioURL = URL(fileURLWithPath: session.audioPath)
                let (transcript, summary, engine) = try await produceNotes(audioURL: audioURL, title: session.title)
                let processed = try manager.applyProcessedText(id: id, transcript: transcript, summary: summary, engine: engine)
                notesReadyPopup.show(title: processed.title) { [weak self] in
                    self?.revealNote(processed)
                }
                manager.purgeExpiredAudio()
            } catch {
                lastError = error.localizedDescription
            }
            phase = .idle
            processingSessionID = nil
            reloadRecent()
        }
    }

    @available(macOS 26, *)
    private func transcribeForNotes(audioURL: URL) async throws -> String {
        let folder = audioURL.deletingLastPathComponent()
        let micURL = folder.appendingPathComponent("mic.m4a")
        let systemURL = folder.appendingPathComponent("system.m4a")
        let fm = FileManager.default
        guard fm.fileExists(atPath: micURL.path), fm.fileExists(atPath: systemURL.path) else {
            return try await SpeechTranscription().transcribe(audioURL: audioURL)
        }
        // Diarize: transcribe each side (sequential — one shared speech model),
        // interleave, then drop the transient tracks. A corrupt/unfinalized track
        // (e.g. from a killed recording) must not block notes — drop the tracks and
        // fall back to the mixed recording.
        do {
            let you = try await SpeechTranscription().transcribeSegments(audioURL: micURL)
            let others = try await SpeechTranscription().transcribeSegments(audioURL: systemURL)
            let labeled = Diarizer().merge(you: you, others: others)
            try? fm.removeItem(at: micURL)
            try? fm.removeItem(at: systemURL)
            if !labeled.isEmpty { return labeled }
        } catch {
            try? fm.removeItem(at: micURL)
            try? fm.removeItem(at: systemURL)
        }
        return try await SpeechTranscription().transcribe(audioURL: audioURL)
    }

    private func produceNotes(audioURL: URL, title: String) async throws -> (transcript: String, summary: String, engine: SummaryEngine) {
        if #available(macOS 26, *) {
            let transcript = try await transcribeForNotes(audioURL: audioURL)
            let onDevice = MeetingSummarizer()
            var cloud: (any Summarizer)?
            if config.useCloudSummaries,
               let key = secretStore.read(account: SecretAccount.anthropicAPIKey),
               !key.isEmpty {
                cloud = CloudSummarizer(apiKey: key)
            }
            let (summary, engine) = try await SummarizationPolicy().summarize(
                transcript: transcript,
                title: title,
                useCloud: config.useCloudSummaries,
                onDevice: onDevice,
                cloud: cloud
            )
            return (transcript, summary, engine)
        } else {
            throw NSError(
                domain: "zMeet", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "On-device transcription requires macOS 26 or newer."]
            )
        }
    }

    func revealNote(_ session: MeetingSession) {
        guard let path = session.notePath else { return }
        NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
    }

    func openOutputFolder() {
        let path = ZMeetPaths.expandTilde(config.outputPath)
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    func openConfigFile() {
        NSWorkspace.shared.open(store.configURL)
    }

    private func reloadRecent() {
        let sessions = (try? manager.listSessions()) ?? []
        allSessions = sessions
        recent = Array(sessions.prefix(10))
    }
}
