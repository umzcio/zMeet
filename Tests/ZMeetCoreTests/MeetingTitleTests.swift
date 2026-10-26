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

@Test func placeholderTitlesAreRecognized() {
    let placeholders = [
        "", "   ", "Untitled Meeting", "Zoom Meeting", "zoom meeting", "Zoom Webinar", "Zoom",
        "Teams Meeting", "Microsoft Teams Meeting", "Microsoft Teams",
        "Microsoft Teams Meeting | Microsoft Teams",
        "Zach Rossmiller (CIO, Example U)'s Zoom Meeting",
        "Pat’s Zoom Meeting",                                  // curly apostrophe
        "Jane Doe's Personal Meeting Room",
        "Meeting with Doe, Jane (Example U) | Microsoft Teams",
    ]
    for title in placeholders {
        #expect(MeetingTitle.isPlaceholder(title), "should be a placeholder: \(title)")
    }
}

@Test func realTitlesAreNeverPlaceholders() {
    let real = [
        "Weekly Sync | Microsoft Teams", "Apex Trust Bridge — Big Sky Briefing", "Budget Review",
        "Meeting with Bob", "Zoom Meeting Prep for Board", "Teams Meeting Retro Notes",
        "CU Boulder VCIT Interview Preparation Session",
    ]
    for title in real {
        #expect(!MeetingTitle.isPlaceholder(title), "should be kept: \(title)")
    }
}
