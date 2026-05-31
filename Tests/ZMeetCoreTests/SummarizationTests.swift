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
