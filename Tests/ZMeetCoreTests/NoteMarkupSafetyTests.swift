import Foundation
import Testing
@testable import ZMeetCore

// Notes and Obsidian vault notes must never carry live HTML tags or Markdown image
// embeds: Obsidian renders inline HTML and fetches remote images, so a tag smuggled
// in by a summary (prompt injection) or a meeting title (e.g. an external Teams
// subject) would beacon the reader's IP and leak summary text.

/// The rendered body (YAML frontmatter removed: it is quoted data, not rendered).
private func body(_ note: String) -> String {
    guard note.hasPrefix("---\n"), let end = note.range(of: "\n---\n", range: note.index(note.startIndex, offsetBy: 4)..<note.endIndex)
    else { return note }
    return String(note[end.upperBound...])
}

/// True when the text still contains something a Markdown/HTML renderer would
/// treat as a tag, comment, declaration or image embed.
private func hasLiveMarkup(_ text: String) -> Bool {
    text.range(of: #"<[A-Za-z/!?]"#, options: .regularExpression) != nil || text.contains("![")
}

private let hostileTitle = #"Call <img src="https://x"> <iframe src="https://x"> ![](https://x)"#

private func session(title: String) -> MeetingSession {
    MeetingSession(id: "2026-10-25-090000-call", title: title, sourceApp: "Microsoft Teams", mode: .remote,
        startedAt: Date(timeIntervalSince1970: 1_780_000_000), endedAt: Date(timeIntervalSince1970: 1_780_003_480),
        status: .processed, audioPath: "/x/recording.m4a", transcriptPath: "/x/transcript.md",
        notePath: "/x/notes.md", recorderLogPath: nil, errorMessage: nil)
}

@Test func sanitizeNoteMarkdownNeutralizesEveryTagSpelling() {
    let attacks = [
        "<Img src=x>", "<iMG src=x>", "<IFRAME src=x>", "<iFrame src=x>", "<ScRiPt>alert(1)</sCrIpT>",
        "<video poster=x>", "<embed src=x>", "<svg><image href=x></svg>",
        #"<div style="background:url(x)">hi</div>"#, "<object data=x>", "<!-- c -->", "<?xml ?>",
        "<audio src=x>", "<link rel=stylesheet href=x>",
    ]
    for attack in attacks {
        #expect(!hasLiveMarkup(ZMeetText.sanitizeNoteMarkdown(attack)), "still live: \(attack)")
    }
}

@Test func sanitizeNoteMarkdownLeavesOrdinaryTextAlone() {
    let prose = "## Summary\n- Budget < $5M and 3 < 4\n- Ratio a<b only when spaced: a < b\n- [link](https://e.com)"
    #expect(ZMeetText.sanitizeNoteMarkdown(prose) == "## Summary\n- Budget < $5M and 3 < 4\n- Ratio a&lt;b only when spaced: a < b\n- [link](https://e.com)")
}

@Test func hostileTitleIsNeutralizedInNotesAndBothVaultNotes() {
    let s = session(title: hostileTitle)
    let notes = MarkdownRenderer().renderProcessedNote(session: s, transcriptURL: URL(fileURLWithPath: "/x/transcript.md"),
        noteURL: URL(fileURLWithPath: "/x/notes.md"), summaryMarkdown: "## Summary\nok")
    let main = ObsidianNoteRenderer.mainNote(session: s, summary: "## Summary\nok",
        entities: MeetingEntities(), transcriptNoteName: "T")
    let transcript = ObsidianNoteRenderer.transcriptNote(session: s, transcript: "[0:00] hello", mainNoteName: "M")
    for note in [notes, main, transcript] {
        #expect(!hasLiveMarkup(body(note)))
        #expect(body(note).contains("# Call &lt;img"))
    }
}

@Test func hostileSummaryIsNeutralizedInNotesAndVaultNote() {
    let s = session(title: "Weekly Sync")
    let summary = "## Summary\nok <Img src=\"https://x/?q=secret\"> <IFrame src=x> <video poster=x>"
    let notes = MarkdownRenderer().renderProcessedNote(session: s, transcriptURL: URL(fileURLWithPath: "/x/transcript.md"),
        noteURL: URL(fileURLWithPath: "/x/notes.md"), summaryMarkdown: summary)
    let main = ObsidianNoteRenderer.mainNote(session: s, summary: summary, entities: MeetingEntities(), transcriptNoteName: "T")
    #expect(!hasLiveMarkup(body(notes)))
    #expect(!hasLiveMarkup(body(main)))
}

@Test func hostileEntityAndNoteNamesCannotCarryTagsIntoWikilinks() {
    let s = session(title: "Weekly Sync")
    let main = ObsidianNoteRenderer.mainNote(session: s, summary: "ok",
        entities: MeetingEntities(people: ["Eve <img src=x>"], projects: ["<IFrame src=x>"], topics: []),
        transcriptNoteName: "2026-10-25 Call <img src=x> — Transcript")
    let transcript = ObsidianNoteRenderer.transcriptNote(session: s, transcript: "hi",
        mainNoteName: "2026-10-25 Call <svg onload=x>")
    #expect(!hasLiveMarkup(body(main)))
    #expect(!hasLiveMarkup(body(transcript)))
    #expect(main.contains("[[Eve img src=x]]"))
}
