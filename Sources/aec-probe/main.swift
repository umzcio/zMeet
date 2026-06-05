import Foundation
@preconcurrency import AVFoundation
import ZMeetCore

// aec-probe — run the EchoCanceller on a REAL zMeet capture pair so we can hear/measure
// cancellation before touching the live recorder (Phase 1, Task 4 decision gate).
//
//   aec-probe <mic.m4a> <system.m4a> [mic-cleaned.m4a]
//
// mic.m4a    = near end (you + speaker bleed of the remote audio)
// system.m4a = far end  (the remote/system audio that bled into the mic — the AEC reference)
// output     = the mic with the remote bleed removed.
//
// This also prototypes the 48 kHz-float ↔ 16 kHz-mono-Int16 conversions Phase 2 needs.

let aecRate: Double = 16_000     // AEC works at 16 kHz mono
let frameSize = 160              // 10 ms @ 16 kHz
let filterLength = 1600          // 100 ms adaptive-filter tail (a typical room)

enum ProbeError: Error, CustomStringConvertible {
    case usage
    case missingFile(String)
    case noConverter
    case allocFailed
    case convertFailed(String)
    case unsupportedWriteFormat(String)

    var description: String {
        switch self {
        case .usage: return "usage: aec-probe <mic.m4a> <system.m4a> [mic-cleaned.m4a]"
        case .missingFile(let p): return "file not found: \(p)"
        case .noConverter: return "could not create AVAudioConverter for the input format"
        case .allocFailed: return "could not allocate an audio buffer"
        case .convertFailed(let m): return "audio conversion failed: \(m)"
        case .unsupportedWriteFormat(let m): return "unsupported output processing format: \(m)"
        }
    }
}

/// Decode an audio file to 16 kHz mono Int16 PCM (the AEC's working format).
func loadMono16k(_ path: String) throws -> [Int16] {
    let url = URL(fileURLWithPath: path)
    guard FileManager.default.fileExists(atPath: url.path) else { throw ProbeError.missingFile(path) }

    let file = try AVAudioFile(forReading: url)
    let inputFormat = file.processingFormat

    guard let outputFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                           sampleRate: aecRate,
                                           channels: 1,
                                           interleaved: true) else {
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

    var samples: [Int16] = []
    samples.reserveCapacity(Int(Double(inFrames) * aecRate / inputFormat.sampleRate) + frameSize)

    func append(_ buffer: AVAudioPCMBuffer) {
        let n = Int(buffer.frameLength)
        guard n > 0, let ch = buffer.int16ChannelData else { return }
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

/// Encode 16 kHz mono Int16 PCM to an AAC .m4a (so the result is listenable).
func writeMono16k(_ samples: [Int16], to path: String) throws {
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
            for i in 0..<Int(count) { dst[0][i] = Float(samples[start + i]) / 32768.0 }
        case .pcmFormatInt16:
            guard let dst = buffer.int16ChannelData else {
                throw ProbeError.unsupportedWriteFormat("int16 without channel data")
            }
            for i in 0..<Int(count) { dst[0][i] = samples[start + i] }
        default:
            throw ProbeError.unsupportedWriteFormat("\(format.commonFormat.rawValue)")
        }

        try outFile.write(from: buffer)
        start = end
    }
}

func rms(_ samples: ArraySlice<Int16>) -> Double {
    guard !samples.isEmpty else { return 0 }
    var acc = 0.0
    for s in samples { acc += Double(s) * Double(s) }
    return (acc / Double(samples.count)).squareRoot()
}

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
    let near = try loadMono16k(micPath)
    print("Loading far  (system): \(systemPath)")
    let far = try loadMono16k(systemPath)

    let n = min(near.count, far.count)
    print(String(format: "Decoded %d near / %d far samples @ %.0f Hz (%.1fs / %.1fs)",
                 near.count, far.count, aecRate,
                 Double(near.count) / aecRate, Double(far.count) / aecRate))
    if near.count != far.count {
        print("  note: track lengths differ; aligning by sample index over the shorter \(n) samples")
    }

    let aec = EchoCanceller(frameSize: frameSize, filterLength: filterLength)
    var cleaned: [Int16] = []
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
        let out = aec.cancel(near: nf, far: ff)
        cleaned.append(contentsOf: out.prefix(len))
        start += frameSize
    }

    try writeMono16k(cleaned, to: outPath)

    // Measure over the back half (after the adaptive filter has converged).
    let half = n / 2
    let nearRMS = rms(near[half..<n])
    let cleanRMS = rms(cleaned[min(half, cleaned.count)..<cleaned.count])
    let farRMS = rms(far[half..<n])
    let reduction = nearRMS > 0 && cleanRMS > 0 ? 20.0 * log10(nearRMS / cleanRMS) : 0

    print("")
    print("Wrote cleaned mic → \(outPath)")
    print(String(format: "  far  RMS (reference): %8.1f", farRMS))
    print(String(format: "  near RMS (mic in):    %8.1f", nearRMS))
    print(String(format: "  clean RMS (mic out):  %8.1f", cleanRMS))
    print(String(format: "  level change:         %+6.1f dB  (negative = quieter after AEC)", -reduction))
    print("")
    print("Now LISTEN: '\(micPath)' should echo the remote; '\(outPath)' should be just you + room.")
} catch {
    FileHandle.standardError.write(Data(("error: \(error)\n").utf8))
    exit(1)
}
