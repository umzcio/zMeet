import Foundation
import ZMeetCore

/// Placeholder recorder for Milestone 1: writes a tiny non-empty file at the
/// audio path so the session/notes pipeline runs end-to-end without real audio.
/// Replaced by SCKAudioRecorder in Milestone 2.
final class StubRecorder: MeetingRecorder, Sendable {
    func start(to url: URL, logURL: URL, audio: AudioConfig) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(
            atPath: url.path,
            contents: Data("zmeet stub recording\n".utf8)
        )
    }

    func stop() async throws {
        // Nothing to finalize for the stub.
    }
}
