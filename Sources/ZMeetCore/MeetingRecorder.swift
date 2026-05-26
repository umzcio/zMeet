import Foundation

/// Drives audio capture for a recording session. ZMeetCore owns this seam;
/// the concrete implementation (ScreenCaptureKit + AVAudioEngine) lives in the
/// app target, because capture is inseparable from app TCC permissions and
/// cannot be exercised in headless unit tests.
///
/// Implementations are expected to begin writing an AAC `.m4a` file at the URL
/// passed to `start(to:logURL:audio:)` and to finalize/close it on `stop()`.
/// `start` may initiate capture asynchronously and return promptly; failures
/// that occur after `start` returns are surfaced by the implementation (written
/// to `logURL` and reflected via session recovery on next launch), not thrown here.
public protocol MeetingRecorder {
    /// Begin capturing to `url`, writing any capture diagnostics to `logURL`.
    /// Throws only for synchronous setup failures (e.g. permission denied up
    /// front, no shareable content). `start` may initiate capture
    /// asynchronously and return promptly; failures that occur after `start`
    /// returns are surfaced by the implementation (written to `logURL` and
    /// reflected via session recovery on next launch), not thrown here.
    func start(to url: URL, logURL: URL, audio: AudioConfig) throws

    /// Stop capture and finalize the audio file.
    func stop() throws
}
