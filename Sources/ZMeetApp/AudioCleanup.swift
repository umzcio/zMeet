import Foundation
import AVFoundation
import AudioToolbox
import ZMeetCore

/// Offline background-noise cleanup for a finished recording. Renders the file
/// through a fresh AVAudioEngine (high-pass + downward expander) and atomically
/// replaces the original on success. Entirely separate from SCKAudioRecorder's
/// live engine. An empty value type, so it's Sendable and `clean` runs off the
/// main actor when awaited from a @MainActor caller.
struct AudioCleanup {
    enum CleanupError: Error { case renderFailed }

    /// Clean `fileURL` in place. On success the file is replaced with the cleaned
    /// version; on any thrown error the original is left untouched.
    func clean(fileURL: URL) async throws {
        let source = try AVAudioFile(forReading: fileURL)
        let format = source.processingFormat
        guard source.length > 0 else { return }

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let eq = AVAudioUnitEQ(numberOfBands: 1)
        let band = eq.bands[0]
        band.filterType = .highPass
        band.frequency = 85
        band.bypass = false

        let dynamics = AVAudioUnitEffect(audioComponentDescription: AudioComponentDescription(
            componentType: kAudioUnitType_Effect,
            componentSubType: kAudioUnitSubType_DynamicsProcessor,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        ))

        engine.attach(player)
        engine.attach(eq)
        engine.attach(dynamics)
        engine.connect(player, to: eq, format: format)
        engine.connect(eq, to: dynamics, format: format)
        engine.connect(dynamics, to: engine.mainMixerNode, format: format)

        let maxFrames: AVAudioFrameCount = 4096
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: maxFrames)
        try engine.start()

        // Configure the dynamics processor as a gentle downward expander so steady
        // low-level noise between speech is pulled down while speech passes.
        let au = dynamics.audioUnit
        AudioUnitSetParameter(au, kDynamicsProcessorParam_ExpansionThreshold, kAudioUnitScope_Global, 0, -45, 0)
        AudioUnitSetParameter(au, kDynamicsProcessorParam_ExpansionRatio, kAudioUnitScope_Global, 0, 2, 0)
        AudioUnitSetParameter(au, kDynamicsProcessorParam_AttackTime, kAudioUnitScope_Global, 0, 0.005, 0)
        AudioUnitSetParameter(au, kDynamicsProcessorParam_ReleaseTime, kAudioUnitScope_Global, 0, 0.15, 0)

        await player.scheduleFile(source, at: nil)
        player.play()

        let tempURL = fileURL.deletingLastPathComponent()
            .appendingPathComponent("cleanup-\(UUID().uuidString).m4a")
        var outFile: AVAudioFile? = try AVAudioFile(forWriting: tempURL, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
        ])

        guard let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: maxFrames) else {
            engine.stop()
            try? FileManager.default.removeItem(at: tempURL)
            throw CleanupError.renderFailed
        }

        var completed = false
        do {
            renderLoop: while engine.manualRenderingSampleTime < source.length {
                let remaining = source.length - engine.manualRenderingSampleTime
                let frames = AVAudioFrameCount(min(Int64(buffer.frameCapacity), remaining))
                let status = try engine.renderOffline(frames, to: buffer)
                switch status {
                case .success:
                    try outFile?.write(from: buffer)
                case .insufficientDataFromInputNode:
                    break renderLoop
                case .cannotDoInCurrentContext, .error:
                    throw CleanupError.renderFailed
                @unknown default:
                    throw CleanupError.renderFailed
                }
            }
            completed = engine.manualRenderingSampleTime >= source.length
        } catch {
            engine.stop()
            outFile = nil
            try? FileManager.default.removeItem(at: tempURL)
            throw error
        }

        engine.stop()
        outFile = nil  // finalize/flush the AAC file before replacing

        // Refuse to swap in a partial render: the loop must have consumed the
        // whole source and the encoded output must be within tolerance of the
        // source length. A thrown error here is the safe path — the caller
        // keeps the original recording.
        let rendered = try AVAudioFile(forReading: tempURL)
        let toleranceFrames = Int64(format.sampleRate)
        guard AudioCleanupPolicy.mayReplaceOriginal(
            sourceFrames: source.length,
            renderedFrames: rendered.length,
            loopCompleted: completed,
            toleranceFrames: toleranceFrames
        ) else {
            try? FileManager.default.removeItem(at: tempURL)
            throw CleanupError.renderFailed
        }

        // Atomically swap the cleaned file in for the original.
        _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: tempURL)
    }
}
