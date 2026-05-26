import Foundation
@testable import ZMeetCore

/// Test double for MeetingRecorder. Optionally simulates writing a non-empty
/// audio file on start so tests can exercise the recorded-vs-failed paths.
final class MockRecorder: MeetingRecorder {
    private(set) var startedURL: URL?
    private(set) var startedLogURL: URL?
    private(set) var stopCount = 0
    var createsAudioFile: Bool
    var startError: Error?

    init(createsAudioFile: Bool = true) {
        self.createsAudioFile = createsAudioFile
    }

    func start(to url: URL, logURL: URL, audio: AudioConfig) throws {
        if let startError { throw startError }
        startedURL = url
        startedLogURL = logURL
        if createsAudioFile {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            FileManager.default.createFile(atPath: url.path, contents: Data(repeating: 0, count: 32))
        }
    }

    func stop() throws {
        stopCount += 1
    }
}
