import Foundation
@preconcurrency import AVFoundation
import ZMeetCore

// aec-probe: runs zMeet's speaker-echo pipeline offline, the way the recorder runs it
// live. EchoAligner pairs the mic with the system audio, EchoCanceller (WebRTC AEC3)
// cleans the mic, and EchoLagTracker steers the aligner's lead.
//
//   aec-probe <mic.m4a> <system.m4a> [out.m4a]
//   aec-probe --selftest
//
// mic.m4a     near end: you, plus the speaker echo of the other participants
// system.m4a  far end: the system audio the speakers played (the canceller's reference)
// out.m4a     the mic with the echo removed, 48 kHz mono AAC. Defaults to mic-clean.m4a
//             next to the mic file, which is never replaced unless named explicitly
//             (the recorder's echo-debug folder keeps its own mic-clean.m4a).
//
// Both files are decoded to 48 kHz and averaged to mono with EchoAudio.monoMix, as the
// recorder does. They are fed in alternating 1 024-sample chunks, system audio first.
// Each chunk is stamped pts = its first sample's index / 48 000, and the aligner's
// clock is advanced to that pts, so sample 0 of both files counts as the same instant.
//
// For every 10 s of cleaned mic it prints one row:
//   t=<s> mic=<dBFS> out=<dBFS> reduction=<dB> lag=<ms|-> lead=<ms> erle=<dB|-> delay=<ms|->
// The levels cover those 10 s. The rest is as of the row: lag is the tracker's lock, "-"
// without one. It is the echo's delay behind the reference as fed, so it includes the
// lead (a 60 ms echo at a 100 ms lead reads about 160). Then the lead, and AEC3's ERLE
// and delay, "-" only before its first capture frame. A summary follows.
//
// --selftest synthesizes 10 s of speech-like far end with a 60 ms / −10 dB echo, plus a
// −35 dBFS 1 kHz near-end tone from 8 to 10 s, and runs the same pipeline. It exits 0
// only when the echo drops by ≥ 25 dB over 4–8 s and the near end changes by ≤ 6 dB
// over 8.5–10 s, while the echo goes on.

let sampleRate = EchoCanceller.sampleRate  // the pipeline runs 48 kHz mono
let chunkSize = 1_024
let rowSamples = 10 * sampleRate

let usage = """
    usage: aec-probe <mic.m4a> <system.m4a> [out.m4a]
           aec-probe --selftest
    """

enum ProbeError: Error, CustomStringConvertible {
    case missingFile(String)
    case unreadable(String, Error)
    case unsupportedFormat(String)
    case convertFailed(String)
    case allocFailed
    case outputExists(String)
    case outputIsInput(String)
    case outputIsDirectory(String)
    case cancellerUnavailable

    var description: String {
        switch self {
        case .missingFile(let path): return "file not found: \(path)"
        case .unreadable(let path, let error):
            return "can't read \(path) as audio (\((error as NSError).domain) \((error as NSError).code))"
        case .unsupportedFormat(let what): return "can't convert to 48 kHz float: \(what)"
        case .convertFailed(let message): return "audio conversion failed: \(message)"
        case .allocFailed: return "could not allocate an audio buffer"
        case .outputExists(let path):
            return "\(path) already exists; name an output path to replace it or to write elsewhere"
        case .outputIsInput(let path): return "the output would replace an input: \(path)"
        case .outputIsDirectory(let path): return "the output is a directory: \(path)"
        case .cancellerUnavailable: return "could not create the echo canceller (WebRTC APM)"
        }
    }
}

func printError(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

/// One decimal, or "-" for no value.
func format(_ value: Double?) -> String {
    value.map { String(format: "%.1f", $0) } ?? "-"
}

func seconds(_ samples: Int) -> Double { Double(samples) / Double(sampleRate) }

/// The running power of a signal, for its level in dBFS.
struct Level {
    private var energy = 0.0
    private(set) var count = 0

    init() {}
    init(_ samples: some Collection<Float>) { add(samples) }

    mutating func add(_ samples: some Collection<Float>) {
        for sample in samples { energy += Double(sample) * Double(sample) }
        count += samples.count
    }

    /// 20·log10(RMS); −200 for silence or no samples.
    var dBFS: Double { count > 0 && energy > 0 ? 10 * log10(energy / Double(count)) : -200 }
}

// MARK: - Audio in and out

/// 48 kHz mono audio, read in chunks of `count` samples (the last may be shorter);
/// nil once it has all been read.
protocol SampleSource: AnyObject {
    func read(_ count: Int) throws -> [Float]?
}

final class ArraySource: SampleSource {
    private let samples: [Float]
    private var position = 0

    init(_ samples: [Float]) { self.samples = samples }

    func read(_ count: Int) -> [Float]? {
        guard position < samples.count else { return nil }
        let end = min(position + count, samples.count)
        defer { position = end }
        return Array(samples[position..<end])
    }
}

/// Streams an audio file as 48 kHz mono, so memory stays flat however long it is. The
/// file is decoded and resampled with AVAudioConverter, keeping its channels, which
/// EchoAudio.monoMix then averages.
final class FileSource: SampleSource {
    /// For the log: the file's channels, rate and length.
    let summary: String

    private let file: AVAudioFile
    private let converter: AVAudioConverter
    private let input: AVAudioPCMBuffer
    private let output: AVAudioPCMBuffer
    private var fileEnded = false
    private var converterEnded = false
    /// Decoded mono samples; those before `position` have been read.
    private var decoded: [Float] = []
    private var position = 0

    init(path: String) throws {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else { throw ProbeError.missingFile(path) }
        do { file = try AVAudioFile(forReading: url) } catch { throw ProbeError.unreadable(path, error) }
        let source = file.processingFormat
        let rate = Double(sampleRate)
        let target = source.channelLayout.map {
            AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, interleaved: false, channelLayout: $0)
        } ?? AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate,
                           channels: source.channelCount, interleaved: false)
        guard let target, let converter = AVAudioConverter(from: source, to: target) else {
            throw ProbeError.unsupportedFormat("\(path): \(source)")
        }
        guard let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: 16_384),
              let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 16_384) else {
            throw ProbeError.allocFailed
        }
        self.converter = converter
        self.input = input
        self.output = output
        summary = String(format: "%d ch, %.0f Hz, %.1f s", source.channelCount, source.sampleRate,
                         Double(file.length) / source.sampleRate)
    }

    func read(_ count: Int) throws -> [Float]? {
        while decoded.count - position < count, !converterEnded { try decode() }
        let available = decoded.count - position
        guard available > 0 else { return nil }
        let end = position + min(count, available)
        defer { position = end }
        return Array(decoded[position..<end])
    }

    /// Converts the next stretch of the file and appends it, mono, to `decoded`.
    private func decode() throws {
        decoded.removeFirst(position)
        position = 0
        output.frameLength = 0
        var readError: Error?
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            do {
                if try self.readBlock() {
                    inputStatus.pointee = .haveData
                    return self.input
                }
            } catch {
                readError = error
            }
            inputStatus.pointee = .endOfStream
            return nil
        }
        if let readError { throw readError }
        switch status {
        case .haveData, .inputRanDry:
            appendMono(output)
            if output.frameLength == 0, fileEnded { converterEnded = true }
        case .endOfStream:
            appendMono(output)
            converterEnded = true
        case .error:
            throw ProbeError.convertFailed(conversionError?.localizedDescription ?? "unknown error")
        @unknown default:
            throw ProbeError.convertFailed("unknown converter status \(status.rawValue)")
        }
    }

    /// Reads the file's next block into `input`; false once the file is used up.
    private func readBlock() throws -> Bool {
        let remaining = file.length - file.framePosition
        guard !fileEnded, remaining > 0 else {
            fileEnded = true
            return false
        }
        do {
            try file.read(into: input, frameCount: AVAudioFrameCount(min(remaining, Int64(input.frameCapacity))))
        } catch let error as NSError
            where error.domain == NSOSStatusErrorDomain && error.code == Int(kAudioFileEndOfFileError) {
            fileEnded = true  // fewer frames than the file's header promised
            return false
        }
        if input.frameLength == 0 { fileEnded = true }
        return !fileEnded
    }

    private func appendMono(_ buffer: AVAudioPCMBuffer) {
        let frames = Int(buffer.frameLength)
        guard frames > 0, let data = buffer.floatChannelData else { return }
        let channels = (0..<Int(buffer.format.channelCount)).map {
            Array(UnsafeBufferPointer(start: data[$0], count: frames))
        }
        decoded += EchoAudio.monoMix(channels)
    }
}

/// Writes 48 kHz mono float as an AAC .m4a, in chunks of any size.
final class TrackWriter {
    private let file: AVAudioFile
    private let buffer: AVAudioPCMBuffer

    init(url: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: Double(sampleRate),
            AVNumberOfChannelsKey: 1,
        ]
        file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        ZMeetPaths.restrictFile(url)  // as private as the recorder's own tracks
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 16_384) else {
            throw ProbeError.allocFailed
        }
        self.buffer = buffer
    }

    func write(_ samples: [Float]) throws {
        guard let channel = buffer.floatChannelData?[0] else { throw ProbeError.allocFailed }
        var start = 0
        while start < samples.count {
            let count = min(Int(buffer.frameCapacity), samples.count - start)
            samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress! + start, count: count) }
            buffer.frameLength = AVAudioFrameCount(count)
            try file.write(from: buffer)
            start += count
        }
    }

    func close() { file.close() }
}

// MARK: - The pipeline

final class ManualClock { var now: TimeInterval = 0 }

/// Prints a row for every 10 s of cleaned mic. The output trails the mic, so each
/// stretch of mic is complete before the matching stretch of output is.
final class RowPrinter {
    private let aligner: EchoAligner
    private let canceller: EchoCanceller
    /// The mic's level over each 10 s, in order.
    private var micStretches: [Level] = []
    private var micCount = 0
    private var outStretch = Level()
    private var outCount = 0
    private(set) var micTotal = Level()
    private(set) var outTotal = Level()

    init(aligner: EchoAligner, canceller: EchoCanceller) {
        self.aligner = aligner
        self.canceller = canceller
    }

    func mic(_ samples: [Float]) {
        micTotal.add(samples)
        var rest = samples[...]
        while !rest.isEmpty {
            if micCount / rowSamples == micStretches.count { micStretches.append(Level()) }
            let part = rest.prefix(rowSamples - micCount % rowSamples)
            micStretches[micStretches.count - 1].add(part)
            micCount += part.count
            rest = rest.dropFirst(part.count)
        }
    }

    func output(_ samples: [Float]) {
        outTotal.add(samples)
        var rest = samples[...]
        while !rest.isEmpty {
            let part = rest.prefix(rowSamples - outCount % rowSamples)
            outStretch.add(part)
            outCount += part.count
            rest = rest.dropFirst(part.count)
            if outCount % rowSamples == 0 { printRow() }
        }
    }

    /// The row for a last stretch shorter than 10 s.
    func finish() {
        if outStretch.count > 0 { printRow() }
    }

    private func printRow() {
        let index = (outCount - 1) / rowSamples
        let mic = index < micStretches.count ? micStretches[index].dBFS : -200
        let out = outStretch.dBFS
        let stats = aligner.stats
        let echo = canceller.statistics  // the row's one read, current as of the latest capture frame
        print("t=\(format(seconds(outCount))) mic=\(format(mic)) out=\(format(out)) reduction=\(format(mic - out))"
              + " lag=\(format(stats.lockedLagMs)) lead=\(format(stats.leadMs))"
              + " erle=\(format(echo.echoReturnLossEnhancementDB)) delay=\(echo.delayMs.map(String.init) ?? "-")")
        outStretch = Level()
    }
}

struct RunResult {
    var micSamples: Int
    var systemSamples: Int
    var mic: Level
    var out: Level
    var aligner: EchoAlignerStats
    var echo: EchoStatistics
}

/// Runs the mic and system audio through the echo pipeline, printing a row for every
/// 10 s of cleaned mic. `output` gets the cleaned mic in order, every sample of it.
func runPipeline(mic: any SampleSource, system: any SampleSource,
                 output: ([Float]) throws -> Void) throws -> RunResult {
    guard let canceller = EchoCanceller() else { throw ProbeError.cancellerUnavailable }
    let clock = ManualClock()
    let aligner = EchoAligner(processor: canceller, now: { clock.now })
    let rows = RowPrinter(aligner: aligner, canceller: canceller)
    func emit(_ cleaned: [Float]) throws {
        guard !cleaned.isEmpty else { return }
        rows.output(cleaned)
        try output(cleaned)
    }

    var micSamples = 0, systemSamples = 0
    var micEnded = false, systemEnded = false
    var index = 0
    while !(micEnded && systemEnded) {
        let pts = Double(index) / Double(sampleRate)
        clock.now = pts
        if !systemEnded {
            if let chunk = try system.read(chunkSize) {
                systemSamples += chunk.count
                aligner.appendRender(chunk, pts: pts)
                try emit(aligner.drainReady())
            } else {
                systemEnded = true
            }
        }
        if !micEnded {
            if let chunk = try mic.read(chunkSize) {
                micSamples += chunk.count
                rows.mic(chunk)
                aligner.appendCapture(chunk, pts: pts)
                try emit(aligner.drainReady())
            } else {
                micEnded = true
            }
        }
        index += chunkSize
    }
    try emit(aligner.flush())
    rows.finish()
    return RunResult(micSamples: micSamples, systemSamples: systemSamples, mic: rows.micTotal,
                     out: rows.outTotal, aligner: aligner.stats, echo: canceller.statistics)
}

func printSummary(_ result: RunResult) {
    let stats = result.aligner
    let echo = result.echo
    print("summary: mic \(format(seconds(result.micSamples))) s, system \(format(seconds(result.systemSamples))) s,"
          + " \(stats.framesProcessed) frames cleaned")
    print("  levels   mic=\(format(result.mic.dBFS)) dBFS out=\(format(result.out.dBFS)) dBFS"
          + " reduction=\(format(result.mic.dBFS - result.out.dBFS)) dB")
    print("  aligner  lead=\(format(stats.leadMs)) ms lag=\(format(stats.lockedLagMs)) ms"
          + " leadChanges=\(stats.leadChanges) owed=\(stats.owedFrames) gaps=\(stats.renderGapFills)"
          + " trims=\(stats.renderTrims) failed=\(stats.failed)")
    print("  aec3     erle=\(format(echo.echoReturnLossEnhancementDB)) dB erl=\(format(echo.echoReturnLossDB)) dB"
          + " delay=\(echo.delayMs.map(String.init) ?? "-") ms")
}

// MARK: - A capture pair

/// Whether both URLs name the same existing file system object, so relative paths and
/// hard links count. Like every URL resource value, a final symlink isn't followed.
func isSameFile(_ a: URL, _ b: URL) -> Bool {
    guard let x = try? a.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier,
          let y = try? b.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier else {
        return false
    }
    return x.isEqual(y)
}

/// Clears the output path, or refuses to: a directory or an input is never replaced, and
/// nothing is when the path was defaulted. A symlink is removed itself, never its target.
func clearOutput(_ url: URL, named: Bool, inputs: [URL]) throws {
    guard let existing = try? url.resourceValues(forKeys: [.isDirectoryKey]) else { return }  // nothing there
    if existing.isDirectory == true { throw ProbeError.outputIsDirectory(url.path) }
    if !named { throw ProbeError.outputExists(url.path) }
    if inputs.contains(where: { isSameFile($0, url) }) { throw ProbeError.outputIsInput(url.path) }
    try FileManager.default.removeItem(at: url)
}

/// Cleans a capture pair into `outputPath` (or mic-clean.m4a next to the mic). Returns the exit status.
func probe(micPath: String, systemPath: String, outputPath: String?) -> Int32 {
    let micURL = URL(fileURLWithPath: micPath)
    let outURL = outputPath.map { URL(fileURLWithPath: $0) }
        ?? micURL.deletingLastPathComponent().appendingPathComponent("mic-clean.m4a")
    var createdOutput = false
    do {
        let mic = try FileSource(path: micPath)
        let system = try FileSource(path: systemPath)
        try clearOutput(outURL, named: outputPath != nil, inputs: [micURL, URL(fileURLWithPath: systemPath)])
        print("mic:    \(micPath) (\(mic.summary))")
        print("system: \(systemPath) (\(system.summary))")

        let writer = try TrackWriter(url: outURL)
        createdOutput = true
        let result = try runPipeline(mic: mic, system: system) { try writer.write($0) }
        writer.close()
        printSummary(result)
        print("wrote \(outURL.path)")
        if result.aligner.failed {
            printError("error: the echo canceller failed; the mic passed through raw from then on")
            return 1
        }
        return 0
    } catch {
        if createdOutput { try? FileManager.default.removeItem(at: outURL) }  // no partial output
        printError("error: \(error)")
        return 1
    }
}

// MARK: - Self-test

/// SplitMix64, as in the test suite: the same seed gives the same signal everywhere.
struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in [0, 1), from the top 53 bits.
    mutating func unit() -> Double { Double(next() >> 11) / Double(UInt64(1) << 53) }
}

/// The test suite's echo signals, rebuilt here because an executable can't import the
/// test target. The same seed gives the same audio as `EchoTestSignals`.
enum Synthetic {
    static let rate = Double(sampleRate)

    /// Uniform noise at −20 dBFS RMS in 300–700 ms bursts with 100–400 ms gaps, each
    /// burst with 10 ms raised-cosine edges.
    static func speechLike(seconds: Double, seed: UInt64) -> [Float] {
        let count = Int((seconds * rate).rounded())
        var out = [Float](repeating: 0, count: count)
        var generator = SplitMix64(seed: seed)
        let amplitude = 0.1 * 3.0.squareRoot()  // uniform on [−a, a] has RMS a/√3; 0.1 is −20 dBFS
        let edge = rate / 100
        var start = 0
        while start < count {
            let burst = Int(((0.3 + 0.4 * generator.unit()) * rate).rounded())
            for i in 0..<burst where start + i < count {
                let ramp = min(1, (Double(i) + 0.5) / edge, (Double(burst - i) - 0.5) / edge)
                let envelope = 0.5 - 0.5 * cos(Double.pi * ramp)
                out[start + i] = Float(envelope * amplitude * (2 * generator.unit() - 1))
            }
            start += burst + Int(((0.1 + 0.3 * generator.unit()) * rate).rounded())
        }
        return out
    }

    /// `x` delayed by `delayMs`, through the room response h[n] = exp(−n / (0.0025·rate))
    /// for n < 0.015·rate, scaled so that sqrt(Σh²) = 10^(gainDB/20).
    static func echo(of x: [Float], delayMs: Double, gainDB: Double) -> [Float] {
        let delay = Int((delayMs * rate / 1_000).rounded())
        let taps = Int((0.015 * rate).rounded())
        let decay = exp(-1 / (0.0025 * rate))
        var energy = 0.0
        for n in 0..<taps { energy += pow(decay, 2 * Double(n)) }
        let scale = pow(10, gainDB / 20) / energy.squareRoot()
        let lastTap = pow(decay, Double(taps))
        // The truncated convolution as a recursion: u[j] = decay·u[j−1] + x[j] − decay^taps·x[j − taps].
        var y = [Float](repeating: 0, count: x.count)
        var u = 0.0
        for n in 0..<x.count where n >= delay {
            let j = n - delay
            u = decay * u + Double(x[j]) - (j >= taps ? lastTap * Double(x[j - taps]) : 0)
            y[n] = Float(scale * u)
        }
        return y
    }

    /// `count` samples, silent except for a sine at `hz` and `dbfs` dBFS RMS over [from, to) seconds.
    static func tone(hz: Double, dbfs: Double, from: Double, to: Double, count: Int) -> [Float] {
        var out = [Float](repeating: 0, count: count)
        let peak = 2.0.squareRoot() * pow(10, dbfs / 20)
        let start = Int(from * rate)
        for n in start..<min(Int(to * rate), count) {
            out[n] = Float(peak * sin(2 * Double.pi * hz * Double(n - start) / rate))
        }
        return out
    }
}

/// A synthetic run with a known answer. Returns the exit status.
func selfTest() -> Int32 {
    let far = Synthetic.speechLike(seconds: 10, seed: 1)
    let near = Synthetic.tone(hz: 1_000, dbfs: -35, from: 8, to: 10, count: far.count)
    let mic = zip(Synthetic.echo(of: far, delayMs: 60, gainDB: -10), near).map { $0 + $1 }
    var out: [Float] = []
    do {
        printSummary(try runPipeline(mic: ArraySource(mic), system: ArraySource(far)) { out += $0 })
    } catch {
        printError("error: \(error)")
        return 1
    }
    guard out.count == mic.count else {
        printError("error: the pipeline returned \(out.count) samples for \(mic.count)")
        return 1
    }
    func level(_ x: [Float], _ from: Double, _ to: Double) -> Double {
        Level(x[Int(from * Synthetic.rate)..<Int(to * Synthetic.rate)]).dBFS
    }
    // Over 4–8 s the mic is echo alone. Over 8.5–10 s the cleaned mic is set against the
    // near end alone, while the echo goes on (double talk).
    let reduction = level(mic, 4, 8) - level(out, 4, 8)
    let change = level(out, 8.5, 10) - level(near, 8.5, 10)
    print(String(format: "selftest: echo reduction %.1f dB (4–8 s), near-end change %+.1f dB (8.5–10 s)",
                 reduction, change))
    guard reduction >= 25, abs(change) <= 6 else {
        print("selftest: FAIL (needs an echo reduction ≥ 25 dB and a near-end change within ±6 dB)")
        return 1
    }
    print("selftest: pass")
    return 0
}

// MARK: - Main

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments == ["--selftest"] {
    exit(selfTest())
}
if arguments == ["-h"] || arguments == ["--help"] {
    print(usage)
    exit(0)
}
guard (2...3).contains(arguments.count), !arguments.contains(where: { $0.hasPrefix("-") }) else {
    printError(usage)
    exit(2)
}
exit(probe(micPath: arguments[0], systemPath: arguments[1], outputPath: arguments.count == 3 ? arguments[2] : nil))
