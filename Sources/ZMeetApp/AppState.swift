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
    @Published var draftTitle: String = ""
    @Published private(set) var lastError: String?
    @Published private(set) var micGranted: Bool = false
    @Published private(set) var screenGranted: Bool = false

    private let store = ConfigStore()
    private let config: ZMeetConfig
    private let manager: SessionManager
    private let detector = MeetingDetector()
    private let meetingPopup = MeetingPopupController()
    private var dismissedMeetingKeys: Set<String> = []

    init(recorder: MeetingRecorder = StubRecorder()) {
        // Load config, or bootstrap a fresh one if missing/old-schema.
        let loaded: ZMeetConfig
        if let existing = try? store.load() {
            loaded = existing
        } else {
            loaded = (try? store.bootstrap()) ?? ZMeetConfig.default()
        }
        self.config = loaded
        self.manager = SessionManager(config: loaded, recorder: recorder)

        // Finalize any session interrupted by a previous crash/quit.
        _ = try? manager.recoverInterruptedSessions()
        reloadRecent()
        refreshPermissions()
        startMeetingDetection()
    }

    private func startMeetingDetection() {
        detector.onChange = { [weak self] meeting in
            guard let self else { return }
            guard let meeting else {
                // Meeting ended: hide the popup and allow future meetings to prompt again.
                self.meetingPopup.hide()
                self.dismissedMeetingKeys.removeAll()
                return
            }
            // Don't prompt while already recording, or for a meeting already dismissed.
            guard !self.isRecording, !self.dismissedMeetingKeys.contains(meeting.key) else { return }
            self.meetingPopup.show(
                meeting: meeting,
                onStart: {
                    self.draftTitle = meeting.title
                    self.startRecording(sourceApp: meeting.app)
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

    func startRecording(sourceApp: String? = nil) {
        lastError = nil
        meetingPopup.hide()
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
                _ = try manager.applyProcessedText(id: id, transcript: transcript, summary: summary)
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
        recent = (try? manager.listSessions().prefix(10).map { $0 }) ?? []
    }
}
