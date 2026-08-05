import Foundation
import SwiftUI
import AppKit
import AVFoundation
import ZMeetCore

@MainActor
final class AppState: ObservableObject {
    // Recording and processing are concurrently valid (a background re-process
    // can run while a new meeting is being recorded), so `.processing` was removed
    // from `Phase` — `isProcessing` (derived from `processingSessionID`) is the
    // sole processing signal now.
    enum Phase: Equatable {
        case idle
        case recording(since: Date)
    }

    @Published private(set) var phase: Phase = .idle
    /// The meeting currently being (re)processed, if any. Drives the Library's
    /// per-meeting processing spinner and triggers a reader refresh on completion.
    @Published private(set) var processingSessionID: String?
    /// Meeting ids whose process+publish lifecycle is still running. Guards against a
    /// second process(id:) for the same meeting — the Obsidian publish continues
    /// after the UI returns to idle, so processingSessionID alone can't gate it.
    private var inFlightSessionIDs: Set<String> = []
    /// Progress of a "publish all to Obsidian" backfill, while one is running (nil
    /// otherwise). Drives the Settings button label + disabled state.
    @Published private(set) var obsidianBackfill: BackfillProgress?
    struct BackfillProgress: Equatable { var done: Int; var total: Int }
    /// Outcome of the most recent backfill (e.g. "All 5 meetings are already in the
    /// vault."), shown in Settings until the next run. nil = no run this session.
    @Published private(set) var obsidianBackfillMessage: String?
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

    enum SettingsMenuKind: Hashable { case retention, quality, microphone, micGain, captureMode, obsidianVault }
    @Published var draftTitle: String = ""
    @Published private(set) var lastError: String?
    @Published private(set) var micGranted: Bool = false
    @Published private(set) var screenGranted: Bool = false
    @Published private(set) var speechGranted: Bool = false

    private let store = ConfigStore()
    private let secretStore: SecretStore = KeychainSecretStore()
    private var recorder: MeetingRecorder
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

    init(recorder: MeetingRecorder) {
        // Load config; a corrupt file is backed up (never clobbered) and replaced
        // with defaults, and the user is told below via lastError.
        let loaded: ZMeetConfig
        var configRecoveryNote: String?
        switch store.loadOrBackupAndBootstrap() {
        case .loaded(let cfg):
            loaded = cfg
        case .bootstrapped(let cfg, let backup):
            loaded = cfg
            if let backup {
                configRecoveryNote = "Your settings file couldn't be read and was reset to defaults. The old file was saved as \(backup.lastPathComponent) in ~/.zmeet."
            }
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
        if let configRecoveryNote { lastError = configRecoveryNote }
        if config.detectMeetings { startMeetingDetection() }

        // Report a capture failure that happens after `start()` returned (async
        // stream setup failure, stream died mid-recording): surface it to the
        // user and mark the in-flight session `.failed` instead of leaving it
        // to look like a normal (silent) recording.
        self.recorder.onCaptureFailure = { [weak self] message in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.lastError = message
                if case .recording = self.phase,
                   let active = self.allSessions.first(where: { $0.status == .recording }) {
                    _ = try? await self.manager.stop()
                    _ = try? self.manager.markFailed(id: active.id, message: message)
                    self.phase = .idle
                    self.reloadRecent()
                }
            }
        }

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
        guard let renamed = try? manager.setTitle(id: id, to: newTitle) else { return }
        reloadRecent()
        // If this meeting was published to Obsidian, re-publish under the new name so
        // the vault note is renamed and the old one is cleaned up — best-effort,
        // background, using the transcript + summary already on disk.
        guard config.publishToObsidian, renamed.status == .processed else { return }
        Task {
            if let notes = onDiskNotes(for: renamed) {
                await publishToObsidianIfEnabled(session: renamed, transcript: notes.transcript, summary: notes.summary)
            }
        }
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
                // Meeting window gone: hide the popup and allow future meetings to
                // prompt again. Auto-stop is NOT driven by windows anymore — a Teams
                // lobby looks like "no window" yet the meeting hasn't ended. The
                // recording is stopped by audio activity (onAudioMeetingEnded) instead.
                self.meetingPopup.hide()
                self.dismissedMeetingKeys.removeAll()
                return
            }
            // Don't prompt while already recording, or for a meeting already dismissed.
            guard !self.isRecording, !self.dismissedMeetingKeys.contains(meeting.key) else { return }
            self.promptToTakeNotes(meeting)
        }
        // Audio actually started (you're in the call) — prompt even if the window
        // detector missed it. Once-per-meeting, so it won't nag.
        detector.onAudioMeetingStarted = { [weak self] app in
            guard let self else { return }
            guard !self.isRecording, !self.meetingPopup.isVisible else { return }
            self.promptToTakeNotes(DetectedMeeting(app: app, title: "\(app) Meeting"))
        }
        // Audio ended after a meeting was actually under way — auto-stop a recording
        // that was started from detection. This is the reliable stop signal.
        detector.onAudioMeetingEnded = { [weak self] in
            guard let self else { return }
            if self.isRecording, self.recordingFromDetection {
                self.stopRecording()
            }
        }
        detector.start()
    }

    /// Show the "Take notes" prompt for a detected meeting.
    private func promptToTakeNotes(_ meeting: DetectedMeeting) {
        meetingPopup.show(
            meeting: meeting,
            onStart: { [weak self] in
                guard let self else { return }
                self.draftTitle = meeting.title
                // Detected meetings are remote — no need to ask.
                self.startRecording(mode: .remote, sourceApp: meeting.app)
            },
            onDismiss: { [weak self] in
                self?.dismissedMeetingKeys.insert(meeting.key)
            }
        )
    }

    var isRecording: Bool {
        if case .recording = phase { return true }
        return false
    }

    /// True while any meeting's process+publish lifecycle is running — independent
    /// of `phase`, so a background re-process never masks a concurrent recording.
    var isProcessing: Bool { processingSessionID != nil }

    var iconState: MenuBarIcon.State {
        if case .recording = phase { return .recording }
        if isProcessing { return .processing }
        return .idle
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
        // Return to idle immediately — processing (if any) is now tracked entirely
        // via `processingSessionID`/`isProcessing`, independent of `phase`, so a
        // concurrent background re-process of another meeting is never clobbered.
        phase = .idle
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
                }
            } catch {
                lastError = error.localizedDescription
                reloadRecent()
            }
        }
    }

    func process(id: String) {
        // Ignore a duplicate (re)process for a meeting whose process+publish is still
        // running — the publish continues after the UI returns to idle, so without
        // this two runs could race on the same notes + vault files.
        guard !inFlightSessionIDs.contains(id) else { return }
        inFlightSessionIDs.insert(id)
        lastError = nil
        // Track the specific meeting so the Library can show a per-row/reader
        // spinner and refresh the open note when this finishes — re-processing an
        // already-`.processed` meeting doesn't change its status, so the Library
        // can't detect completion from status alone.
        processingSessionID = id
        Task {
            // Carries the inputs for the background Obsidian publish, set only on success.
            var toPublish: (session: MeetingSession, transcript: String, summary: String)?
            do {
                // The async Apple speech/LLM work runs off the main actor; the
                // synchronous Core write happens back on the main actor.
                let session = try manager.session(id: id)
                let (transcript, summary, engine) = try await produceNotes(session: session)
                if engine == .onDeviceAfterCloudFailure {
                    lastError = "Cloud summary failed — this meeting's notes were generated on-device. Check your API key in Settings."
                }
                // Give untitled meetings (in-person / manual) a descriptive title from
                // their notes, before the note is written + published so it carries
                // through. Best-effort; never overwrites a real/user-set title. You can
                // still rename afterward (Library → Rename), which republishes cleanly.
                if Self.needsAutoTitle(session.title) {
                    let generated = await TitleGenerator(
                        useCloud: config.useCloudSummaries,
                        apiKey: secretStore.read(account: SecretAccount.anthropicAPIKey)
                    ).title(summary: summary)
                    if let generated, !generated.isEmpty {
                        _ = try? manager.setTitle(id: id, to: generated)
                    }
                }
                let processed = try manager.applyProcessedText(id: id, transcript: transcript, summary: summary, engine: engine)
                notesReadyPopup.show(title: processed.title) { [weak self] in
                    self?.revealNote(processed)
                }
                manager.purgeExpiredAudio()
                toPublish = (processed, transcript, summary)
            } catch {
                lastError = error.localizedDescription
                let failedTitle = (try? manager.session(id: id))?.title ?? "Meeting"
                notesReadyPopup.show(kind: .failure, title: failedTitle) { [weak self] in
                    self?.openLibrary(select: id)
                }
            }
            // Free the UI as soon as the notes are saved + shown.
            processingSessionID = nil
            reloadRecent()
            // Obsidian publish is a best-effort background step that runs AFTER the
            // UI is freed, so a slow entity-extraction call can't pin the icon in
            // .processing or delay the "notes ready" popup.
            if let toPublish {
                await publishToObsidianIfEnabled(session: toPublish.session, transcript: toPublish.transcript, summary: toPublish.summary)
            }
            inFlightSessionIDs.remove(id)
        }
    }

    /// Whether a meeting should get an auto-generated title: only when it has no real
    /// one (blank or the "Untitled Meeting" placeholder), so a user-set or detected
    /// title is never overwritten.
    private static func needsAutoTitle(_ title: String) -> Bool {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty || t == "Untitled Meeting"
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

    private func produceNotes(session: MeetingSession) async throws -> (transcript: String, summary: String, engine: SummaryEngine) {
        if #available(macOS 26, *) {
            let transcript = try await transcript(for: session)
            let onDevice = MeetingSummarizer()
            var cloud: (any Summarizer)?
            if config.useCloudSummaries,
               let key = secretStore.read(account: SecretAccount.anthropicAPIKey),
               !key.isEmpty {
                cloud = CloudSummarizer(apiKey: key)
            }
            let (summary, engine) = try await SummarizationPolicy().summarize(
                transcript: transcript,
                title: session.title,
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

    /// The transcript for a (re)process: transcribe the audio when it's present,
    /// otherwise fall back to the transcript already on disk. The fallback lets a
    /// meeting whose audio was purged (retention / free-up) still be re-processed —
    /// e.g. to back-fill it into Obsidian after enabling that feature.
    @available(macOS 26, *)
    private func transcript(for session: MeetingSession) async throws -> String {
        let audioURL = URL(fileURLWithPath: session.audioPath)
        if FileManager.default.fileExists(atPath: audioURL.path) {
            return try await transcribeForNotes(audioURL: audioURL)
        }
        if let path = session.transcriptPath,
           FileManager.default.fileExists(atPath: path),
           let existing = try? String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8),
           !existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return existing
        }
        throw NSError(
            domain: "zMeet", code: 2,
            userInfo: [NSLocalizedDescriptionKey: "The audio for this meeting is no longer available, so it can't be re-processed."]
        )
    }

    /// Publishes a linked copy of the meeting (main note + companion transcript) into
    /// the configured Obsidian vault. Best-effort: gated on the opt-in flag + an
    /// existing vault folder; any failure is logged and never blocks notes or surfaces
    /// as a user error. Re-processing overwrites the same two files; if the meeting was
    /// renamed since its last publish, the previously-published pair is removed first
    /// so the vault doesn't accumulate stale duplicates.
    private func publishToObsidianIfEnabled(session: MeetingSession, transcript: String, summary: String) async {
        guard config.publishToObsidian,
              let rawPath = config.obsidianVaultPath, !rawPath.isEmpty else { return }
        let vault = URL(fileURLWithPath: ZMeetPaths.expandTilde(rawPath))
        guard FileManager.default.fileExists(atPath: vault.path) else {
            print("zMeet: Obsidian vault not found at \(vault.path); skipping publish.")
            return
        }
        let entities = await EntityExtractor(
            useCloud: config.useCloudSummaries,
            apiKey: secretStore.read(account: SecretAccount.anthropicAPIKey)
        ).extract(summary: summary, transcript: transcript)
        let names = ObsidianVaultFiles.names(for: session)
        // Remove a stale prior pair so the vault doesn't keep an orphaned note:
        if let previous = session.obsidianBaseName {
            // …published before under a now-different name (the meeting was renamed).
            if previous != names.mainNoteName {
                ObsidianVaultFiles.remove(baseName: previous, from: vault)
            }
        } else {
            // …or first publish since upgrading from v1.12.0, which named files
            // date-only (no time). Remove that legacy pair if it differs.
            let legacy = ObsidianVaultFiles.legacyBaseName(for: session)
            if legacy != names.mainNoteName {
                ObsidianVaultFiles.remove(baseName: legacy, from: vault)
            }
        }
        let main = ObsidianNoteRenderer.mainNote(
            session: session, summary: summary, entities: entities,
            transcriptNoteName: names.transcriptNoteName)
        let tx = ObsidianNoteRenderer.transcriptNote(
            session: session, transcript: transcript, mainNoteName: names.mainNoteName)
        do {
            try ObsidianVaultFiles.write(
                main: main, transcript: tx,
                mainName: names.main, transcriptName: names.transcript, into: vault)
            // Remember what we published so a future rename can clean up this pair.
            try? manager.setObsidianBaseName(id: session.id, to: names.mainNoteName)
        } catch {
            print("zMeet: Obsidian publish failed: \(error.localizedDescription)")
        }
    }

    /// Backfills every already-processed meeting into the Obsidian vault, reusing the
    /// transcript + summary already on disk (no re-transcribing / re-summarizing) and
    /// adding the graph links. Best-effort and idempotent; meetings with no readable
    /// transcript/notes are skipped. Drives `obsidianBackfill` for the Settings UI.
    func publishAllToObsidian() {
        guard config.publishToObsidian,
              let rawPath = config.obsidianVaultPath, !rawPath.isEmpty,
              FileManager.default.fileExists(atPath: ZMeetPaths.expandTilde(rawPath)),
              obsidianBackfill == nil else { return }
        let vault = URL(fileURLWithPath: ZMeetPaths.expandTilde(rawPath))
        let sessions = ((try? manager.listSessions()) ?? []).filter { $0.status == .processed }
        obsidianBackfillMessage = nil
        obsidianBackfill = BackfillProgress(done: 0, total: sessions.count)
        Task {
            var done = 0, published = 0, skipped = 0
            for session in sessions {
                // Skip meetings already imported into THIS vault under their current
                // name — so re-running the backfill only picks up new/renamed/missing
                // meetings instead of re-publishing (and re-extracting) everything.
                if isAlreadyPublished(session, in: vault) {
                    skipped += 1
                } else if let notes = onDiskNotes(for: session) {
                    await publishToObsidianIfEnabled(session: session, transcript: notes.transcript, summary: notes.summary)
                    published += 1
                } else {
                    skipped += 1  // no readable transcript/notes on disk
                }
                done += 1
                obsidianBackfill = BackfillProgress(done: done, total: sessions.count)
            }
            obsidianBackfill = nil
            obsidianBackfillMessage = Self.backfillSummary(published: published, skipped: skipped, total: sessions.count)
        }
    }

    /// Human-readable outcome of a backfill run for the Settings UI.
    private static func backfillSummary(published: Int, skipped: Int, total: Int) -> String {
        func meetings(_ n: Int) -> String { "\(n) meeting\(n == 1 ? "" : "s")" }
        if total == 0 { return "No processed meetings to publish yet." }
        if published == 0 { return "All \(meetings(total)) already in the vault." }
        if skipped == 0 { return "Published \(meetings(published)) to the vault." }
        return "Published \(meetings(published)); \(meetings(skipped)) already in the vault."
    }

    /// True when the meeting's note already exists in the vault under its current name
    /// (tracked via obsidianBaseName + a file-existence check, so switching vaults or
    /// renaming a meeting correctly re-publishes).
    private func isAlreadyPublished(_ session: MeetingSession, in vault: URL) -> Bool {
        let names = ObsidianVaultFiles.names(for: session)
        return session.obsidianBaseName == names.mainNoteName
            && FileManager.default.fileExists(atPath: vault.appendingPathComponent(names.main).path)
    }

    /// Reads a processed meeting's transcript and summary back off disk (the summary is
    /// recovered from the rendered note). Returns nil if either isn't readable.
    private func onDiskNotes(for session: MeetingSession) -> (transcript: String, summary: String)? {
        guard let transcriptPath = session.transcriptPath,
              let notePath = session.notePath,
              let transcript = try? String(contentsOf: URL(fileURLWithPath: transcriptPath), encoding: .utf8),
              let note = try? String(contentsOf: URL(fileURLWithPath: notePath), encoding: .utf8) else { return nil }
        let summary = MarkdownRenderer().summaryBody(fromProcessedNote: note)
        guard !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return (transcript, summary)
    }

    /// Folder picker for choosing an Obsidian vault manually (mirrors the notes-
    /// folder picker). Writes the chosen path into config.
    func chooseObsidianVault() {
        settingsMenu = nil
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = false
        panel.prompt = "Choose"
        if let cur = config.obsidianVaultPath, !cur.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: ZMeetPaths.expandTilde(cur))
        }
        if panel.runModal() == .OK, let url = panel.url {
            updateConfig { $0.obsidianVaultPath = url.path }
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
