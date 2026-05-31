import Foundation
import FoundationModels
import ZMeetCore

/// Summarizes a transcript into structured Markdown notes using macOS 26's
/// on-device Foundation Models LLM. Falls back to a simple extractive summary
/// when Apple Intelligence is unavailable. Stateless / Sendable.
@available(macOS 26, *)
struct MeetingSummarizer: Summarizer {
    /// On-device context is limited, so cap the transcript fed to the model.
    private let maxTranscriptCharacters = 12_000

    func summarize(transcript: String, title: String) async throws -> String {
        let model = SystemLanguageModel.default
        guard case .available = model.availability else {
            return Self.extractiveFallback(transcript: transcript)
        }

        let clipped = String(transcript.prefix(maxTranscriptCharacters))
        let truncatedNote = transcript.count > maxTranscriptCharacters
            ? "\n\n_(Transcript was truncated for summarization.)_"
            : ""

        let prompt = MeetingSummaryPrompt.build(transcript: clipped, title: title)

        do {
            let response = try await LanguageModelSession().respond(to: prompt)
            return response.content + truncatedNote
        } catch {
            return Self.extractiveFallback(transcript: transcript)
        }
    }

    static func extractiveFallback(transcript: String) -> String {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "## Summary\n\n- No transcript content was available."
        }
        let excerpt = trimmed
            .split(separator: "\n")
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .prefix(15)
            .joined(separator: "\n")
        return """
        ## Summary

        On-device summarization was unavailable, so here is the start of the transcript:

        \(excerpt)
        """
    }
}
