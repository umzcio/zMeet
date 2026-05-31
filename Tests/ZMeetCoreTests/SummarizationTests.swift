import Testing
@testable import ZMeetCore

@Test func summaryEngineAttributionStrings() {
    #expect(SummaryEngine.onDevice.attribution == "Summary generated on-device")
    #expect(SummaryEngine.cloud.attribution == "Summary by Claude Sonnet (cloud)")
}

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

private struct CannedSummarizer: Summarizer {
    let text: String
    final class Calls: @unchecked Sendable { var count = 0 }
    let calls = Calls()
    func summarize(transcript: String, title: String) async throws -> String {
        calls.count += 1
        return text
    }
}

private struct ThrowingSummarizer: Summarizer {
    struct Boom: Error {}
    func summarize(transcript: String, title: String) async throws -> String { throw Boom() }
}

@Test func policyUsesCloudWhenEnabledAndSucceeds() async throws {
    let onDevice = CannedSummarizer(text: "local")
    let cloud = CannedSummarizer(text: "cloud")
    let (md, engine) = try await SummarizationPolicy().summarize(
        transcript: "t", title: "x", useCloud: true, onDevice: onDevice, cloud: cloud)
    #expect(md == "cloud")
    #expect(engine == .cloud)
    #expect(onDevice.calls.count == 0)
}

@Test func policyFallsBackToOnDeviceWhenCloudThrows() async throws {
    let onDevice = CannedSummarizer(text: "local")
    let (md, engine) = try await SummarizationPolicy().summarize(
        transcript: "t", title: "x", useCloud: true, onDevice: onDevice, cloud: ThrowingSummarizer())
    #expect(md == "local")
    #expect(engine == .onDevice)
}

@Test func policyUsesOnDeviceWhenDisabled() async throws {
    let onDevice = CannedSummarizer(text: "local")
    let cloud = CannedSummarizer(text: "cloud")
    let (md, engine) = try await SummarizationPolicy().summarize(
        transcript: "t", title: "x", useCloud: false, onDevice: onDevice, cloud: cloud)
    #expect(md == "local")
    #expect(engine == .onDevice)
    #expect(cloud.calls.count == 0)
}

@Test func policyUsesOnDeviceWhenNoCloudProvided() async throws {
    let onDevice = CannedSummarizer(text: "local")
    let (md, engine) = try await SummarizationPolicy().summarize(
        transcript: "t", title: "x", useCloud: true, onDevice: onDevice, cloud: nil)
    #expect(md == "local")
    #expect(engine == .onDevice)
}
