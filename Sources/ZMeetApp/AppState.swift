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
    @Published private(set) var recent: [MeetingSession] = []
    /// Every meeting, newest first — backs the Library window.
    @Published private(set) var allSessions: [MeetingSession] = []
    /// Currently-selected meeting in the Library window (nil = newest).
    @Published var librarySelectedID: String?
    @Published var draftTitle: String = ""
    @Published private(set) var lastError: String?
    @Published private(set) var micGranted: Bool = false
    @Published private(set) var screenGranted: Bool = false
    @Published private(set) var speechGranted: Bool = false

    private let store = ConfigStore()
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

    func setMicDevice(_ id: String?) {
        updateConfig { $0.audio.micDeviceID = id }
    }

    /// Mutate + persist config, then apply side-effects (recorder uses the new
    /// config; meeting detection turns on/off).
    func updateConfig(_ mutate: (inout ZMeetConfig) -> Void) {
        mutate(&config)
        try? store.write(config)
        manager = SessionManager(config: config, recorder: recorder)
        if config.detectMeetings {
            startMeetingDetection()
        } else {
            detector.stop()
            meetingPopup.hide()
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
        // Apply the chosen mode (remote captures system audio, in-person doesn't)
        // and remember it.
        updateConfig {
            $0.recordingMode = mode
            $0.audio.captureSystemAudio = (mode == .remote)
        }
        Task {
            let ok = await requestPermissions()
            guard ok else {
                lastError = "Microphone and Screen Recording permission are required. Grant them in System Settings → Privacy & Security, then try again."
                Permissions.openScreenRecordingSettings()
                return
            }
            do {
                _ = try manager.start(title: draftTitle, sourceApp: sourceApp)
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
        lastError = nil
        recordingFromDetection = false
        do {
            let stopped = try manager.stop()
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

    func process(id: String) {
        lastError = nil
        phase = .processing
        Task {
            do {
                // The async Apple speech/LLM work runs off the main actor; the
                // synchronous Core write happens back on the main actor.
                let session = try manager.session(id: id)
                let audioURL = URL(fileURLWithPath: session.audioPath)
                let (transcript, summary) = try await produceNotes(audioURL: audioURL, title: session.title)
                let processed = try manager.applyProcessedText(id: id, transcript: transcript, summary: summary)
                notesReadyPopup.show(title: processed.title) { [weak self] in
                    self?.revealNote(processed)
                }
            } catch {
                lastError = error.localizedDescription
            }
            phase = .idle
            reloadRecent()
        }
    }

    private func produceNotes(audioURL: URL, title: String) async throws -> (transcript: String, summary: String) {
        if #available(macOS 26, *) {
            let transcript = try await SpeechTranscription().transcribe(audioURL: audioURL)
            let summary = try await MeetingSummarizer().summarize(transcript: transcript, title: title)
            return (transcript, summary)
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
