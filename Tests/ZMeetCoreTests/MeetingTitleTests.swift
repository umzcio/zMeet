import Foundation
import Testing
@testable import ZMeetCore

@Test func cleanPassesThroughAPlainTitle() {
    #expect(MeetingTitle.clean("Affiliate Campus Billing") == "Affiliate Campus Billing")
}

@Test func cleanStripsQuotesLabelAndMarkdown() {
    #expect(MeetingTitle.clean("\"Budget Review\"") == "Budget Review")
    #expect(MeetingTitle.clean("Title: Banner SaaS Planning") == "Banner SaaS Planning")
    #expect(MeetingTitle.clean("**Standup**") == "Standup")
    #expect(MeetingTitle.clean("- Quarterly Planning") == "Quarterly Planning")
}

@Test func cleanKeepsOnlyFirstLineAndCollapsesSpaces() {
    #expect(MeetingTitle.clean("Affiliate   Billing\n\nblah blah") == "Affiliate Billing")
}

@Test func cleanReturnsNilForEmptyOrJunk() {
    #expect(MeetingTitle.clean("") == nil)
    #expect(MeetingTitle.clean("   \n  ") == nil)
    #expect(MeetingTitle.clean("\"\"") == nil)
}

@Test func titlePromptAsksForShortPlainTitle() {
    let p = MeetingSummaryPrompt.titlePrompt(summary: "We discussed affiliate billing.")
    #expect(p.lowercased().contains("title"))
    #expect(p.contains("affiliate billing"))
}
