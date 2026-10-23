import Foundation
import AVFoundation
import Speech
import CoreMedia
import ZMeetCore

/// On-device transcription using macOS 26's SpeechAnalyzer + SpeechTranscriber.
/// Stateless (a value type), so it's trivially Sendable and safe to call from
/// any actor. The speech model is system-managed and downloaded on first use.
struct SpeechTranscription: Sendable {
    /// The whole recording as readable Markdown: timestamped paragraphs broken at
    /// pauses and length (`TranscriptFormatter`).
    func transcribe(audioURL: URL, onProgress: (@Sendable (Double) -> Void)? = nil) async throws -> String {
        let segments = try await transcribeSegments(audioURL: audioURL, onProgress: onProgress)
        let text = TranscriptFormatter().format(segments)
        return text.isEmpty ? "(No speech detected in the recording.)" : text
    }

    func transcribeSegments(audioURL: URL, onProgress: (@Sendable (Double) -> Void)? = nil) async throws -> [TranscriptSegment] {
        guard await ensureAuthorized() else { throw TranscriptionError.notAuthorized }
        let locale = bestLocale()
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        if let installation = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await installation.downloadAndInstall()
        }
        let audioFile = try AVAudioFile(forReading: audioURL)
        let duration = Double(audioFile.length) / audioFile.fileFormat.sampleRate
        let analyzer = SpeechAnalyzer(modules: [transcriber])

        let collector = Task { () -> [TranscriptSegment] in
            var segments: [TranscriptSegment] = []
            for try await result in transcriber.results {
                let text = String(result.text.characters)
                segments.append(TranscriptSegment(text: text, start: result.range.start.seconds,
                                                  end: result.range.end.seconds))
                if duration > 0 { onProgress?(min(1, result.range.end.seconds / duration)) }
            }
            return segments
        }
        defer { collector.cancel() }
        do {
            _ = try await analyzer.analyzeSequence(from: audioFile)
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            await analyzer.cancelAndFinishNow()
            throw error
        }
        return try await collector.value
    }

    private func bestLocale() -> Locale {
        let current = Locale.current
        // Fall back to US English if the current locale isn't a sensible default.
        if current.language.languageCode != nil { return current }
        return Locale(identifier: "en-US")
    }

    private func ensureAuthorized() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status == .authorized)
                }
            }
        default:
            return false
        }
    }

    enum TranscriptionError: LocalizedError {
        case notAuthorized
        var errorDescription: String? {
            switch self {
            case .notAuthorized:
                return "Speech Recognition permission was denied. Enable it in System Settings → Privacy & Security → Speech Recognition."
            }
        }
    }
}
