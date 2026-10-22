import Foundation
@preconcurrency import AVFoundation
import ZMeetCore

// aec-probe — run the EchoCanceller (WebRTC AEC3) on a REAL zMeet capture pair so we
// can hear/measure cancellation offline, before touching the live recorder.
//
//   aec-probe <mic.m4a> <system.m4a> [mic-cleaned.m4a]
//
// mic.m4a    = near end (you + speaker bleed of the remote audio)
// system.m4a = far end  (the remote/system audio that bled into the mic — the AEC reference)
// output     = the mic with the remote bleed removed.
//
// Both tracks are decoded to the canceller's format (48 kHz mono Float32) and fed in
// 10 ms frames, paired by sample index: processRender(far), then processCapture(&near).

let aecRate = Double(EchoCanceller.sampleRate)  // 48 kHz mono
let frameSize = EchoCanceller.frameSize          // 10 ms

enum ProbeError: Error, CustomStringConvertible {
    case usage
    case missingFile(String)
    case noConverter
    case allocFailed
    case convertFailed(String)
    case unsupportedWriteFormat(String)
    case cancellerUnavailable
    case cancellerFailed(sample: Int)

    var description: String {
        switch self {
        case .usage: return "usage: aec-probe <mic.m4a> <system.m4a> [mic-cleaned.m4a]"
        case .missingFile(let p): return "file not found: \(p)"
        case .noConverter: return "could not create AVAudioConverter for the input format"
        case .allocFailed: return "could not allocate an audio buffer"
        case .convertFailed(let m): return "audio conversion failed: \(m)"
        case .unsupportedWriteFormat(let m): return "unsupported output processing format: \(m)"
        case .cancellerUnavailable: return "could not create the echo canceller (WebRTC APM)"
        case .cancellerFailed(let s): return "the echo canceller rejected the frame at sample \(s)"
        }
    }
}

/// Decode an audio file to 48 kHz mono Float32 PCM (the canceller's working format).
func loadMono48k(_ path: String) throws -> [Float] {
    let url = URL(fileURLWithPath: path)
    guard FileManager.default.fileExists(atPath: url.path) else { throw ProbeError.missingFile(path) }

    let file = try AVAudioFile(forReading: url)
    let inputFormat = file.processingFormat

    guard let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                           sampleRate: aecRate,
                                           channels: 1,
                                           interleaved: false) else {
        throw ProbeError.noConverter
    }
    guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
        throw ProbeError.noConverter
    }

    // Pull the whole file into one input buffer, then drain the converter.
    let inFrames = AVAudioFrameCount(file.length)
    guard inFrames > 0,
          let inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: inFrames) else {
        return []
    }
    try file.read(into: inputBuffer)

    // Box the one-shot flag in a reference so the (Sendable) input block can mutate it
    // under Swift 6 strict concurrency. The converter calls this synchronously.
    final class FeedState: @unchecked Sendable { var fed = false }
    let state = FeedState()
    let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
        if state.fed { outStatus.pointee = .endOfStream; return nil }
        state.fed = true
        outStatus.pointee = .haveData
        return inputBuffer
    }

    var samples: [Float] = []
    samples.reserveCapacity(Int(Double(inFrames) * aecRate / inputFormat.sampleRate) + frameSize)

    func append(_ buffer: AVAudioPCMBuffer) {
        let n = Int(buffer.frameLength)
        guard n > 0, let ch = buffer.floatChannelData else { return }
        samples.append(contentsOf: UnsafeBufferPointer(start: ch[0], count: n))
    }

    var draining = true
    while draining {
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 16_384) else {
            throw ProbeError.allocFailed
        }
        var error: NSError?
        let status = converter.convert(to: outBuffer, error: &error, withInputFrom: inputBlock)
        switch status {
        case .haveData:
            append(outBuffer)
        case .inputRanDry:
            append(outBuffer)   // single-shot input → nothing more is coming
            draining = false
        case .endOfStream:
            draining = false
        case .error:
            throw ProbeError.convertFailed(error?.localizedDescription ?? "unknown")
        @unknown default:
            draining = false
        }
    }
    return samples
}

/// Encode 48 kHz mono Float32 PCM to an AAC .m4a (so the result is listenable).
func writeMono48k(_ samples: [Float], to path: String) throws {
    let url = URL(fileURLWithPath: path)
    try? FileManager.default.removeItem(at: url)

    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: aecRate,
        AVNumberOfChannelsKey: 1
    ]
    let outFile = try AVAudioFile(forWriting: url, settings: settings)
    let format = outFile.processingFormat   // PCM format AVAudioFile wants us to write

    let chunk = 16_384
    var start = 0
    while start < samples.count {
        let end = min(start + chunk, samples.count)
        let count = AVAudioFrameCount(end - start)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count) else {
            throw ProbeError.allocFailed
        }
        buffer.frameLength = count

        switch format.commonFormat {
        case .pcmFormatFloat32:
            guard let dst = buffer.floatChannelData else {
                throw ProbeError.unsupportedWriteFormat("float32 without channel data")
            }
            for i in 0..<Int(count) { dst[0][i] = samples[start + i] }
        case .pcmFormatInt16:
            guard let dst = buffer.int16ChannelData else {
                throw ProbeError.unsupportedWriteFormat("int16 without channel data")
            }
            for i in 0..<Int(count) { dst[0][i] = Int16(max(-1, min(1, samples[start + i])) * 32767) }
        default:
            throw ProbeError.unsupportedWriteFormat("\(format.commonFormat.rawValue)")
        }

        try outFile.write(from: buffer)
        start = end
    }
}

func rms(_ samples: ArraySlice<Float>) -> Double {
    guard !samples.isEmpty else { return 0 }
    var acc = 0.0
    for s in samples { acc += Double(s) * Double(s) }
    return (acc / Double(samples.count)).squareRoot()
}

func dbfs(_ rms: Double) -> Double { rms > 0 ? 20 * log10(rms) : -200 }

// ---- main ----

let args = CommandLine.arguments
guard args.count >= 3 else {
    FileHandle.standardError.write(Data((ProbeError.usage.description + "\n").utf8))
    exit(2)
}
let micPath = args[1]
let systemPath = args[2]
let outPath = args.count >= 4 ? args[3]
    : (micPath as NSString).deletingPathExtension + "-cleaned.m4a"

do {
    print("Loading near (mic):    \(micPath)")
    let near = try loadMono48k(micPath)
    print("Loading far  (system): \(systemPath)")
    let far = try loadMono48k(systemPath)

    let n = min(near.count, far.count)
    print(String(format: "Decoded %d near / %d far samples @ %.0f Hz (%.1fs / %.1fs)",
                 near.count, far.count, aecRate,
                 Double(near.count) / aecRate, Double(far.count) / aecRate))
    if near.count != far.count {
        print("  note: track lengths differ; aligning by sample index over the shorter \(n) samples")
    }

    guard let canceller = EchoCanceller() else { throw ProbeError.cancellerUnavailable }
    var cleaned: [Float] = []
    cleaned.reserveCapacity(n)

    var start = 0
    while start < n {
        let end = min(start + frameSize, n)
        let len = end - start
        var nf = Array(near[start..<end])
        var ff = Array(far[start..<end])
        if len < frameSize {
            nf.append(contentsOf: repeatElement(0, count: frameSize - len))
            ff.append(contentsOf: repeatElement(0, count: frameSize - len))
        }
        guard canceller.processRender(ff), canceller.processCapture(&nf) else {
            throw ProbeError.cancellerFailed(sample: start)
        }
        cleaned.append(contentsOf: nf.prefix(len))
        start += frameSize
    }

    try writeMono48k(cleaned, to: outPath)

    // Measure over the back half (after the adaptive filter has converged).
    let half = n / 2
    let nearRMS = rms(near[half..<n])
    let cleanRMS = rms(cleaned[min(half, cleaned.count)..<cleaned.count])
    let farRMS = rms(far[half..<n])
    let reduction = nearRMS > 0 && cleanRMS > 0 ? 20.0 * log10(nearRMS / cleanRMS) : 0

    print("")
    print("Wrote cleaned mic → \(outPath)")
    print(String(format: "  far  RMS (reference): %8.5f (%6.1f dBFS)", farRMS, dbfs(farRMS)))
    print(String(format: "  near RMS (mic in):    %8.5f (%6.1f dBFS)", nearRMS, dbfs(nearRMS)))
    print(String(format: "  clean RMS (mic out):  %8.5f (%6.1f dBFS)", cleanRMS, dbfs(cleanRMS)))
    print(String(format: "  level change:         %+6.1f dB  (negative = quieter after AEC)", -reduction))
    print("")
    print("Now LISTEN: '\(micPath)' should echo the remote; '\(outPath)' should be just you + room.")
} catch {
    FileHandle.standardError.write(Data(("error: \(error)\n").utf8))
    exit(1)
}
