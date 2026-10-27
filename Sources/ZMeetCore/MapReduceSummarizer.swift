import Foundation

/// Which notes a summarizer asks for: the full structured format, or the
/// compact four-section fallback.
public enum NotesFormat: Sendable { case full, compact }

/// Summarizes with any prompt → text completion, map-reducing transcripts longer
/// than one chunk so long meetings are fully covered, not just their opening.
/// Shared by the on-device engine and Ollama; the completion is injected so the
/// orchestration is testable without a model.
public struct MapReduceSummarizer: Summarizer {
    public typealias Complete = @Sendable (String) async throws -> String

    let maxChunkCharacters: Int
    let format: NotesFormat
    let complete: Complete

    public init(maxChunkCharacters: Int, format: NotesFormat = .full, complete: @escaping Complete) {
        self.maxChunkCharacters = maxChunkCharacters
        self.format = format
        self.complete = complete
    }

    public func summarize(transcript: String, title: String) async throws -> String {
        let chunks = TranscriptChunker().chunk(transcript, maxCharacters: maxChunkCharacters)
        // Short meeting (or empty): single pass.
        guard chunks.count > 1 else {
            let text = chunks.first ?? transcript
            return try await complete(format == .full
                ? MeetingSummaryPrompt.build(transcript: text, title: title)
                : MeetingSummaryPrompt.buildCompact(transcript: text, title: title))
        }
        // Map each chunk — to a fact list (full) or to compact notes. Clean each
        // answer so a reasoning model's <think> block never reaches the reduce.
        var parts: [String] = []
        for chunk in chunks {
            let prompt = format == .full
                ? MeetingSummaryPrompt.map(transcript: chunk, title: title)
                : MeetingSummaryPrompt.buildCompact(transcript: chunk, title: title)
            parts.append(SummaryOutput.clean(try await complete(prompt)))
        }
        return format == .full
            ? try await writeNotes(facts: parts, title: title)
            : try await reduceCompact(parts: parts, title: title)
    }

    /// Merges fact lists in rounds until they fit one call, then writes the notes
    /// once. Merging deduplicates without summarizing numbers or speakers away.
    private func writeNotes(facts: [String], title: String) async throws -> String {
        var facts = facts
        let chunker = TranscriptChunker()
        // Same bound as reduceCompact: a model whose merges don't shrink the
        // list must not loop forever.
        for _ in 0..<6 {
            let groups = chunker.group(facts, maxCharacters: maxChunkCharacters)
            if groups.count == 1 { break }
            var merged: [String] = []
            for group in groups {
                merged.append(SummaryOutput.clean(try await complete(MeetingSummaryPrompt.mergeFacts(parts: group, title: title))))
            }
            let shrank = merged.count < facts.count
            facts = merged
            if !shrank { break }
        }
        // Still too large (a merge that wouldn't shrink): clip rather than overflow.
        let joined = facts.joined(separator: "\n\n")
        if joined.count > maxChunkCharacters { facts = [String(joined.prefix(maxChunkCharacters))] }
        return try await complete(MeetingSummaryPrompt.reduce(parts: facts, title: title))
    }

    /// Collapse per-portion compact notes into one set, reducing in rounds when
    /// the joined notes are themselves too large for a single pass.
    private func reduceCompact(parts: [String], title: String) async throws -> String {
        var parts = parts
        let chunker = TranscriptChunker()
        // Each round should shrink the part count; a model that returns
        // non-shrinking output would otherwise loop forever. 6 rounds covers
        // any real meeting (10k-char budget → 6 halvings ≳ 640k chars).
        for _ in 0..<6 {
            if parts.count == 1 { return parts[0] }
            let groups = chunker.group(parts, maxCharacters: maxChunkCharacters)
            if groups.count == 1 {
                return try await complete(MeetingSummaryPrompt.reduceCompact(parts: parts, title: title))
            }
            var reduced: [String] = []
            for group in groups {
                reduced.append(SummaryOutput.clean(try await complete(MeetingSummaryPrompt.reduceCompact(parts: group, title: title))))
            }
            // A round that didn't shrink will never converge — bail to the guard below.
            if reduced.count >= parts.count { parts = reduced; break }
            parts = reduced
        }
        // Exhausted: reduce whatever we have in one clipped pass rather than spin.
        let joined = parts.joined(separator: "\n\n")
        return try await complete(MeetingSummaryPrompt.reduceCompact(parts: [String(joined.prefix(maxChunkCharacters))], title: title))
    }
}

/// For large-context cloud models: extracts facts from the whole transcript
/// (capped) in one request, then writes the notes from those facts in a second.
/// Separating the steps keeps speakers and details that a single pass blurs;
/// map-reduce would only lose cross-meeting context.
public struct FactFirstSummarizer: Summarizer {
    let maxTranscriptCharacters: Int
    let complete: MapReduceSummarizer.Complete

    public init(maxTranscriptCharacters: Int = 150_000, complete: @escaping MapReduceSummarizer.Complete) {
        self.maxTranscriptCharacters = maxTranscriptCharacters
        self.complete = complete
    }

    public func summarize(transcript: String, title: String) async throws -> String {
        let clipped = String(transcript.prefix(maxTranscriptCharacters))
        let facts = SummaryOutput.clean(try await complete(
            MeetingSummaryPrompt.map(transcript: clipped, title: title, maxLines: nil)))
        // Nothing extracted (an empty or odd reply): write from the transcript itself.
        guard !facts.isEmpty else {
            return try await complete(MeetingSummaryPrompt.build(transcript: clipped, title: title))
        }
        return try await complete(MeetingSummaryPrompt.reduce(parts: [facts], title: title))
    }
}
