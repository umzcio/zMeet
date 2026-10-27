import Foundation
import Testing
@testable import ZMeetCore

private let fullNotes = """
## Summary
Shipped.

**On the call:** Not stated

## Release
- Out today

## Decisions
- None

## Action Items
- None

## Open Questions & Checks
- None
"""

private let compactNotes = "## Summary\nShipped.\n\n## Key Points\n- a\n\n## Action Items\n- None\n\n## Decisions\n- None"

/// Answers compact prompts with `compact` and everything else with `full`.
private final class FormatModel: @unchecked Sendable {
    private let lock = NSLock()
    private var log: [String] = []
    let full: String
    init(full: String) { self.full = full }
    var prompts: [String] { lock.withLock { log } }
    var complete: MapReduceSummarizer.Complete {
        { [self] prompt in
            lock.withLock { log.append(prompt) }
            return prompt.contains("## Key Points") ? compactNotes : full
        }
    }
}

@Test func fullFormatResultIsKeptWhenValid() async throws {
    let model = FormatModel(full: fullNotes)
    let out = try await StructuredNotesSummarizer(maxChunkCharacters: 1_000, complete: model.complete)
        .summarize(transcript: "We shipped.", title: "Sync")
    #expect(out == fullNotes)
    #expect(model.prompts.count == 1)
}

@Test func fallsBackToCompactWhenFullFormatFailsAnchors() async throws {
    let model = FormatModel(full: "blah")
    let out = try await StructuredNotesSummarizer(maxChunkCharacters: 1_000, complete: model.complete)
        .summarize(transcript: "We shipped.", title: "Sync")
    #expect(SummaryOutput.hasRequiredSections(out))
    #expect(out.contains("## Key Points"))
    #expect(model.prompts.count == 2)
}

@Test func fullFormatResultIsCleanedBeforeTheCheck() async throws {
    let model = FormatModel(full: "```\n" + fullNotes + "\n```")
    let out = try await StructuredNotesSummarizer(maxChunkCharacters: 1_000, complete: model.complete)
        .summarize(transcript: "We shipped.", title: "Sync")
    #expect(out == fullNotes)
}

@Test func anthropicRequestLeavesRoomForThinking() throws {
    let req = try AnthropicSummary.makeRequest(key: "k", prompt: "p")
    let body = try #require(req.httpBody)
    let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
    // Sonnet 5 thinks by default and thinking tokens count toward max_tokens:
    // 4096 left notes truncated or empty, and fact extraction nearly filled
    // 16,000. Streaming lets the cap be high without hitting the idle timeout.
    #expect(json["max_tokens"] as? Int == 64_000)
    #expect(json["stream"] as? Bool == true)
}

@Test func aThrownFullAttemptStillReachesCompact() async throws {
    // The full prompts are larger; a context overflow or guardrail error on them
    // must not skip straight past the compact notes.
    struct Overflow: Error {}
    let out = try await StructuredNotesSummarizer(maxChunkCharacters: 1_000) { prompt in
        if prompt.contains("## Key Points") { return compactNotes }
        throw Overflow()
    }.summarize(transcript: "We shipped.", title: "Sync")
    #expect(out.contains("## Key Points"))
}

@Test func cancellationIsNotRetriedAsCompact() async {
    await #expect(throws: CancellationError.self) {
        _ = try await StructuredNotesSummarizer(maxChunkCharacters: 1_000) { _ in throw CancellationError() }
            .summarize(transcript: "We shipped.", title: "Sync")
    }
}
