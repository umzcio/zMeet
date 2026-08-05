import Foundation
@testable import ZMeetCore

/// Test double for MeetingRecorder. Optionally simulates writing a non-empty
/// audio file on start so tests can exercise the recorded-vs-failed paths.
final class MockRecorder: MeetingRecorder, @unchecked Sendable {
    private(set) var startedURL: URL?
    private(set) var startedLogURL: URL?
    private(set) var startedAudio: AudioConfig?
    private(set) var stopCount = 0
    var createsAudioFile: Bool
    var audioFileSize: Int
    var startError: Error?
    var stopError: Error?
    var onCaptureFailure: (@Sendable (String) -> Void)?
    /// Optional hook awaited at the very start of stop(), before stopCount is
    /// incremented. Lets tests deterministically sequence their own assertions
    /// against SessionManager's compensating-Task ordering instead of racing
    /// it. nil (the default) is a no-op — no behavior change for other tests.
    var beforeStop: (@Sendable () async -> Void)?

    init(createsAudioFile: Bool = true, audioFileSize: Int = 32) {
        self.createsAudioFile = createsAudioFile
        self.audioFileSize = audioFileSize
    }

    /// Test hook: invokes the stored `onCaptureFailure` handler synchronously,
    /// as if capture had died after `start()` returned.
    func simulateCaptureFailure(_ message: String) {
        onCaptureFailure?(message)
    }

    func start(to url: URL, logURL: URL, audio: AudioConfig) throws {
        if let startError { throw startError }
        startedURL = url
        startedLogURL = logURL
        startedAudio = audio
        if createsAudioFile {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            FileManager.default.createFile(atPath: url.path, contents: Data(repeating: 0, count: audioFileSize))
        }
    }

    func stop() async throws {
        if let beforeStop { await beforeStop() }
        stopCount += 1
        if let stopError { throw stopError }
    }
}
