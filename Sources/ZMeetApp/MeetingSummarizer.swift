import Foundation
import FoundationModels
import ZMeetCore

/// Summarizes a transcript into structured Markdown notes using macOS 26's
/// on-device Foundation Models LLM via map-reduce (so long meetings are fully
/// covered, not just their opening). Falls back to a simple extractive summary
/// when Apple Intelligence is unavailable. Stateless / Sendable.
struct MeetingSummarizer: Summarizer {
    func summarize(transcript: String, title: String) async throws -> String {
        let model = SystemLanguageModel.default
        guard case .available = model.availability else {
            return Self.extractiveFallback(transcript: transcript)
        }
        do {
            return try await MapReduceSummarizer(
                maxChunkCharacters: AIProvider.onDevice.chunkBudget ?? 10_000,
                complete: { prompt in try await LanguageModelSession().respond(to: prompt).content }
            ).summarize(transcript: transcript, title: title)
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
