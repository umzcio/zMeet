import Foundation
import Testing
@testable import ZMeetCore

@Test func meetingSummaryPromptHasRequiredSections() {
    let prompt = MeetingSummaryPrompt.build(transcript: "We shipped X.", title: "Sync")
    #expect(prompt.contains("## Summary"))
    #expect(prompt.contains("## Key Points"))
    #expect(prompt.contains("## Action Items"))
    #expect(prompt.contains("## Decisions"))
    #expect(prompt.contains("Sync"))
    #expect(prompt.contains("We shipped X."))
    #expect(prompt.contains("Do not invent"))
}

private let validNote = "## Summary\nok\n\n## Key Points\n- a\n\n## Action Items\n- None\n\n## Decisions\n- None"

/// Returns its answers in order (repeating the last), counting calls.
private final class ScriptedSummarizer: Summarizer, @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [Result<String, Error>]
    private(set) var calls = 0
    init(_ answers: [Result<String, Error>]) { self.answers = answers }
    func summarize(transcript: String, title: String) async throws -> String {
        let answer: Result<String, Error> = lock.withLock {
            calls += 1
            return answers.count > 1 ? answers.removeFirst() : answers[0]
        }
        return try answer.get()
    }
}

private struct Boom: Error {}

@Test func attributionForEveryOutcome() {
    #expect(SummaryEngine.onDevice.attribution == "Summary generated on-device")
    #expect(SummaryEngine.provider(.anthropic, model: "claude-sonnet-5").attribution
            == "Summary by Claude Sonnet 5 (Anthropic)")
    #expect(SummaryEngine.provider(.openAI, model: "gpt-5-mini").attribution == "Summary by gpt-5-mini (OpenAI)")
    #expect(SummaryEngine.provider(.ollama, model: "llama3.1:8b").attribution == "Summary by llama3.1:8b (Ollama)")
    #expect(SummaryEngine.onDeviceAfterFailure(.ollama).attribution
            == "Summary generated on-device (Ollama attempt failed)")
}

@Test func attributionEscapesMarkdownInModelNames() {
    #expect(SummaryEngine.provider(.ollama, model: "qwen2.5_coder*[x]`").attribution
            == #"Summary by qwen2.5\_coder\*\[x\]\` (Ollama)"#)
}

@Test func policyUsesRemoteWhenValid() async throws {
    let remote = ScriptedSummarizer([.success(validNote)])
    let onDevice = ScriptedSummarizer([.success("local")])
    let (md, engine) = try await SummarizationPolicy().summarize(
        transcript: "t", title: "x", provider: .openAI, model: "gpt-5-mini", remote: remote, onDevice: onDevice)
    #expect(md == validNote)
    #expect(engine == .provider(.openAI, model: "gpt-5-mini"))
    #expect(onDevice.calls == 0)
}

@Test func policyCleansRemoteOutput() async throws {
    let remote = ScriptedSummarizer([.success("<think>hmm</think>\n```markdown\n" + validNote + "\n```")])
    let (md, _) = try await SummarizationPolicy().summarize(
        transcript: "t", title: "x", provider: .ollama, model: "qwen3", remote: remote,
        onDevice: ScriptedSummarizer([.success("local")]))
    #expect(md == validNote)
}

@Test func policyFallsBackImmediatelyWhenRemoteThrows() async throws {
    let remote = ScriptedSummarizer([.failure(Boom())])
    let (md, engine) = try await SummarizationPolicy().summarize(
        transcript: "t", title: "x", provider: .ollama, model: "m", remote: remote,
        onDevice: ScriptedSummarizer([.success("local")]))
    #expect(md == "local")
    #expect(engine == .onDeviceAfterFailure(.ollama))
    #expect(remote.calls == 1)
}

@Test func policyRetriesOnceOnMalformedOutput() async throws {
    let remote = ScriptedSummarizer([.success("just prose"), .success(validNote)])
    let (md, engine) = try await SummarizationPolicy().summarize(
        transcript: "t", title: "x", provider: .anthropic, model: "claude-sonnet-5", remote: remote,
        onDevice: ScriptedSummarizer([.success("local")]))
    #expect(md == validNote)
    #expect(engine == .provider(.anthropic, model: "claude-sonnet-5"))
    #expect(remote.calls == 2)
}

@Test func policyFallsBackAfterTwoMalformedOutputs() async throws {
    let remote = ScriptedSummarizer([.success("just prose")])
    let (md, engine) = try await SummarizationPolicy().summarize(
        transcript: "t", title: "x", provider: .openAI, model: "gpt-5", remote: remote,
        onDevice: ScriptedSummarizer([.success("local")]))
    #expect(md == "local")
    #expect(engine == .onDeviceAfterFailure(.openAI))
    #expect(remote.calls == 2)
}

@Test func policyIgnoresRemoteWhenProviderIsOnDevice() async throws {
    let remote = ScriptedSummarizer([.success(validNote)])
    let (md, engine) = try await SummarizationPolicy().summarize(
        transcript: "t", title: "x", provider: .onDevice, model: "", remote: remote,
        onDevice: ScriptedSummarizer([.success("local")]))
    #expect(md == "local")
    #expect(engine == .onDevice)
    #expect(remote.calls == 0)
}

@Test func policyRunsOnDeviceWhenRemoteIsNotConfigured() async throws {
    let (md, engine) = try await SummarizationPolicy().summarize(
        transcript: "t", title: "x", provider: .ollama, model: "", remote: nil,
        onDevice: ScriptedSummarizer([.success("local")]))
    #expect(md == "local")
    #expect(engine == .onDevice)
}

@Test func extractEntitiesPromptRequestsLabeledFormat() {
    let p = MeetingSummaryPrompt.extractEntities(summary: "We discussed flights.", transcript: "Jonathan: ...")
    #expect(p.contains("PEOPLE:"))
    #expect(p.contains("PROJECTS:"))
    #expect(p.contains("TOPICS:"))
    #expect(p.lowercased().contains("none"))
    #expect(p.contains("flights"))
}

@Test func reducePromptHasSectionsAndParts() {
    let prompt = MeetingSummaryPrompt.reduce(parts: ["## Summary\n- Alpha", "## Summary\n- Beta"], title: "Sync")
    #expect(prompt.contains("## Summary"))
    #expect(prompt.contains("## Key Points"))
    #expect(prompt.contains("## Action Items"))
    #expect(prompt.contains("## Decisions"))
    #expect(prompt.contains("Sync"))
    #expect(prompt.contains("Alpha"))
    #expect(prompt.contains("Beta"))
    #expect(prompt.contains("Do not invent"))
}
