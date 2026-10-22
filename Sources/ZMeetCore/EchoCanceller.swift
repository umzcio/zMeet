import CWebRTCAPM
import Foundation

/// AEC3's own view of the echo path. Each value is nil until AEC3 has one.
public struct EchoStatistics: Sendable, Equatable {
    /// ERL, 10·log10(P_far / P_echo): how much quieter the echo is than the reference.
    public var echoReturnLossDB: Double?
    /// ERLE, 10·log10(P_echo / P_out): how much echo AEC3 believes it removed.
    public var echoReturnLossEnhancementDB: Double?
    /// AEC3's instantaneous estimate of the render-to-capture delay.
    public var delayMs: Int?
}

/// One echo canceller step per 10 ms: exactly one render frame, then exactly one
/// capture frame. AEC3 needs these calls strictly paired.
public protocol EchoProcessing: AnyObject {
    /// Feeds the far end (the system audio the speakers played). False on an APM error.
    func processRender(_ frame: [Float]) -> Bool
    /// Cleans the mic frame in place. False on an APM error.
    func processCapture(_ frame: inout [Float]) -> Bool
}

/// Speaker-echo canceller: WebRTC AEC3 (vendored in CWebRTCAPM) at 48 kHz mono,
/// float samples in [-1, 1], 10 ms frames of `frameSize` samples. Noise
/// suppression and gain control are off; only the echo canceller and its
/// high-pass filter run.
///
/// NOT thread-safe: one instance per recording, used from one queue.
public final class EchoCanceller: EchoProcessing {
    public static let sampleRate = 48_000
    public static let frameSize = 480

    private let apm: OpaquePointer

    /// nil if APM can't be created.
    public init?() {
        guard let apm = zm_apm_create(Int32(Self.sampleRate), 1, 0) else { return nil }
        guard Int(zm_apm_frame_samples(apm)) == Self.frameSize else {
            zm_apm_destroy(apm)
            return nil
        }
        self.apm = apm
    }

    deinit { zm_apm_destroy(apm) }

    public func processRender(_ frame: [Float]) -> Bool {
        precondition(frame.count == Self.frameSize, "render frame must be \(Self.frameSize) samples")
        return zm_apm_process_reverse(apm, frame) == 0
    }

    public func processCapture(_ frame: inout [Float]) -> Bool {
        precondition(frame.count == Self.frameSize, "capture frame must be \(Self.frameSize) samples")
        return zm_apm_process_capture(apm, &frame) == 0
    }

    public var statistics: EchoStatistics {
        var stats = ZMApmStats()
        guard zm_apm_get_stats(apm, &stats) == 0 else { return EchoStatistics() }
        return EchoStatistics(
            echoReturnLossDB: stats.has_echo_return_loss != 0 ? stats.echo_return_loss : nil,
            echoReturnLossEnhancementDB: stats.has_echo_return_loss_enhancement != 0
                ? stats.echo_return_loss_enhancement : nil,
            delayMs: stats.has_delay_ms != 0 ? Int(stats.delay_ms) : nil
        )
    }
}
