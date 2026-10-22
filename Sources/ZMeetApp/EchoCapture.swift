import AVFoundation
import CoreMedia
import Foundation
import ZMeetCore

/// One recording's echo pipeline. Confined to SCKAudioRecorder.queue — never touch it from another thread.
///
/// The system audio is AEC3's reference and the mic is what gets cleaned. Both arrive
/// canonical (48 kHz, 2 channels, non-interleaved float) and run mono
/// (`EchoAudio.monoMix`) through `EchoAligner` and `EchoCanceller`. The cleaned mic comes
/// back canonical, with the mono in both channels. A mic frame waits for its reference
/// (up to the aligner's hold), so the cleaned mic comes out later than the raw mic went
/// in. To keep that wait out of the mix, the recorder keeps each of its players
/// `primingFrames` ahead of what it plays, the mic player less the mic's wait
/// (`micTargetFrames`). It measures each player's queue from the player's own position
/// (`PlaybackQueueController`), so both streams play the priming after they arrived
/// through gaps, stalls and clock drift too.
///
/// Logs `echo: on …` at creation, a stats line every 30 s while handling input, one line
/// if the canceller fails (the raw mic passes through from then on), and `echo: final …`
/// at `finish()`. Given a debug folder, it also writes the raw mic, the system audio and
/// the cleaned mic there (`EchoDebugTracks`).
final class EchoCapture {
    /// How long after it arrived each stream plays in the mix while the pipeline runs: what
    /// each player is kept ahead of what it plays. Longer than the aligner's longest hold
    /// (250 ms), so held mic still reaches its player in time.
    static let primingMs = 300
    static let primingFrames = AVAudioFrameCount(primingMs * EchoCanceller.sampleRate / 1_000)

    private static let statsInterval: TimeInterval = 30

    private let canonical: AVAudioFormat
    private let canceller: EchoCanceller
    private let aligner: EchoAligner
    private let clock: () -> TimeInterval
    private let log: (String) -> Void
    private var debug: EchoDebugTracks?
    private var lastStatsLog: TimeInterval
    private var loggedFailure = false

    init?(canonical: AVAudioFormat, debugFolder: URL?, log: @escaping (String) -> Void) {
        guard let canceller = EchoCanceller() else { return nil }
        let clock: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
        let config = EchoAlignerConfig()
        self.canonical = canonical
        self.canceller = canceller
        aligner = EchoAligner(config: config, processor: canceller, now: clock)
        self.clock = clock
        self.log = log
        lastStatsLog = clock()
        log("echo: on (lead \(Int(config.initialLeadMs)) ms, hold \(Int(config.maxHoldMs)) ms, priming \(Self.primingMs) ms)")
        if let debugFolder { debug = EchoDebugTracks(folder: debugFolder, format: canonical, log: log) }
    }

    /// System audio, canonical: feeds the reference. Returns the cleaned mic it released, if any.
    func system(_ buffer: AVAudioPCMBuffer, pts: CMTime) -> AVAudioPCMBuffer? {
        let seconds = Self.seconds(pts)
        debug?.system(buffer, pts: seconds)
        if let mono = Self.mono(buffer) { aligner.appendRender(mono, pts: seconds) }
        return release(aligner.drainReady())
    }

    /// The mic, canonical: feeds the capture side. Returns the cleaned mic ready now, if any.
    func microphone(_ buffer: AVAudioPCMBuffer, pts: CMTime) -> AVAudioPCMBuffer? {
        let seconds = Self.seconds(pts)
        debug?.microphone(buffer, pts: seconds)
        if let mono = Self.mono(buffer) { aligner.appendCapture(mono, pts: seconds) }
        return release(aligner.drainReady())
    }

    /// What the mic player should have queued when the cleaned mic just returned goes in:
    /// the priming less how long that mic's first frame waited in the aligner, so it plays
    /// the priming after it arrived, as the system audio does. Read it right after
    /// `system(_:pts:)`, `microphone(_:pts:)` or `finish()` returns cleaned mic.
    var micTargetFrames: Int {
        let priming = Double(Self.primingFrames)
        let held = min(aligner.lastReleaseHoldSeconds * Double(EchoCanceller.sampleRate), priming)
        return Int((priming - held).rounded())
    }

    /// The end of the recording: every mic sample still held, cleaned with whatever
    /// reference arrived (silence where none did), then the final stats line. Feed
    /// nothing after this.
    func finish() -> AVAudioPCMBuffer? {
        let tail = output(aligner.flush())
        noteFailure()
        if let tail { debug?.cleaned(tail) }
        debug?.finish()
        debug = nil
        log("echo: final " + statsLine())
        return tail
    }

    // MARK: - Pipeline

    /// Hands back cleaned mic, after the failure check and the 30 s stats line.
    private func release(_ cleaned: [Float]) -> AVAudioPCMBuffer? {
        noteFailure()
        let now = clock()
        if now - lastStatsLog >= Self.statsInterval {
            lastStatsLog = now
            log("echo: " + statsLine())
        }
        let out = output(cleaned)
        if let out { debug?.cleaned(out) }
        return out
    }

    /// Logs, once, that the canceller failed; the aligner passes the raw mic through from then on.
    private func noteFailure() {
        guard aligner.stats.failed, !loggedFailure else { return }
        loggedFailure = true
        log("echo: canceller failed — raw mic for the rest of this recording")
    }

    /// `erle=… dB delay=… ms lag=… ms lead=… ms owed=… gaps=… trims=… moves=… leadChanges=… failed=…`,
    /// with `-` where AEC3 or the lag tracker has no value. The AEC3 numbers are current as of
    /// the latest capture frame.
    private func statsLine() -> String {
        let echo = canceller.statistics
        let stats = aligner.stats
        return "erle=\(Self.format(echo.echoReturnLossEnhancementDB)) dB"
            + " delay=\(echo.delayMs.map(String.init) ?? "-") ms"
            + " lag=\(Self.format(stats.lockedLagMs)) ms lead=\(Self.format(stats.leadMs)) ms"
            + " owed=\(stats.owedFrames) gaps=\(stats.renderGapFills) trims=\(stats.renderTrims)"
            + " moves=\(stats.referenceMoves) leadChanges=\(stats.leadChanges) failed=\(stats.failed)"
    }

    // MARK: - Conversion

    /// A canonical buffer's channels averaged to mono, the downmix APM itself uses.
    private static func mono(_ buffer: AVAudioPCMBuffer) -> [Float]? {
        guard !buffer.format.isInterleaved, let data = buffer.floatChannelData, buffer.frameLength > 0 else { return nil }
        let frames = Int(buffer.frameLength)
        let channels = (0..<Int(buffer.format.channelCount)).map {
            Array(UnsafeBufferPointer(start: data[$0], count: frames))
        }
        return EchoAudio.monoMix(channels)
    }

    /// Cleaned mono as a canonical buffer with the same samples in each channel; nil for none.
    private func output(_ mono: [Float]) -> AVAudioPCMBuffer? {
        guard !mono.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: canonical, frameCapacity: AVAudioFrameCount(mono.count)),
              let data = buffer.floatChannelData else { return nil }
        buffer.frameLength = AVAudioFrameCount(mono.count)
        mono.withUnsafeBufferPointer { samples in
            for channel in 0..<Int(canonical.channelCount) {
                data[channel].update(from: samples.baseAddress!, count: samples.count)
            }
        }
        return buffer
    }

    /// The PTS in seconds; nil when it's invalid or not finite, and placement then falls
    /// back to sample counts.
    private static func seconds(_ pts: CMTime) -> TimeInterval? {
        guard pts.isValid else { return nil }
        let seconds = pts.seconds
        return seconds.isFinite ? seconds : nil
    }

    private static func format(_ value: Double?) -> String {
        value.map { String(format: "%.1f", $0) } ?? "-"
    }
}

/// The echo-debug tracks `mic-raw.m4a`, `system.m4a` and `mic-clean.m4a`: what the pipeline
/// was given and the mic it made, on the aligner's timeline. That is what `aec-probe`
/// expects, since it reads the raw tracks as starting together and running contiguously.
///
/// Sample 0 of each track is the first PTS either stream showed. The mic tracks start
/// where the mic does and run contiguously, as the aligner treats the mic. Each system
/// buffer goes where the aligner places its reference: by its PTS against the latest mic
/// PTS, with a gap of more than 2 ms filled with silence and an overlap of more than
/// 2 ms trimmed. After a mic PTS jump (`moves` in the stats line) the aligner also moves
/// the reference it already holds, which a written track can't do, so an offline replay
/// differs from the live run for as long as the jump after it.
///
/// Best-effort: a track that can't be created or written is logged and dropped.
private final class EchoDebugTracks {
    /// `EchoAlignerConfig.placementToleranceMs` (2 ms) in frames: a PTS difference this
    /// small is left alone, as the aligner leaves it.
    private static let tolerance = Int((EchoAlignerConfig().placementToleranceMs * Double(EchoCanceller.sampleRate) / 1_000).rounded())

    private var micRawTrack: DebugTrack?
    private var systemTrack: DebugTrack?
    private var micCleanTrack: DebugTrack?
    /// The first PTS either stream showed: index 0.
    private var origin: TimeInterval?
    /// The index after the last raw mic sample; nil until the mic starts.
    private var micEnd: Int?
    /// The latest mic buffer with a PTS: that PTS and the index of its first sample.
    private var micAnchor: (pts: TimeInterval, index: Int)?
    /// The index of the next cleaned sample, which is the raw sample it came from.
    private var cleanedEnd = 0
    private var systemStarted = false

    init?(folder: URL, format: AVAudioFormat, log: @escaping (String) -> Void) {
        do {
            try ZMeetPaths.ensurePrivateDirectory(folder)
        } catch {
            log("echo: debug tracks unavailable: \(error.localizedDescription)")
            return nil
        }
        micRawTrack = DebugTrack(url: folder.appendingPathComponent("mic-raw.m4a"), format: format, log: log)
        systemTrack = DebugTrack(url: folder.appendingPathComponent("system.m4a"), format: format, log: log)
        micCleanTrack = DebugTrack(url: folder.appendingPathComponent("mic-clean.m4a"), format: format, log: log)
        log("echo: debug tracks in \(folder.lastPathComponent)/")
    }

    func system(_ buffer: AVAudioPCMBuffer, pts: TimeInterval?) {
        guard let track = systemTrack else { return }
        var start = target(pts) ?? track.end
        if systemStarted, abs(start - track.end) <= Self.tolerance { start = track.end }
        systemStarted = true
        track.place(buffer, at: start)
    }

    func microphone(_ buffer: AVAudioPCMBuffer, pts: TimeInterval?) {
        if let pts, origin == nil { origin = pts }
        let first: Int
        if let micEnd {
            first = micEnd
        } else {
            if let pts, let origin { first = Self.samples(seconds: pts - origin) ?? 0 } else { first = 0 }
            cleanedEnd = first
        }
        if let pts { micAnchor = (pts, first) }
        micEnd = first + Int(buffer.frameLength)
        micRawTrack?.place(buffer, at: first)
    }

    func cleaned(_ buffer: AVAudioPCMBuffer) {
        micCleanTrack?.place(buffer, at: cleanedEnd)
        cleanedEnd += Int(buffer.frameLength)
    }

    /// Writes what's still waiting and closes the files.
    func finish() {
        for track in [micRawTrack, systemTrack, micCleanTrack] { track?.close() }
        micRawTrack = nil
        systemTrack = nil
        micCleanTrack = nil
    }

    /// Where system audio with this PTS starts, as `EchoAligner` places it; nil without a PTS.
    private func target(_ pts: TimeInterval?) -> Int? {
        guard let pts else { return nil }
        let origin = self.origin ?? pts
        self.origin = origin
        let anchor = micAnchor ?? (pts: origin, index: 0)
        return Self.samples(seconds: pts - anchor.pts).map { anchor.index + $0 }
    }

    /// round(seconds · 48 000), or nil past 2^53 samples, as the aligner rounds.
    private static func samples(seconds: TimeInterval) -> Int? {
        let count = (seconds * Double(EchoCanceller.sampleRate)).rounded()
        guard abs(count) <= 9_007_199_254_740_992 else { return nil }
        return Int(count)
    }
}

/// One echo-debug file, written in timeline order. A gap is filled with silence at most a
/// second per call, with the audio after it waiting in order, so a long gap never holds
/// up the capture queue; `close()` writes the rest.
private final class DebugTrack {
    /// The longest gap filled with silence. A PTS jump past it is more likely corrupt than
    /// real, so the track ends there instead of growing by hours of silence.
    private static let maxGapFrames = 10 * 60 * EchoCanceller.sampleRate
    private static let silencePerCall = EchoCanceller.sampleRate

    private enum Piece {
        case silence(Int)
        case audio(AVAudioPCMBuffer)
    }

    private let name: String
    private let log: (String) -> Void
    private let silence: AVAudioPCMBuffer
    private var file: AVAudioFile?
    /// Placed but not yet written, oldest first.
    private var waiting: [Piece] = []
    /// The timeline index after everything placed so far.
    private(set) var end = 0

    init?(url: URL, format: AVAudioFormat, log: @escaping (String) -> Void) {
        name = url.lastPathComponent
        self.log = log
        guard let silence = AVAudioPCMBuffer.silence(format, frames: 4_800) else { return nil }
        self.silence = silence
        do {
            file = try AVAudioFile(forWriting: url, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: format.sampleRate,
                AVNumberOfChannelsKey: format.channelCount,
                AVEncoderBitRateKey: 128_000,
            ])
            ZMeetPaths.restrictFile(url)
        } catch {
            log("echo: debug \(name) unavailable: \(error.localizedDescription)")
            return nil
        }
    }

    /// Places `buffer` with its first frame at timeline index `start`: a gap before it
    /// becomes silence, and frames before the track's end (or before index 0) are dropped.
    func place(_ buffer: AVAudioPCMBuffer, at start: Int) {
        guard file != nil else { return }
        if start > end {
            guard start - end <= Self.maxGapFrames else {
                log(String(format: "echo: debug %@ ended at a %.0f s jump in its timestamps",
                           name, Double(start - end) / Double(EchoCanceller.sampleRate)))
                close()
                return
            }
            waiting.append(.silence(start - end))
            end = start
        }
        let frames = Int(buffer.frameLength)
        let skip = end - start
        guard skip < frames else { return }
        guard let kept = skip == 0 ? buffer : buffer.copy(frames: skip..<frames) else { return }
        waiting.append(.audio(kept))
        end += frames - skip
        writeWaiting(silenceBudget: Self.silencePerCall)
    }

    func close() {
        writeWaiting(silenceBudget: .max)
        file = nil
        waiting.removeAll()
    }

    /// Writes waiting pieces in order, at most `silenceBudget` frames of silence.
    private func writeWaiting(silenceBudget: Int) {
        var budget = silenceBudget
        while let piece = waiting.first, file != nil {
            switch piece {
            case .audio(let buffer):
                guard write(buffer) else { return }
                waiting.removeFirst()
            case .silence(let count):
                guard budget > 0 else { return }
                let chunk = min(count, budget, Int(silence.frameCapacity))
                silence.frameLength = AVAudioFrameCount(chunk)
                guard write(silence) else { return }
                budget -= chunk
                if chunk == count { waiting.removeFirst() } else { waiting[0] = .silence(count - chunk) }
            }
        }
    }

    private func write(_ buffer: AVAudioPCMBuffer) -> Bool {
        do {
            try file?.write(from: buffer)
            return true
        } catch {
            log("echo: debug \(name) write failed, dropping it: \(error.localizedDescription)")
            file = nil
            waiting.removeAll()
            return false
        }
    }
}

extension AVAudioPCMBuffer {
    /// `frames` of silence in `format`, a non-interleaved float format; nil if the buffer can't be made.
    static func silence(_ format: AVAudioFormat, frames: AVAudioFrameCount) -> AVAudioPCMBuffer? {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let data = buffer.floatChannelData else { return nil }
        buffer.frameLength = frames
        for channel in 0..<Int(format.channelCount) {
            data[channel].update(repeating: 0, count: Int(frames))
        }
        return buffer
    }

    /// A copy of the frames in `range` (a non-interleaved float buffer); nil if the range is
    /// empty or out of bounds, or the copy can't be made.
    fileprivate func copy(frames range: Range<Int>) -> AVAudioPCMBuffer? {
        guard range.lowerBound >= 0, range.upperBound <= Int(frameLength), !range.isEmpty,
              let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(range.count)),
              let source = floatChannelData, let destination = copy.floatChannelData else { return nil }
        copy.frameLength = AVAudioFrameCount(range.count)
        for channel in 0..<Int(format.channelCount) {
            destination[channel].update(from: source[channel] + range.lowerBound, count: range.count)
        }
        return copy
    }
}
