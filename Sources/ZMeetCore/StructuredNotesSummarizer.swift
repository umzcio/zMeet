import Foundation

/// Asks for the full structured notes and, if the answer fails the anchor
/// check, asks again for the compact four-section notes — so a small model
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
        let full = SummaryOutput.clean(try await MapReduceSummarizer(
            maxChunkCharacters: maxChunkCharacters, format: .full, complete: complete
        ).summarize(transcript: transcript, title: title))
        if SummaryOutput.hasRequiredSections(full) { return full }
        return SummaryOutput.clean(try await MapReduceSummarizer(
            maxChunkCharacters: maxChunkCharacters, format: .compact, complete: complete
        ).summarize(transcript: transcript, title: title))
    }
}
