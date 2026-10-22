import Foundation
import AVFoundation
import CoreMedia
import ScreenCaptureKit
import ZMeetCore
import os

/// Captures system audio + microphone via one SCStream (macOS 15+), normalizes
/// both to a canonical PCM format, mixes them through an AVAudioEngine, and
/// writes the mix to an AAC `.m4a`. The main mixer is muted so nothing plays
/// back to the speakers (no feedback); a capture mixer is tapped at full level.
final class SCKAudioRecorder: NSObject, MeetingRecorder, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private var stream: SCStream?
    private let engine = AVAudioEngine()
    private let systemPlayer = AVAudioPlayerNode()
    private let micPlayer = AVAudioPlayerNode()
    private let captureMixer = AVAudioMixerNode()
    // All mutable state below is confined to `queue` after start().
    private var audioFile: AVAudioFile?
    private var micFile: AVAudioFile?
    private var systemFile: AVAudioFile?
    private var logHandle: FileHandle?
    private var startTask: Task<Void, Never>?
    private let queue = DispatchQueue(label: "edu.umontana.zmeet.capture")
    private static let queueKey = DispatchSpecificKey<Void>()
    /// Whether a capture failure has already been reported for the current
    /// recording. Confined to `queue`, like the other mutable state.
    private var didReportFailure = false
    /// Whether `stop()` is currently tearing down capture. Confined to `queue`.
    /// Suppresses failure reports that race an intentional stop (e.g. SCK
    /// delivering `didStopWithError` as a side effect of our own teardown)
    /// without suppressing a genuine mid-recording death, since that path
    /// reports before `stop()` is ever called.
    private var isStopping = false
    /// This recording's echo pipeline: nil when echo cancellation is off, isn't
    /// needed (mic or system audio not captured) or couldn't start. Confined to
    /// `queue`, like the other mutable state.
    private var echo: EchoCapture?
    /// Each player's fill controller while the echo pipeline runs; nil otherwise, when each
    /// player plays its audio as it comes. With the pipeline, the mic waits up to 250 ms for
    /// its reference before it reaches the mic player. So before each buffer goes to a
    /// player, its controller measures what the player still has queued, counted from the
    /// player's own position, and tops it up with silence to its target:
    /// `EchoCapture.primingFrames` (300 ms) on the system player, that less the mic's wait on
    /// the mic player (`EchoCapture.micTargetFrames`). Both streams then play 300 ms after
    /// they arrived, so they stay as aligned in the mix as without echo cancellation, through
    /// gaps in either stream, stalls, a player that ran dry and a clock slower than the
    /// output's. The silence goes to the players only: `mic.m4a` and `system.m4a` get their
    /// audio as without echo cancellation. Confined to `queue`.
    private var systemPlayerFill: PlaybackQueueController?
    private var micPlayerFill: PlaybackQueueController?
    var onCaptureFailure: (@Sendable (String) -> Void)?

    private let canonical = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 48_000,
        channels: 2,
        interleaved: false
    )!
    private var systemConverter: AVAudioConverter?
    private var micConverter: AVAudioConverter?

    /// Render-side backpressure for mixed-file writes handed to `queue`: a
    /// stalled disk must never block the real-time thread, so past the cap we
    /// drop the incoming buffer (newest) (drops are counted and logged at
    /// stop). 64 × 4096 frames ≈ 5.5 s of audio in flight at 48 kHz before
    /// dropping.
    private let mixWriteBackpressure = OSAllocatedUnfairLock(initialState: MixWriteBackpressure(capacity: 64))

    override init() {
        super.init()
        queue.setSpecific(key: Self.queueKey, value: ())
    }

    func start(to url: URL, logURL: URL, audio: AudioConfig) throws {
        queue.sync { didReportFailure = false; isStopping = false }
        mixWriteBackpressure.withLock { $0.reset() }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        ZMeetPaths.restrictFile(logURL)
        logHandle = try? FileHandle(forWritingTo: logURL)
        log("start \(url.lastPathComponent)")

        do {
            audioFile = try AVAudioFile(forWriting: url, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: canonical.sampleRate,
                AVNumberOfChannelsKey: canonical.channelCount,
                AVEncoderBitRateKey: audio.bitrate
            ])
            ZMeetPaths.restrictFile(url)

            if audio.separateTracks {
                let folder = url.deletingLastPathComponent()
                let trackSettings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: canonical.sampleRate,
                    AVNumberOfChannelsKey: canonical.channelCount,
                    AVEncoderBitRateKey: audio.bitrate,
                ]
                // Best-effort: a track-file failure must never abort the recording.
                micFile = try? AVAudioFile(forWriting: folder.appendingPathComponent("mic.m4a"), settings: trackSettings)
                systemFile = try? AVAudioFile(forWriting: folder.appendingPathComponent("system.m4a"), settings: trackSettings)
                if micFile != nil { ZMeetPaths.restrictFile(folder.appendingPathComponent("mic.m4a")) }
                if systemFile != nil { ZMeetPaths.restrictFile(folder.appendingPathComponent("system.m4a")) }
                log("separate tracks: mic=\(micFile != nil) system=\(systemFile != nil)")
            }

            engine.attach(systemPlayer)
            engine.attach(micPlayer)
            engine.attach(captureMixer)
            engine.connect(systemPlayer, to: captureMixer, format: canonical)
            engine.connect(micPlayer, to: captureMixer, format: canonical)
            engine.connect(captureMixer, to: engine.mainMixerNode, format: canonical)
            engine.mainMixerNode.outputVolume = 0  // prevent speaker feedback

            let tapFile = audioFile   // captured by value; tap never reads self's mutable state
            captureMixer.installTap(onBus: 0, bufferSize: 4096, format: canonical) { [weak self] buffer, _ in
                guard let self, let tapFile, buffer.frameLength > 0 else { return }
                // Render thread: copy + enqueue only. Encoding and I/O happen on `queue`.
                let admitted = self.mixWriteBackpressure.withLock { $0.admit() }
                guard admitted, let copy = Self.copyBuffer(buffer) else {
                    if !admitted { return }
                    // Copy failed after admission: release the slot and count it
                    // as a drop, same as backpressure rejection.
                    self.mixWriteBackpressure.withLock { $0.releaseDropping() }
                    return
                }
                self.queue.async {
                    defer { self.mixWriteBackpressure.withLock { $0.release() } }
                    do { try tapFile.write(from: copy) } catch { self.log("write error: \(error)") }
                }
            }

            try engine.start()
        } catch {
            rollbackFailedStart()
            throw error
        }

        startEcho(audio: audio, meetingFolder: url.deletingLastPathComponent())

        systemPlayer.play()
        micPlayer.play()
        // Mic-only pre-mix gain (1.0 = unchanged). Scales just the mic node's
        // contribution into the capture mixer; system audio is unaffected.
        micPlayer.volume = audio.micGain

        startTask = Task {
            do { try await self.startStream(audio: audio) }
            catch {
                self.log("stream start error: \(error)")
                self.reportCaptureFailure("Could not start audio capture: \(error.localizedDescription)")
            }
        }
    }

    /// Rolls back a partially-completed start(): tears down whatever was set up
    /// so the next start() begins from a clean engine. Safe to call when the
    /// engine never started (removeTap/stop/detach are no-ops or harmless then).
    private func rollbackFailedStart() {
        captureMixer.removeTap(onBus: 0)
        engine.stop()
        engine.detach(systemPlayer)
        engine.detach(micPlayer)
        engine.detach(captureMixer)
        queue.sync {
            echo = nil
            systemPlayerFill = nil
            micPlayerFill = nil
            systemConverter = nil
            micConverter = nil
            audioFile = nil
            micFile = nil
            systemFile = nil
            try? logHandle?.close()
            logHandle = nil
        }
    }

    /// Sets up this recording's echo pipeline and its players' fill controllers, on `queue`.
    /// It runs only when echo cancellation is on and both the mic and the system audio are
    /// captured; otherwise the mic path is today's. With the `ZMeetEchoDebugTracks`
    /// default set, it also writes `<meeting folder>/echo-debug/` tracks for tuning.
    private func startEcho(audio: AudioConfig, meetingFolder: URL) {
        let active = audio.echoCancellation && audio.captureMicrophone && audio.captureSystemAudio
        let debugFolder = UserDefaults.standard.bool(forKey: "ZMeetEchoDebugTracks")
            ? meetingFolder.appendingPathComponent("echo-debug") : nil
        queue.sync {
            echo = nil
            systemPlayerFill = nil
            micPlayerFill = nil
            guard active else {
                log(audio.echoCancellation ? "echo: off (needs both the mic and system audio)" : "echo: off (turned off in Settings)")
                return
            }
            echo = EchoCapture(canonical: canonical, debugFolder: debugFolder, log: { [weak self] in self?.log($0) })
            guard echo != nil else {
                log("echo: unavailable — raw mic")
                return
            }
            systemPlayerFill = PlaybackQueueController()
            micPlayerFill = PlaybackQueueController()
        }
    }

    private func startStream(audio: AudioConfig) async throws {
        let content = try await SCShareableContent.current
        guard let display = content.displays.first else {
            log("no display available")
            throw CaptureError.noDisplay
        }
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])

        let config = SCStreamConfiguration()
        config.capturesAudio = audio.captureSystemAudio
        config.sampleRate = Int(canonical.sampleRate)
        config.channelCount = 2
        config.captureMicrophone = audio.captureMicrophone
        if let micID = audio.micDeviceID {
            config.microphoneCaptureDeviceID = micID
            log("mic device: \(micID)")
        }
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        if audio.captureMicrophone {
            try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: queue)
        }
        guard !Task.isCancelled else { return }
        self.stream = stream
        try await stream.startCapture()
        if Task.isCancelled { try? await stream.stopCapture(); self.stream = nil; return }
        log("capture started (system=\(audio.captureSystemAudio) mic=\(audio.captureMicrophone))")
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        log("stream stopped with error: \(error)")
        reportCaptureFailure("Audio capture stopped unexpectedly: \(error.localizedDescription)")
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid, sampleBuffer.numSamples > 0,
              let pcm = Self.pcmBuffer(from: sampleBuffer) else { return }
        switch type {
        case .audio:
            if let out = convert(pcm, using: &systemConverter, label: "system") {
                if let systemFile { try? systemFile.write(from: out) }
                schedule(out, on: systemPlayer, through: &systemPlayerFill, target: Int(EchoCapture.primingFrames))
                // The system audio is also the canceller's reference; it can release held mic.
                if let cleaned = echo?.system(out, pts: sampleBuffer.presentationTimeStamp) { emitMic(cleaned) }
            }
        case .microphone:
            if let out = convert(pcm, using: &micConverter, label: "mic") {
                if let echo {
                    // Held until its reference arrives, then cleaned; the raw mic isn't played.
                    if let cleaned = echo.microphone(out, pts: sampleBuffer.presentationTimeStamp) { emitMic(cleaned) }
                } else {
                    emitMic(out)
                }
            }
        default:
            break
        }
    }

    /// The mic's way into the recording: `mic.m4a` when separate tracks are on, then the mix.
    /// While the echo pipeline runs, the mic player is kept the priming less this mic's wait
    /// ahead of what it plays (`EchoCapture.micTargetFrames`).
    private func emitMic(_ buffer: AVAudioPCMBuffer) {
        if let micFile { try? micFile.write(from: buffer) }
        schedule(buffer, on: micPlayer, through: &micPlayerFill, target: echo?.micTargetFrames ?? 0)
    }

    /// Queues `buffer` on `player`. While the echo pipeline runs (`fill` isn't nil), the
    /// silence `fill` asks for goes in first, so that `player` has `target` frames queued
    /// ahead of the buffer, counted from the player's position as of its last render.
    private func schedule(_ buffer: AVAudioPCMBuffer, on player: AVAudioPlayerNode,
                          through fill: inout PlaybackQueueController?, target: Int) {
        if let silence = fill?.silenceBefore(frames: Int(buffer.frameLength), nowFrames: Self.position(of: player),
                                             targetFrames: target),
           silence > 0, let gap = AVAudioPCMBuffer.silence(canonical, frames: AVAudioFrameCount(silence)) {
            player.scheduleBuffer(gap, completionHandler: nil)
        }
        player.scheduleBuffer(buffer, completionHandler: nil)
    }

    /// `player`'s sample position as of its last render; nil before its first render.
    private static func position(of player: AVAudioPlayerNode) -> Int64? {
        guard let rendered = player.lastRenderTime,
              let time = player.playerTime(forNodeTime: rendered), time.isSampleTimeValid else { return nil }
        return time.sampleTime
    }

    private func convert(_ input: AVAudioPCMBuffer, using converter: inout AVAudioConverter?, label: String) -> AVAudioPCMBuffer? {
        if input.format == canonical { return input }
        if let existing = converter, existing.inputFormat != input.format {
            log("\(label) input format changed \(existing.inputFormat) -> \(input.format); rebuilding converter")
            converter = nil
        }
        if converter == nil {
            converter = AVAudioConverter(from: input.format, to: canonical)
            log("\(label) converter: \(input.format) -> canonical")
        }
        guard let conv = converter else { return nil }
        let ratio = canonical.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: canonical, frameCapacity: capacity) else { return nil }
        var error: NSError?
        let state = ConverterFeedState()
        conv.convert(to: out, error: &error) { _, status in
            if state.consumed {
                status.pointee = .noDataNow
                return nil
            }
            state.consumed = true
            status.pointee = .haveData
            return input
        }
        if let error {
            log("\(label) convert error: \(error)")
            return nil
        }
        return out.frameLength > 0 ? out : nil
    }

    func stop() async throws -> RecorderStopDiagnostics {
        // Set before anything else so a capture-failure report racing this stop
        // (e.g. `didStopWithError` firing from SCK's own teardown) is suppressed
        // instead of misreporting an intentional stop as a failure.
        queue.sync { isStopping = true }
        log("stop")
        // The unstructured start Task may still be mid-setup (e.g. awaiting
        // SCShareableContent.current); cancel and await it before touching
        // `stream` so a late `self.stream = stream` can never land after teardown.
        startTask?.cancel()
        await startTask?.value
        startTask = nil
        if let stream {
            // A stopCapture failure can leave the file truncated; log it for the
            // session-recovery diagnostics but still tear down so the engine is
            // left in a clean state for the next recording.
            do { try await stream.stopCapture() }
            catch { log("stopCapture failed: \(error)") }
        }
        stream = nil
        // Barrier: all queued sample callbacks/log writes finish before teardown.
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            queue.async { cont.resume() }
        }
        // The mic the echo pipeline still holds goes to the mic player and mic.m4a.
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            queue.async {
                if let tail = self.echo?.finish() { self.emitMic(tail) }
                self.echo = nil
                self.logPlayerFill()
                self.systemPlayerFill = nil
                self.micPlayerFill = nil
                cont.resume()
            }
        }
        // What the players still have queued (with the echo pipeline, up to 300 ms each, and
        // that tail) plays through the capture mixer before the tap that writes the mix comes off.
        await drainPlayers()
        captureMixer.removeTap(onBus: 0)
        systemPlayer.stop()
        micPlayer.stop()
        engine.stop()
        // Detach the nodes so the next recording's start() can re-attach cleanly.
        // Without this, re-attaching already-attached nodes can crash on a second
        // recording (the recorder instance is reused for the app's lifetime).
        engine.detach(systemPlayer)
        engine.detach(micPlayer)
        engine.detach(captureMixer)
        var dropped = 0
        queue.sync {
            systemConverter = nil
            micConverter = nil
            audioFile = nil  // closes/finalizes the file
            micFile = nil       // finalize/close the track files
            systemFile = nil
            dropped = mixWriteBackpressure.withLock { $0.dropped }
            if dropped > 0 { logHandle?.write(Data("[\(Date())] dropped \(dropped) mix buffers (slow disk)\n".utf8)) }
            try? logHandle?.close()
            logHandle = nil
        }
        return RecorderStopDiagnostics(droppedMixBuffers: dropped)
    }

    /// At stop, after `echo: final`: how many times each player's queue was topped up with
    /// silence, and how much went in, the priming included. On queue.
    private func logPlayerFill() {
        guard let systemPlayerFill, let micPlayerFill else { return }
        func fill(_ controller: PlaybackQueueController) -> String {
            "\(controller.insertions) (\(controller.insertedFrames * 1_000 / Int64(EchoCanceller.sampleRate)) ms)"
        }
        log("echo: player fill system=\(fill(systemPlayerFill)) mic=\(fill(micPlayerFill))")
    }

    /// The silent buffer each player gets at stop: 100 ms, at least a block of the capture
    /// mixer's tap (it asks for 4 096 frames), so the block holding the end of the
    /// recording fills and is written before the tap comes off.
    private static let drainMarkerFrames: AVAudioFrameCount = 4_800

    /// Waits until both players have played everything scheduled on them: a
    /// `drainMarkerFrames` silent buffer goes on each with `.dataPlayedBack`, and this
    /// returns once both have played back, or after `timeout`. Skipped when the engine
    /// isn't running, since then nothing would play.
    private func drainPlayers(timeout: TimeInterval = 2) async {
        guard engine.isRunning else {
            log("stop: engine not running, players not drained")
            return
        }
        let players = [systemPlayer, micPlayer]
        let markers = players.compactMap { _ in AVAudioPCMBuffer.silence(canonical, frames: Self.drainMarkerFrames) }
        guard markers.count == players.count else { return }
        let drained = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            let gate = DrainGate(count: players.count, continuation: cont)
            for (player, marker) in zip(players, markers) {
                player.scheduleBuffer(marker, completionCallbackType: .dataPlayedBack) { _ in gate.arrive() }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { gate.expire() }
        }
        if !drained { log("stop: players didn't drain within \(Int(timeout)) s") }
    }

    /// Copies a canonical-format buffer so the render thread can hand it off
    /// without sharing memory with the engine's tap buffer.
    private static func copyBuffer(_ src: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: src.format, frameCapacity: src.frameLength) else { return nil }
        copy.frameLength = src.frameLength
        let channels = Int(src.format.channelCount)
        guard let srcData = src.floatChannelData, let dstData = copy.floatChannelData else { return nil }
        for ch in 0..<channels {
            memcpy(dstData[ch], srcData[ch], Int(src.frameLength) * MemoryLayout<Float>.size)
        }
        return copy
    }

    private static func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let formatDesc = sampleBuffer.formatDescription,
              let asbd = formatDesc.audioStreamBasicDescription else { return nil }
        var asbdVar = asbd
        guard let format = AVAudioFormat(streamDescription: &asbdVar) else { return nil }
        let frames = AVAudioFrameCount(sampleBuffer.numSamples)
        guard frames > 0, let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        pcm.frameLength = frames
        do {
            try sampleBuffer.copyPCMData(fromRange: 0..<Int(frames), into: pcm.mutableAudioBufferList)
        } catch {
            return nil
        }
        return pcm
    }

    private func log(_ message: String) {
        if DispatchQueue.getSpecific(key: Self.queueKey) != nil {
            logHandle?.write(Data("[\(Date())] \(message)\n".utf8))
        } else {
            queue.async { self.logHandle?.write(Data("[\(Date())] \(message)\n".utf8)) }
        }
    }

    /// Delivers `onCaptureFailure` at most once per recording. Dispatches onto
    /// `queue` to check+set `didReportFailure` safely, then invokes the handler
    /// outside any lock context so it can freely re-enter the recorder.
    private func reportCaptureFailure(_ message: String) {
        queue.async {
            guard !self.isStopping else { return }
            guard !self.didReportFailure else { return }
            self.didReportFailure = true
            self.onCaptureFailure?(message)
        }
    }
}

/// A synchronous setup failure inside `startStream` that should flow through
/// the same reporting path as any other post-start capture failure.
enum CaptureError: LocalizedError {
    case noDisplay
    var errorDescription: String? { "No display available for system-audio capture." }
}

/// Resumes a player drain exactly once: with true when every player has played its
/// marker, or with false if the timeout fires first.
private final class DrainGate: Sendable {
    private let state: OSAllocatedUnfairLock<(remaining: Int, continuation: CheckedContinuation<Bool, Never>?)>

    init(count: Int, continuation: CheckedContinuation<Bool, Never>) {
        state = OSAllocatedUnfairLock(initialState: (remaining: count, continuation: continuation))
    }

    func arrive() {
        let finished = state.withLock { state -> CheckedContinuation<Bool, Never>? in
            state.remaining -= 1
            guard state.remaining == 0 else { return nil }
            defer { state.continuation = nil }
            return state.continuation
        }
        finished?.resume(returning: true)
    }

    func expire() {
        let pending = state.withLock { state -> CheckedContinuation<Bool, Never>? in
            defer { state.continuation = nil }
            return state.continuation
        }
        pending?.resume(returning: false)
    }
}

/// Tracks whether the single input buffer has been handed to an AVAudioConverter
/// input block. A reference type so the synchronous conversion closure mutates
/// shared state without tripping Swift 6 captured-var diagnostics.
private final class ConverterFeedState: @unchecked Sendable {
    var consumed = false
}
