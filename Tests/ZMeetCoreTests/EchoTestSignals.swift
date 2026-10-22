import Foundation
import Testing
@testable import ZMeetCore

/// SplitMix64. Fully specified, so every echo test signal is identical on every
/// machine and toolchain.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

fileprivate extension SeededGenerator {
    /// Uniform in [0, 1) from the top 53 bits. Not `Double.random(in:using:)`, whose
    /// algorithm the standard library doesn't promise to keep.
    mutating func unit() -> Double { Double(next() >> 11) / Double(UInt64(1) << 53) }
}

/// Deterministic signals shared by the echo-pipeline tests (canceller, lag tracker, aligner).
enum EchoTestSignals {
    /// Speech-like far end: uniform noise at −20 dBFS RMS, gated into 300–700 ms bursts
    /// separated by 100–400 ms gaps (lengths drawn from the seeded generator), with
    /// 10 ms raised-cosine edges on every burst.
    static func speechLike(seconds: Double, seed: UInt64, rate: Int = 48_000) -> [Float] {
        let count = Int((seconds * Double(rate)).rounded())
        var out = [Float](repeating: 0, count: count)
        var generator = SeededGenerator(seed: seed)
        let amplitude = 0.1 * 3.0.squareRoot()  // uniform on [−a, a] has RMS a/√3; 0.1 = −20 dBFS
        let edge = Double(rate) / 100            // 10 ms
        var start = 0
        while start < count {
            let burst = Int(((0.3 + 0.4 * generator.unit()) * Double(rate)).rounded())
            for i in 0..<burst where start + i < count {
                let ramp = min(1, (Double(i) + 0.5) / edge, (Double(burst - i) - 0.5) / edge)
                let envelope = 0.5 - 0.5 * cos(Double.pi * ramp)
                out[start + i] = Float(envelope * amplitude * (2 * generator.unit() - 1))
            }
            let gap = Int(((0.1 + 0.3 * generator.unit()) * Double(rate)).rounded())
            start += burst + gap
        }
        return out
    }

    /// Speaker echo of `x`: a pure delay of round(delayMs·rate/1000) samples, then the
    /// room response h[n] = exp(−n / (0.0025·rate)) for n < 0.015·rate, scaled so that
    /// sqrt(Σh²) = 10^(gainDB/20). Same length as `x`.
    static func echo(of x: [Float], delayMs: Double, gainDB: Double, rate: Int = 48_000) -> [Float] {
        let delay = Int((delayMs * Double(rate) / 1000).rounded())
        let taps = Int((0.015 * Double(rate)).rounded())
        let decay = exp(-1 / (0.0025 * Double(rate)))  // h[n] = decay^n before scaling
        var energy = 0.0
        for n in 0..<taps { energy += pow(decay, 2 * Double(n)) }
        let scale = pow(10, gainDB / 20) / energy.squareRoot()
        let lastTap = pow(decay, Double(taps))
        // u[j] = Σ_{k<taps} decay^k · x[j − k], run as the equivalent recursion
        // u[j] = decay·u[j−1] + x[j] − decay^taps · x[j − taps]: the same truncated
        // convolution in O(n), so seconds of 48 kHz audio stay fast in debug builds.
        var y = [Float](repeating: 0, count: x.count)
        var u = 0.0
        for n in 0..<x.count where n >= delay {
            let j = n - delay
            u = decay * u + Double(x[j]) - (j >= taps ? lastTap * Double(x[j - taps]) : 0)
            y[n] = Float(scale * u)
        }
        return y
    }

    /// A sine at `hz` whose RMS is `dbfs` dBFS (peak √2 · 10^(dbfs/20)), starting at phase 0.
    static func tone(hz: Double, dbfs: Double, seconds: Double, rate: Int = 48_000) -> [Float] {
        let count = Int((seconds * Double(rate)).rounded())
        let peak = 2.0.squareRoot() * pow(10, dbfs / 20)
        let step = 2 * Double.pi * hz / Double(rate)
        return (0..<count).map { Float(peak * sin(step * Double($0))) }
    }

    /// 20·log10(RMS); −200 when the RMS is 0 (including an empty slice). NaN when a sample is
    /// NaN, so that no comparison with it holds: a canceller whose output went NaN must not read
    /// as one that removed everything.
    static func rmsDB(_ x: ArraySlice<Float>) -> Double {
        var power = 0.0
        for v in x { power += Double(v) * Double(v) }
        let rms = x.isEmpty ? 0 : (power / Double(x.count)).squareRoot()
        return rms == 0 ? -200 : 20 * log10(rms)
    }

    /// Element-wise a + b; the result has the longer length, the shorter input reading as zeros.
    static func sum(_ a: [Float], _ b: [Float]) -> [Float] {
        (0..<max(a.count, b.count)).map { i in
            (i < a.count ? a[i] : 0) + (i < b.count ? b[i] : 0)
        }
    }

    /// Runs the canceller in 10 ms frames: processRender(far) then processCapture(mic) for
    /// each frame, zero-padding the last one. The output has exactly mic.count samples.
    static func runCanceller(_ c: EchoCanceller, mic: [Float], far: [Float]) -> [Float] {
        let n = EchoCanceller.frameSize
        var out: [Float] = []
        out.reserveCapacity(mic.count)
        var start = 0
        while start < mic.count {
            var farFrame = [Float](repeating: 0, count: n)
            var micFrame = [Float](repeating: 0, count: n)
            for i in 0..<n {
                if start + i < far.count { farFrame[i] = far[start + i] }
                if start + i < mic.count { micFrame[i] = mic[start + i] }
            }
            let rendered = c.processRender(farFrame)
            let captured = c.processCapture(&micFrame)
            #expect(rendered && captured, "APM rejected the frame at sample \(start)")
            out.append(contentsOf: micFrame.prefix(mic.count - start))
            start += n
        }
        return out
    }
}
