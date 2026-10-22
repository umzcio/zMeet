import Accelerate
import Foundation

/// One GCC-PHAT measurement of the delay between two equal-length windows.
public struct LagEstimate: Sendable, Equatable {
    /// How many samples `observed` trails `reference`: > 0 when the observed copy
    /// comes later (an echo trailing its source), < 0 when it comes earlier.
    public var lagSamples: Int
    /// The correlation peak over the mean |correlation| of every other searched lag.
    public var peakRatio: Double
    /// The correlation peak over the highest |correlation| more than 3 samples from it.
    public var distinctiveness: Double
    /// peakRatio ≥ 10 and distinctiveness ≥ 1.15: confident enough to act on.
    public var accepted: Bool
}

/// Generalized cross-correlation with the phase transform. Whitening the
/// cross-spectrum turns the correlation of a delayed copy into a sharp spike at
/// the delay, whatever the two signals' spectra, so speech, music and noise all
/// measure alike.
public enum GCCPhat {
    static let acceptedPeakRatio = 10.0
    static let acceptedDistinctiveness = 1.15
    /// The peak's own main lobe, which `distinctiveness` looks past.
    static let peakNeighborhood = 3

    /// Equal-length windows. nil if either window's RMS (after mean removal) < rmsFloor.
    /// Searches lags in ±maxLagSamples, capped at the window length − 1.
    public static func estimate(reference: [Float], observed: [Float], maxLagSamples: Int,
                                rmsFloor: Float = 0.003) -> LagEstimate? {
        precondition(reference.count == observed.count, "GCC-PHAT windows must be the same length")
        precondition(maxLagSamples > 0, "maxLagSamples must be positive")
        let count = reference.count
        guard count >= 2 else { return nil }
        // The next power of two ≥ 2× the window. With that much zero padding the
        // circular correlation equals the linear one, so lags never wrap into each other.
        let n = 1 << (Int.bitWidth - (2 * count - 1).leadingZeroBitCount)
        guard let ref = centered(reference, paddedTo: n, rmsFloor: rmsFloor),
              let obs = centered(observed, paddedTo: n, rmsFloor: rmsFloor) else { return nil }
        let log2n = vDSP_Length(n.trailingZeroBitCount)
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return nil }
        defer { vDSP_destroy_fftsetup(setup) }

        let cross = phatCrossSpectrum(observed: forward(obs, setup: setup, log2n: log2n),
                                      reference: forward(ref, setup: setup, log2n: log2n))
        let correlation = inverse(cross, setup: setup, log2n: log2n)
        return peak(of: correlation, maxLag: min(maxLagSamples, count - 1))
    }

    /// `x` minus its mean, zero-padded to `length`; nil when what remains has an RMS
    /// below `rmsFloor` (or isn't finite).
    private static func centered(_ x: [Float], paddedTo length: Int, rmsFloor: Float) -> [Float]? {
        let mean = vDSP.mean(x)
        var out = [Float](repeating: 0, count: length)
        for i in x.indices { out[i] = x[i] - mean }
        let rms = vDSP.rootMeanSquare(out[0..<x.count])
        guard rms.isFinite, rms >= rmsFloor else { return nil }
        return out
    }

    /// vDSP's packed real-FFT layout for n samples: re[0] is the DC bin and im[0]
    /// the Nyquist bin (both real); (re[k], im[k]) is bin k for 0 < k < n/2.
    private struct PackedSpectrum {
        var re: [Float]
        var im: [Float]
    }

    private static func forward(_ signal: [Float], setup: FFTSetup, log2n: vDSP_Length) -> PackedSpectrum {
        let half = signal.count / 2
        var re = [Float](repeating: 0, count: half)
        var im = [Float](repeating: 0, count: half)
        re.withUnsafeMutableBufferPointer { re in
            im.withUnsafeMutableBufferPointer { im in
                var split = DSPSplitComplex(realp: re.baseAddress!, imagp: im.baseAddress!)
                signal.withUnsafeBufferPointer { samples in
                    samples.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
            }
        }
        return PackedSpectrum(re: re, im: im)
    }

    /// The real signal whose packed spectrum is `spectrum`, up to a constant scale
    /// (which every ratio taken from it cancels).
    private static func inverse(_ spectrum: PackedSpectrum, setup: FFTSetup, log2n: vDSP_Length) -> [Float] {
        let half = spectrum.re.count
        var re = spectrum.re
        var im = spectrum.im
        var out = [Float](repeating: 0, count: 2 * half)
        re.withUnsafeMutableBufferPointer { re in
            im.withUnsafeMutableBufferPointer { im in
                var split = DSPSplitComplex(realp: re.baseAddress!, imagp: im.baseAddress!)
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_INVERSE))
                out.withUnsafeMutableBufferPointer { samples in
                    samples.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                        vDSP_ztoc(&split, 1, $0, 2, vDSP_Length(half))
                    }
                }
            }
        }
        return out
    }

    /// C = Obs · conj(Ref), each bin scaled to C / max(|C|, 1e-12). Its inverse
    /// transform peaks at lag d when observed[t] = reference[t − d].
    private static func phatCrossSpectrum(observed o: PackedSpectrum, reference r: PackedSpectrum) -> PackedSpectrum {
        let half = o.re.count
        var re = [Float](repeating: 0, count: half)
        var im = [Float](repeating: 0, count: half)
        // The packed DC and Nyquist bins are real.
        re[0] = unitScaled(o.re[0] * r.re[0])
        im[0] = unitScaled(o.im[0] * r.im[0])
        for k in 1..<half {
            let cr = o.re[k] * r.re[k] + o.im[k] * r.im[k]
            let ci = o.im[k] * r.re[k] - o.re[k] * r.im[k]
            let scale = 1 / max((cr * cr + ci * ci).squareRoot(), 1e-12)
            re[k] = cr * scale
            im[k] = ci * scale
        }
        return PackedSpectrum(re: re, im: im)
    }

    private static func unitScaled(_ x: Float) -> Float { x / max(abs(x), 1e-12) }

    /// Reads |r| at every lag in ±maxLag (a negative lag sits at index n + lag)
    /// and scores the highest one.
    private static func peak(of r: [Float], maxLag: Int) -> LagEstimate? {
        let span = 2 * maxLag + 1
        var magnitude = [Double](repeating: 0, count: span)  // magnitude[i] is |r| at lag i − maxLag
        for i in 0..<span {
            let lag = i - maxLag
            magnitude[i] = Double(abs(r[lag >= 0 ? lag : r.count + lag]))
        }
        var peakIndex = 0
        for i in 1..<span where magnitude[i] > magnitude[peakIndex] { peakIndex = i }
        let peak = magnitude[peakIndex]
        guard peak > 0 else { return nil }
        var othersSum = 0.0
        var runnerUp = 0.0
        for i in 0..<span where i != peakIndex {
            othersSum += magnitude[i]
            if abs(i - peakIndex) > peakNeighborhood { runnerUp = max(runnerUp, magnitude[i]) }
        }
        let peakRatio = peak / (othersSum / Double(span - 1))
        let distinctiveness = peak / runnerUp
        return LagEstimate(
            lagSamples: peakIndex - maxLag,
            peakRatio: peakRatio,
            distinctiveness: distinctiveness,
            accepted: peakRatio >= acceptedPeakRatio && distinctiveness >= acceptedDistinctiveness
        )
    }
}

/// Measures the delay D at which the echo appears in the mic relative to the
/// reference fed alongside it, for `EchoAligner` to keep D inside AEC3's range.
public protocol EchoLagTracking {
    /// 48 kHz mono, equal lengths: the reference (far end) and the raw mic it echoes into.
    mutating func append(reference: [Float], observed: [Float])
    /// The echo delay (observed trailing reference) last locked onto. Held through
    /// silence and low confidence; nil only before the first lock or after `reset()`.
    var lockedLagMs: Double? { get }
    /// Forgets all audio, measurements and the lock.
    mutating func reset()
}

/// GCC-PHAT supervisor for the echo delay. Both streams are decimated to 16 kHz
/// (the mean of every 3 samples); once the 1.024 s window first fills, and then
/// every 1 s, it measures the lag within ±600 ms. It locks when ≥ 3 of the last
/// 4 accepted lags lie within ±1.5 ms of their median, and the lock is that
/// cluster's median.
///
/// The lock never falls back on its own: rejected and quiet windows leave it as
/// it is, and a new consistent cluster replaces it directly, with no "lost" state
/// in between. Only `reset()` clears it.
public struct EchoLagTracker: EchoLagTracking {
    public static let analysisRate = 16_000
    static let decimation = 3                 // 48 kHz → 16 kHz
    static let windowSamples = 16_384         // 1.024 s
    static let measurementInterval = 16_000   // 1 s
    static let maxLagSamples = 9_600          // ±600 ms
    static let rmsFloor: Float = 0.003
    static let historyLength = 4
    static let lockCount = 3
    static let lockToleranceSamples = 24.0    // 1.5 ms

    public private(set) var lockedLagMs: Double?
    /// The latest measurement, accepted or not; nil if that window was too quiet.
    public private(set) var lastEstimate: LagEstimate?

    private var referenceRing = [Float](repeating: 0, count: windowSamples)
    private var observedRing = [Float](repeating: 0, count: windowSamples)
    private var ringWriteIndex = 0
    private var ringFill = 0
    private var samplesSinceMeasurement = 0
    private var pendingReference: Float = 0   // the 48 kHz samples of the analysis sample being built
    private var pendingObserved: Float = 0
    private var pendingCount = 0
    private var acceptedLags: [Int] = []      // the last `historyLength` accepted lags, oldest first

    public init() {}

    public mutating func append(reference: [Float], observed: [Float]) {
        precondition(reference.count == observed.count, "reference and observed must be the same length")
        for i in 0..<reference.count {
            pendingReference += reference[i]
            pendingObserved += observed[i]
            pendingCount += 1
            guard pendingCount == Self.decimation else { continue }
            push(reference: pendingReference / Float(Self.decimation),
                 observed: pendingObserved / Float(Self.decimation))
            pendingReference = 0
            pendingObserved = 0
            pendingCount = 0
        }
    }

    public mutating func reset() {
        lockedLagMs = nil
        lastEstimate = nil
        ringWriteIndex = 0
        ringFill = 0  // the rings' stale contents are overwritten before the next measurement
        samplesSinceMeasurement = 0
        pendingReference = 0
        pendingObserved = 0
        pendingCount = 0
        acceptedLags.removeAll(keepingCapacity: true)
    }

    private mutating func push(reference: Float, observed: Float) {
        referenceRing[ringWriteIndex] = reference
        observedRing[ringWriteIndex] = observed
        ringWriteIndex += 1
        if ringWriteIndex == Self.windowSamples { ringWriteIndex = 0 }
        ringFill = min(ringFill + 1, Self.windowSamples)
        samplesSinceMeasurement += 1
        if samplesSinceMeasurement >= Self.measurementInterval && ringFill == Self.windowSamples {
            samplesSinceMeasurement = 0
            measure()
        }
    }

    private mutating func measure() {
        let estimate = GCCPhat.estimate(reference: unrolled(referenceRing), observed: unrolled(observedRing),
                                        maxLagSamples: Self.maxLagSamples, rmsFloor: Self.rmsFloor)
        lastEstimate = estimate
        guard let estimate, estimate.accepted else { return }
        acceptedLags.append(estimate.lagSamples)
        if acceptedLags.count > Self.historyLength { acceptedLags.removeFirst() }
        let lags = acceptedLags.map(Double.init)
        let center = Self.median(lags)
        let cluster = lags.filter { abs($0 - center) <= Self.lockToleranceSamples }
        guard cluster.count >= Self.lockCount else { return }
        lockedLagMs = Self.median(cluster) * 1_000 / Double(Self.analysisRate)
    }

    /// The ring, oldest sample first.
    private func unrolled(_ ring: [Float]) -> [Float] {
        var out: [Float] = []
        out.reserveCapacity(ring.count)
        out.append(contentsOf: ring[ringWriteIndex...])
        out.append(contentsOf: ring[..<ringWriteIndex])
        return out
    }

    /// The middle value of a non-empty list, or the mean of the middle two for an even count.
    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }
}
