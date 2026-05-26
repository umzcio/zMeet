import Foundation
import SwiftUI
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

    private let store = ConfigStore()
    private let config: ZMeetConfig
    private let manager: SessionManager

    init(recorder: MeetingRecorder = StubRecorder()) {
        // Load config, or bootstrap a fresh one if missing/old-schema.
        let loaded: ZMeetConfig
        if let existing = try? store.load() {
            loaded = existing
        } else {
            loaded = (try? store.bootstrap(notesRepoPath: "~/Documents/Github/zMeetNotes"))
                ?? ZMeetConfig.default(notesRepoPath: "~/Documents/Github/zMeetNotes")
        }
        self.config = loaded
        self.manager = SessionManager(config: loaded, recorder: recorder)

        // Finalize any session interrupted by a previous crash/quit.
        _ = try? manager.recoverInterruptedSessions()
        reloadRecent()
    }

    var isRecording: Bool {
        if case .recording = phase { return true }
        return false
    }

    func startRecording() {
        lastError = nil
        do {
            _ = try manager.start(title: draftTitle, sourceApp: nil)
            phase = .recording(since: Date())
            draftTitle = ""
            reloadRecent()
        } catch {
            lastError = error.localizedDescription
        }
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
        // Placeholder/stub processing is fast, so run it on the main actor.
        // Milestone 2: when real transcription/summary commands can be slow,
        // move this onto a background executor to keep the menu responsive.
        phase = .processing
        defer {
            phase = .idle
            reloadRecent()
        }
        do {
            _ = try manager.process(id: id)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func revealNote(_ session: MeetingSession) {
        guard let path = session.notePath else { return }
        NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
    }

    func openNotesFolder() {
        let path = ZMeetPaths.expandTilde(config.notesRepoPath)
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    func openConfigFile() {
        NSWorkspace.shared.open(store.configURL)
    }

    private func reloadRecent() {
        recent = (try? manager.listSessions().prefix(10).map { $0 }) ?? []
    }
}
