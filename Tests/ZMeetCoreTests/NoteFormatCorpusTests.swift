import Foundation
import Testing
@testable import ZMeetCore

// Characterizes the three independent notes.md parsers — MarkdownRenderer.summaryBody,
// ZMeetText.noteSearchBody, and NoteDocument.parse (moved out of LibraryView's NoteBlock) —
// against one shared fixture corpus. This is NOT a spec for correct behavior: where the
// parsers disagree, the test records the divergence with a comment rather than fixing it.
// Prerequisite for the eventual parser-unification refactor (see plans/README.md).

private func processedNote(summary: String, title: String = "Weekly Sync") -> String {
    let session = MeetingSession(
        id: "2026-06-01-090000-sync", title: title, sourceApp: "Microsoft Teams",
        startedAt: Date(timeIntervalSince1970: 1_780_000_000), endedAt: Date(timeIntervalSince1970: 1_780_003_480),
        status: .processed, audioPath: "/x/recording.m4a", transcriptPath: "/x/transcript.md",
        notePath: "/x/notes.md", recorderLogPath: nil, errorMessage: nil)
    return MarkdownRenderer().renderProcessedNote(
        session: session,
        transcriptURL: URL(fileURLWithPath: "/x/transcript.md"),
        noteURL: URL(fileURLWithPath: "/x/notes.md"),
        summaryMarkdown: summary)
}

// MARK: - Fixture (a): full renderProcessedNote output

@Test func corpusFullRenderedNote() {
    let summary = "## Summary\n\n- Discussed flights.\n\n## Action Items\n\n- Book the trip."
    let note = processedNote(summary: summary)

    let summaryBody = MarkdownRenderer().summaryBody(fromProcessedNote: note)
    let searchBody = ZMeetText.noteSearchBody(note)
    let elements = NoteDocument.parse(note)

    #expect(summaryBody == summary)
    // DIVERGENCE: noteSearchBody drops ALL heading lines outright (any line with a "#"
    // prefix, including interior ones), collapsing "## Action Items" to nothing — whereas
    // summaryBody keeps interior headings verbatim (only the leading "# Title" is special).
    // NoteDocument.parse instead turns them into structured .h2 elements. Net effect: the
    // search index loses the "Action Items" label text that both other views retain.
    #expect(searchBody == "- Discussed flights.\n\n\n- Book the trip.")
    #expect(elements == [
        .h2("Summary"),
        .bullet("Discussed flights."),
        .h2("Action Items"),
        .bullet("Book the trip.")
    ])
}

// MARK: - Fixture (b): frontmatter absent

@Test func corpusFrontmatterAbsent() {
    let note = "# Weekly Sync\n\n## Summary\n\n- Discussed flights.\n\n## Transcript\n\n[Open transcript](transcript.md)\n\n_Summary generated on-device_"

    let summaryBody = MarkdownRenderer().summaryBody(fromProcessedNote: note)
    let searchBody = ZMeetText.noteSearchBody(note)
    let elements = NoteDocument.parse(note)

    // All three tolerate a missing frontmatter block (the "---" check is conditional) and
    // agree on the result.
    #expect(summaryBody == "## Summary\n\n- Discussed flights.")
    #expect(searchBody == "- Discussed flights.")
    #expect(elements == [.h2("Summary"), .bullet("Discussed flights.")])
}

// MARK: - Fixture (c): "## Transcript" absent

@Test func corpusTranscriptSectionAbsent() {
    let note = "---\nid: \"x\"\n---\n\n# Weekly Sync\n\n## Summary\n\n- Discussed flights."

    let summaryBody = MarkdownRenderer().summaryBody(fromProcessedNote: note)
    let searchBody = ZMeetText.noteSearchBody(note)
    let elements = NoteDocument.parse(note)

    // All three tolerate a missing transcript section — nothing to cut, body runs to the
    // end, and all three agree.
    #expect(summaryBody == "## Summary\n\n- Discussed flights.")
    #expect(searchBody == "- Discussed flights.")
    #expect(elements == [.h2("Summary"), .bullet("Discussed flights.")])
}

// MARK: - Fixture (d): summary containing "## Transcript of the call" (false-positive hazard)

@Test func corpusSummaryContainsTranscriptOfTheCallHeading() {
    let summary = "## Transcript of the call\n\n- Key point.\n\n## Decisions\n\n- Ship it."
    let note = processedNote(summary: summary)

    let summaryBody = MarkdownRenderer().summaryBody(fromProcessedNote: note)
    let searchBody = ZMeetText.noteSearchBody(note)
    let elements = NoteDocument.parse(note)

    // All three guard this hazard the same way: an EXACT (not prefix) line match against
    // "## Transcript" / "## transcript", so "## Transcript of the call" is never mistaken
    // for the appended transcript-link section. The full summary — including its own
    // "Transcript of the call" heading — survives in all three, and the real appended
    // "## Transcript" section further down is the one that gets cut/skipped.
    #expect(summaryBody == summary)
    #expect(searchBody == "- Key point.\n\n\n- Ship it.")
    #expect(elements == [
        .h2("Transcript of the call"),
        .bullet("Key point."),
        .h2("Decisions"),
        .bullet("Ship it.")
    ])
}

// MARK: - Fixture (e): no "# Title" heading

@Test func corpusNoTitleHeading() {
    let note = "---\nid: \"x\"\n---\n\n## Summary\n\n- Discussed flights.\n\n## Transcript\n\n[Open transcript](transcript.md)"

    let summaryBody = MarkdownRenderer().summaryBody(fromProcessedNote: note)
    let searchBody = ZMeetText.noteSearchBody(note)
    let elements = NoteDocument.parse(note)

    // Absence of "# Title" is harmless everywhere — it's an optional strip in all three,
    // and all three agree on the result.
    #expect(summaryBody == "## Summary\n\n- Discussed flights.")
    #expect(searchBody == "- Discussed flights.")
    #expect(elements == [.h2("Summary"), .bullet("Discussed flights.")])
}

// MARK: - Fixture (f): empty string

@Test func corpusEmptyString() {
    let note = ""

    let summaryBody = MarkdownRenderer().summaryBody(fromProcessedNote: note)
    let searchBody = ZMeetText.noteSearchBody(note)
    let elements = NoteDocument.parse(note)

    #expect(summaryBody == "")
    #expect(searchBody == "")
    #expect(elements == [])
}

// MARK: - Fixture (g): CRLF line endings

@Test func corpusCRLFLineEndings() {
    let summary = "## Summary\n\n- Discussed flights."
    let note = processedNote(summary: summary).replacingOccurrences(of: "\n", with: "\r\n")

    let summaryBody = MarkdownRenderer().summaryBody(fromProcessedNote: note)
    let searchBody = ZMeetText.noteSearchBody(note)
    let elements = NoteDocument.parse(note)

    // DIVERGENCE (all three, differently broken): every parser splits on "\n" only,
    // leaving a trailing "\r" Character on each line (Swift's grapheme-cluster String
    // merges an adjacent \r+\n into one Character, but split(separator: "\n") consumes
    // the \n, so each line keeps a lone, un-merged \r). CharacterSet.whitespaces (used by
    // noteSearchBody's and NoteDocument.parse's trims) does NOT include \r — that's
    // .newlines — so "---\r" != "---" and "## transcript\r" != "## transcript":
    // frontmatter stripping and the transcript-section cut both silently fail to fire.
    //
    // summaryBody is worst off: its frontmatter check (`lines.first == "---"`) doesn't
    // trim AT ALL, so under CRLF it never strips frontmatter, and its "## Transcript"
    // check is likewise an untrimmed exact match that never fires either — the entire
    // frontmatter + transcript link + attribution survive verbatim as the "body".
    #expect(summaryBody == note)

    // noteSearchBody: hasPrefix("#") is unaffected by a trailing \r, so heading lines
    // ("# Weekly Sync\r", "## Summary\r", "## Transcript\r") are still dropped — but the
    // frontmatter body lines ("id: ...\r", "title: ...\r", etc.) are NOT headings, so they
    // are NOT dropped, and (since the "## transcript\r" break condition never matches)
    // iteration runs to the end, so the transcript link and attribution leak through too.
    let expectedSearchBody = "---\r\nid: \"2026-06-01-090000-sync\"\r\ntitle: \"Weekly Sync\"\r\n"
        + "started_at: \"2026-05-28T20:26:40Z\"\r\nended_at: \"2026-05-28T21:24:40Z\"\r\n"
        + "source_app: \"Microsoft Teams\"\r\nstatus: \"processed\"\r\naudio_path: \"/x/recording.m4a\"\r\n"
        + "transcript: \"transcript.md\"\r\nduration_seconds: 3480\r\n---\r\n\r\n\r\n\r\n- Discussed flights.\r\n\r\n\r\n"
        + "[Open transcript](transcript.md)\r\n\r\n_Summary generated on-device_"
    #expect(searchBody == expectedSearchBody)

    // NoteDocument.parse: the frontmatter "---\r" line fails the trimmed "---" equality,
    // so it and every frontmatter field render as literal .paragraph elements instead of
    // being stripped. "# Weekly Sync\r" DOES still match `hasPrefix("# ")` (prefix
    // matching survives the trailing \r) so the title is still dropped as designed. But
    // "## Transcript\r" fails the exact lowercase match, so it renders as a normal .h2
    // instead of being the cut point, and the transcript-link paragraph follows it.
    #expect(elements == [
        .paragraph("---\r"),
        .paragraph("id: \"2026-06-01-090000-sync\"\r"),
        .paragraph("title: \"Weekly Sync\"\r"),
        .paragraph("started_at: \"2026-05-28T20:26:40Z\"\r"),
        .paragraph("ended_at: \"2026-05-28T21:24:40Z\"\r"),
        .paragraph("source_app: \"Microsoft Teams\"\r"),
        .paragraph("status: \"processed\"\r"),
        .paragraph("audio_path: \"/x/recording.m4a\"\r"),
        .paragraph("transcript: \"transcript.md\"\r"),
        .paragraph("duration_seconds: 3480\r"),
        .paragraph("---\r"),
        .paragraph("\r"),
        .paragraph("\r"),
        .h2("Summary\r"),
        .paragraph("\r"),
        .bullet("Discussed flights.\r"),
        .paragraph("\r"),
        .h2("Transcript\r"),
        .paragraph("\r"),
        .paragraph("[Open transcript](transcript.md)\r"),
        .paragraph("\r"),
        .paragraph("_Summary generated on-device_")
    ])
}
