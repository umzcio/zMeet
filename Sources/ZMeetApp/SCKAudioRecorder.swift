import Foundation
import AVFoundation
import CoreMedia
import ScreenCaptureKit
import ZMeetCore

/// Captures system audio + microphone via one SCStream (macOS 15+), normalizes
/// both to a canonical PCM format, mixes them through an AVAudioEngine, and
/// writes the mix to an AAC `.m4a`. The main mixer is muted so nothing plays
/// back to the speakers (no feedback); a capture mixer is tapped at full level.
final class SCKAudioRecorder: NSObject, MeetingRecorder, SCStreamOutput, @unchecked Sendable {
    private var stream: SCStream?
    private let engine = AVAudioEngine()
    private let systemPlayer = AVAudioPlayerNode()
    private let micPlayer = AVAudioPlayerNode()
    private let captureMixer = AVAudioMixerNode()
    private var audioFile: AVAudioFile?
    private var logHandle: FileHandle?
    private let queue = DispatchQueue(label: "edu.umontana.zmeet.capture")

    private let canonical = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 48_000,
        channels: 2,
        interleaved: false
    )!
    private var systemConverter: AVAudioConverter?
    private var micConverter: AVAudioConverter?

    func start(to url: URL, logURL: URL, audio: AudioConfig) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        logHandle = try? FileHandle(forWritingTo: logURL)
        log("start \(url.lastPathComponent)")

        audioFile = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: canonical.sampleRate,
            AVNumberOfChannelsKey: canonical.channelCount,
            AVEncoderBitRateKey: audio.bitrate
        ])

        engine.attach(systemPlayer)
        engine.attach(micPlayer)
        engine.attach(captureMixer)
        engine.connect(systemPlayer, to: captureMixer, format: canonical)
        engine.connect(micPlayer, to: captureMixer, format: canonical)
        engine.connect(captureMixer, to: engine.mainMixerNode, format: canonical)
        engine.mainMixerNode.outputVolume = 0  // prevent speaker feedback

        captureMixer.installTap(onBus: 0, bufferSize: 4096, format: canonical) { [weak self] buffer, _ in
            guard let self, let file = self.audioFile, buffer.frameLength > 0 else { return }
            do { try file.write(from: buffer) } catch { self.log("write error: \(error)") }
        }

        try engine.start()
        systemPlayer.play()
        micPlayer.play()

        Task {
            do { try await self.startStream(audio: audio) }
            catch { self.log("stream start error: \(error)") }
        }
    }

    private func startStream(audio: AudioConfig) async throws {
        let content = try await SCShareableContent.current
        guard let display = content.displays.first else {
            log("no display available")
            return
        }
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])

        let config = SCStreamConfiguration()
        config.capturesAudio = audio.captureSystemAudio
        config.sampleRate = Int(canonical.sampleRate)
        config.channelCount = 2
        config.captureMicrophone = audio.captureMicrophone
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        if audio.captureMicrophone {
            try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: queue)
        }
        self.stream = stream
        try await stream.startCapture()
        log("capture started (system=\(audio.captureSystemAudio) mic=\(audio.captureMicrophone))")
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid, sampleBuffer.numSamples > 0,
              let pcm = Self.pcmBuffer(from: sampleBuffer) else { return }
        switch type {
        case .audio:
            if let out = convert(pcm, using: &systemConverter, label: "system") {
                systemPlayer.scheduleBuffer(out, completionHandler: nil)
            }
        case .microphone:
            if let out = convert(pcm, using: &micConverter, label: "mic") {
                micPlayer.scheduleBuffer(out, completionHandler: nil)
            }
        default:
            break
        }
    }

    private func convert(_ input: AVAudioPCMBuffer, using converter: inout AVAudioConverter?, label: String) -> AVAudioPCMBuffer? {
        if input.format == canonical { return input }
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

    func stop() throws {
        log("stop")
        if let stream {
            let sem = DispatchSemaphore(value: 0)
            stream.stopCapture { _ in sem.signal() }
            _ = sem.wait(timeout: .now() + 5)
        }
        stream = nil
        captureMixer.removeTap(onBus: 0)
        systemPlayer.stop()
        micPlayer.stop()
        engine.stop()
        audioFile = nil  // closes/finalizes the file
        try? logHandle?.close()
        logHandle = nil
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
        logHandle?.write(Data("[\(Date())] \(message)\n".utf8))
    }
}

/// Tracks whether the single input buffer has been handed to an AVAudioConverter
/// input block. A reference type so the synchronous conversion closure mutates
/// shared state without tripping Swift 6 captured-var diagnostics.
private final class ConverterFeedState: @unchecked Sendable {
    var consumed = false
}
