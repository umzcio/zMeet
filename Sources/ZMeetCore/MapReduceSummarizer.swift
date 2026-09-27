import Foundation

/// Summarizes with any prompt → text completion, map-reducing transcripts longer
/// than one chunk so long meetings are fully covered, not just their opening.
/// Shared by the on-device engine and Ollama; the completion is injected so the
/// orchestration is testable without a model.
public struct MapReduceSummarizer: Summarizer {
    public typealias Complete = @Sendable (String) async throws -> String

    let maxChunkCharacters: Int
    let complete: Complete

    public init(maxChunkCharacters: Int, complete: @escaping Complete) {
        self.maxChunkCharacters = maxChunkCharacters
        self.complete = complete
    }

    public func summarize(transcript: String, title: String) async throws -> String {
        let chunks = TranscriptChunker().chunk(transcript, maxCharacters: maxChunkCharacters)
        // Short meeting (or empty): single pass.
        guard chunks.count > 1 else {
            return try await complete(MeetingSummaryPrompt.build(transcript: chunks.first ?? transcript, title: title))
        }
        // Map: summarize each chunk. Clean each answer so a reasoning model's
        // <think> block never reaches the reduce prompt.
        var parts: [String] = []
        for chunk in chunks {
            parts.append(SummaryOutput.clean(try await complete(MeetingSummaryPrompt.build(transcript: chunk, title: title))))
        }
        return try await reduce(parts: parts, title: title)
    }

    /// Collapse per-portion notes into one set, reducing in rounds when the joined
    /// notes are themselves too large for a single pass.
    private func reduce(parts: [String], title: String) async throws -> String {
        var parts = parts
        let chunker = TranscriptChunker()
        // Each round should shrink the part count; a model that returns
        // non-shrinking output would otherwise loop forever. 6 rounds covers
        // any real meeting (10k-char budget → 6 halvings ≳ 640k chars).
        for _ in 0..<6 {
            if parts.count == 1 { return parts[0] }
            let groups = chunker.group(parts, maxCharacters: maxChunkCharacters)
            if groups.count == 1 {
                return try await complete(MeetingSummaryPrompt.reduce(parts: parts, title: title))
            }
            var reduced: [String] = []
            for group in groups {
                reduced.append(SummaryOutput.clean(try await complete(MeetingSummaryPrompt.reduce(parts: group, title: title))))
            }
            // A round that didn't shrink will never converge — bail to the guard below.
            if reduced.count >= parts.count { parts = reduced; break }
            parts = reduced
        }
        // Exhausted: reduce whatever we have in one clipped pass rather than spin.
        let joined = parts.joined(separator: "\n\n")
        return try await complete(MeetingSummaryPrompt.reduce(parts: [String(joined.prefix(maxChunkCharacters))], title: title))
    }
}

/// Sends the whole transcript (capped) in one request — for large-context cloud
/// models, where map-reduce would only lose cross-meeting context.
public struct SinglePassSummarizer: Summarizer {
    let maxTranscriptCharacters: Int
    let complete: MapReduceSummarizer.Complete

    public init(maxTranscriptCharacters: Int = 150_000, complete: @escaping MapReduceSummarizer.Complete) {
        self.maxTranscriptCharacters = maxTranscriptCharacters
        self.complete = complete
    }

    public func summarize(transcript: String, title: String) async throws -> String {
        let clipped = String(transcript.prefix(maxTranscriptCharacters))
        return try await complete(MeetingSummaryPrompt.build(transcript: clipped, title: title))
    }
}
