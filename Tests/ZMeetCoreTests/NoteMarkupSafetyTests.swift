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
/// treat as a tag, comment, declaration or image embed. Checked per Unicode
/// scalar, as renderers parse: a String/Character search would miss "![" or
/// "<img" fused with a combining or prepend mark into one grapheme.
private func hasLiveMarkup(_ text: String) -> Bool {
    let scalars = Array(text.unicodeScalars)
    for (i, s) in scalars.enumerated() where i + 1 < scalars.count {
        let n = scalars[i + 1]
        if s == "!" && n == "[" { return true }
        if s == "<" && (n.properties.isAlphabetic || "/!?".unicodeScalars.contains(n)) { return true }
    }
    return false
}

/// The finding's attacks: a mark after "[" or a prepend scalar before "!"/"<"
/// fuses the syntax into one grapheme that a Character check doesn't match.
private let markSmuggled = ["![\u{301}](https://x)", "![\u{FE0F}](https://x)", "\u{D4E}![](https://x)",
                            "\u{600}<img src=https://x>", "\u{D4E}<img src=https://x>"]

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

@Test func repeatedBangsCannotReformAnImageEmbed() {
    for attack in ["!![](https://x)", "!!![](https://x)", "a !![b](https://x) c", "!!!![x](y)"] {
        #expect(!ZMeetText.sanitizeNoteMarkdown(attack).contains("!["), "re-formed: \(attack)")
    }
    #expect(ZMeetText.sanitizeNoteMarkdown("Weekly call !![](https://x)") == "Weekly call [](https://x)")
}

@Test func repeatedBangTitleAndSummaryStayInertInNotesAndBothVaultNotes() {
    let s = session(title: "Weekly call !![](https://x/b)")
    let summary = "## Summary\nok !!![](https://x/?q=secret)"
    let notes = MarkdownRenderer().renderProcessedNote(session: s, transcriptURL: URL(fileURLWithPath: "/x/transcript.md"),
        noteURL: URL(fileURLWithPath: "/x/notes.md"), summaryMarkdown: summary)
    let main = ObsidianNoteRenderer.mainNote(session: s, summary: summary, entities: MeetingEntities(), transcriptNoteName: "T")
    let transcript = ObsidianNoteRenderer.transcriptNote(session: s, transcript: "!![](https://x)", mainNoteName: "M")
    for note in [notes, main, transcript] {
        #expect(!hasLiveMarkup(body(note)))
        #expect(body(note).contains("# Weekly call [](https://x/b)"))
    }
}

@Test func sanitizerNeutralizesMarkupFusedWithMarks() {
    for attack in markSmuggled {
        #expect(!hasLiveMarkup(ZMeetText.sanitizeNoteMarkdown(attack)), "still live: \(attack.unicodeScalars.map { String($0.value, radix: 16) })")
    }
}

@Test func markSmuggledTitlesAndSummariesAreNeutralizedInEveryRenderedNote() {
    for attack in markSmuggled {
        let s = session(title: "Weekly Call " + attack)
        let summary = "## Summary\nok " + attack
        let notes = MarkdownRenderer().renderProcessedNote(session: s, transcriptURL: URL(fileURLWithPath: "/x/transcript.md"),
            noteURL: URL(fileURLWithPath: "/x/notes.md"), summaryMarkdown: summary)
        let main = ObsidianNoteRenderer.mainNote(session: s, summary: summary, entities: MeetingEntities(), transcriptNoteName: "T")
        let transcript = ObsidianNoteRenderer.transcriptNote(session: s, transcript: "[0:00] " + attack, mainNoteName: "M")
        for note in [notes, main, transcript] { #expect(!hasLiveMarkup(body(note))) }
    }
}

@Test func storedTitlesCannotCarryMarkupEvenWithoutTheNoteSanitizer() {
    // Defense in depth: a window title is organizer-controlled, so it is
    // neutralized when stored, not only when rendered.
    for raw in ["![\u{301}](https://x) Weekly Call", "\u{D4E}<img src=https://x> Weekly Call",
                "<IFRAME src=x> Call", "!![](https://x) Call"] {
        #expect(!hasLiveMarkup(ZMeetText.sanitizeTitle(raw)), "still live: \(raw)")
    }
    #expect(ZMeetText.sanitizeTitle("Café Weekly Call") == "Café Weekly Call")
    #expect(ZMeetText.sanitizeTitle("Budget: a < b [draft]") == "Budget: a < b [draft]")
}
