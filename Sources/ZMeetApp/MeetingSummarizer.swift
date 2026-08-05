import Foundation
import FoundationModels
import ZMeetCore

/// Summarizes a transcript into structured Markdown notes using macOS 26's
/// on-device Foundation Models LLM via map-reduce (so long meetings are fully
/// covered, not just their opening). Falls back to a simple extractive summary
/// when Apple Intelligence is unavailable. Stateless / Sendable.
struct MeetingSummarizer: Summarizer {
    /// Per-chunk budget, kept under the on-device model's context limit with room
    /// for the surrounding prompt.
    private let maxChunkCharacters = 10_000

    func summarize(transcript: String, title: String) async throws -> String {
        let model = SystemLanguageModel.default
        guard case .available = model.availability else {
            return Self.extractiveFallback(transcript: transcript)
        }

        let chunks = TranscriptChunker().chunk(transcript, maxCharacters: maxChunkCharacters)
        do {
            // Short meeting (or empty): single pass, current behavior.
            guard chunks.count > 1 else {
                let prompt = MeetingSummaryPrompt.build(transcript: chunks.first ?? transcript, title: title)
                return try await respond(to: prompt)
            }
            // Map: summarize each chunk.
            var parts: [String] = []
            for chunk in chunks {
                parts.append(try await respond(to: MeetingSummaryPrompt.build(transcript: chunk, title: title)))
            }
            // Reduce (hierarchically if the joined parts exceed one chunk budget).
            return try await reduce(parts: parts, title: title)
        } catch {
            return Self.extractiveFallback(transcript: transcript)
        }
    }

    private func respond(to prompt: String) async throws -> String {
        try await LanguageModelSession().respond(to: prompt).content
    }

    /// Collapse per-portion notes into one set, reducing in rounds when the joined
    /// notes are themselves too large for a single pass.
    private func reduce(parts: [String], title: String) async throws -> String {
        var parts = parts
        let chunker = TranscriptChunker()
        while true {
            if parts.count == 1 { return parts[0] }
            let groups = chunker.group(parts, maxCharacters: maxChunkCharacters)
            if groups.count == 1 {
                return try await respond(to: MeetingSummaryPrompt.reduce(parts: parts, title: title))
            }
            var reduced: [String] = []
            for group in groups {
                reduced.append(try await respond(to: MeetingSummaryPrompt.reduce(parts: group, title: title)))
            }
            parts = reduced
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
