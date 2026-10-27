import Foundation

/// Asks for the full structured notes and, if the answer fails the anchor
/// check or the attempt throws, asks again for the compact four-section notes — so a small model
/// that can't manage the full format still produces valid notes, just leaner.
/// Used for on-device summaries.
public struct StructuredNotesSummarizer: Summarizer {
    let maxChunkCharacters: Int
    let complete: MapReduceSummarizer.Complete

    public init(maxChunkCharacters: Int, complete: @escaping MapReduceSummarizer.Complete) {
        self.maxChunkCharacters = maxChunkCharacters
        self.complete = complete
    }

    public func summarize(transcript: String, title: String) async throws -> String {
        // The full prompts are larger, so they're likelier to throw (context
        // overflow, guardrails): that falls back to compact too. Cancellation
        // means the user stopped processing, so it propagates.
        do {
            let full = SummaryOutput.clean(try await MapReduceSummarizer(
                maxChunkCharacters: maxChunkCharacters, format: .full, complete: complete
            ).summarize(transcript: transcript, title: title))
            if SummaryOutput.hasRequiredSections(full) { return full }
        } catch is CancellationError {
            throw CancellationError()
        } catch {}
        return SummaryOutput.clean(try await MapReduceSummarizer(
            maxChunkCharacters: maxChunkCharacters, format: .compact, complete: complete
        ).summarize(transcript: transcript, title: title))
    }
}
