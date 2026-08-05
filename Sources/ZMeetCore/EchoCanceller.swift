import CSpeexDSP
import Foundation

/// Reference-based acoustic echo canceller (speexdsp MDF + residual-echo preprocessor).
/// Fed fixed-size frames of 16-bit mono PCM: `near` (mic + speaker bleed) and `far`
/// (the system/remote audio that bled in). Returns the mic with the echo removed.
/// NOT thread-safe — own one per recording and call from a single queue.
public final class EchoCanceller {
    private let frameSize: Int
    private let echo: OpaquePointer
    private let preprocess: OpaquePointer

    /// - frameSize: samples per frame (160 = 10 ms @ 16 kHz).
    /// - filterLength: adaptive-filter tail in samples (1600 = 100 ms, a typical room).
    public init(frameSize: Int = 160, filterLength: Int = 1600, sampleRate: Int32 = 16_000) {
        self.frameSize = frameSize
        echo = speex_echo_state_init(Int32(frameSize), Int32(filterLength))
        preprocess = speex_preprocess_state_init(Int32(frameSize), sampleRate)
        var rate = sampleRate
        _ = speex_echo_ctl(echo, SPEEX_ECHO_SET_SAMPLING_RATE, &rate)
        // Link the preprocessor to the echo state so it suppresses residual echo the
        // linear filter leaves behind.
        _ = speex_preprocess_ctl(preprocess, SPEEX_PREPROCESS_SET_ECHO_STATE, UnsafeMutableRawPointer(echo))
    }

    deinit {
        speex_echo_state_destroy(echo)
        speex_preprocess_state_destroy(preprocess)
    }

    /// Cancel the echo of `far` from `near`. Both arrays MUST be exactly `frameSize`.
    public func cancel(near: [Int16], far: [Int16]) -> [Int16] {
        precondition(near.count == frameSize && far.count == frameSize, "frame size mismatch")
        var out = [Int16](repeating: 0, count: frameSize)
        near.withUnsafeBufferPointer { n in
            far.withUnsafeBufferPointer { f in
                out.withUnsafeMutableBufferPointer { o in
                    speex_echo_cancellation(echo, n.baseAddress, f.baseAddress, o.baseAddress)
                    _ = speex_preprocess_run(preprocess, o.baseAddress)
                }
            }
        }
        return out
    }
}
