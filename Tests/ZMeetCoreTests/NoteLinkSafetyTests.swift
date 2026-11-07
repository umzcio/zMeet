import Foundation
import Testing
@testable import ZMeetCore

// (An angle-bracket destination like [a](<https://…>) loses its link: the HTML
// tag rule escapes its "<" first. Inert is the safe direction.)
// A model can be steered (by speech or the meeting title) into writing links.
// Only web and mail links may stay live in a note; anything else would hand a
// click to whatever app owns the scheme (smb mounts, Terminal via ssh, deep links).

@Test func webAndMailLinksStayLive() {
    for link in ["[site](https://e.com/a?b=1&c=2)", "[x](http://e.com)", "[X](HTTPS://E.COM)",
                 "[mail](mailto:a@b.com)", "[w](https://en.wikipedia.org/wiki/Foo_(bar))"] {
        #expect(ZMeetText.sanitizeNoteMarkdown(link) == link, "changed: \(link)")
    }
}

@Test func otherSchemesBecomePlainText() {
    let cases = [
        "[Slides](smb://attacker/share)": "Slides",
        "[Open](file:///Applications/Utilities/Terminal.app)": "Open",
        "[Join](zoommtg://zoom.us/join?confno=1)": "Join",
        "[Login](ssh://x@h)": "Login",
        "[Code](vscode://file/etc/passwd)": "Code",
        "[Run](javascript:alert(1))": "Run)",
        "[Rel](notes.md)": "Rel",
        "[Angle](<smb://h/s>)": "Angle",
        "[Entity](&#115;mb://h/s)": "Entity",
        "[Escaped](\\smb://h/s)": "Escaped",
        "[Titled](smb://h/s \"Slides\")": "Titled",
        "[Spaced]( smb://h/s )": "Spaced",
    ]
    for (input, expected) in cases {
        #expect(ZMeetText.sanitizeNoteMarkdown(input) == expected, "\(input)")
    }
}

@Test func referenceStyleLinksAreAlwaysInert() {
    // Only verified inline web links stay live; reference definitions and
    // reference links never form, whatever their destination.
    let md = "See [the slides][s] and [the site][w].\n\n[s]: smb://attacker/share\n  [w]: https://e.com"
    let out = ZMeetText.sanitizeNoteMarkdown(md)
    #expect(parsedLinks(out).isEmpty)
    #expect(out.contains("smb://attacker/share") && out.contains("https://e.com"))   // kept as text
}

@Test func linksInsideProseAreHandledInPlace() {
    #expect(ZMeetText.sanitizeNoteMarkdown("- Deck: [Slides](smb://h/s), site: [E](https://e.com).")
            == "- Deck: Slides, site: [E](https://e.com).")
}

@Test func titlesCannotCarryLiveLinksEither() {
    #expect(ZMeetText.sanitizeTitle("Weekly Call [join](zoommtg://x)") == "Weekly Call join")
}

@Test func onlyWebAndMailLinksAreOpenable() {
    for s in ["https://e.com", "http://e.com", "mailto:a@b.com", "HTTPS://E.COM"] {
        #expect(ZMeetText.isOpenableNoteLink(URL(string: s)!), "\(s)")
    }
    for s in ["smb://h/s", "file:///etc/passwd", "zoommtg://x", "ssh://h", "vscode://x", "notes.md", "x-apple.systempreferences:x"] {
        #expect(!ZMeetText.isOpenableNoteLink(URL(string: s)!), "\(s)")
    }
}

// MARK: - Backstop: shapes the one-pass pattern can't see

/// Every link a Markdown parser finds in `text` (block-level parse, so
/// reference definitions count too).
private func parsedLinks(_ text: String) -> [URL] {
    guard let attributed = try? AttributedString(
        markdown: text, options: .init(interpretedSyntax: .full, failurePolicy: .returnPartiallyParsedIfPossible))
    else { return [] }
    return attributed.runs.compactMap(\.link)
}

private let shapesThePatternMisses = [
    "[[Slides](deck)](ssh://h)",
    "[a [b] c](smb://h)",
    "[a\\]b](file:///x)",
    "[two\nlines](smb://h)",
    "[next](\nsmb://h)",
    "[re\\]f]: smb://h\n\nSee [re\\]f].",
    "[s]:\nsmb://h\n\nSee [s].",
    "[full][r]\n\n[r]: smb://h",
    "[collapsed][]\n\n[collapsed]: ssh://h",
    "Review Meeting [Deck [final]](smb://attacker/share)",
]

@Test func noNonWebLinkSurvivesInAnyShape() {
    for input in shapesThePatternMisses {
        for out in [ZMeetText.sanitizeNoteMarkdown(input),
                    ZMeetText.sanitizeNoteMarkdown(ZMeetText.sanitizeTitle(input))] {
            let bad = parsedLinks(out).filter { !ZMeetText.isOpenableNoteLink($0) }
            #expect(bad.isEmpty, "live: \(bad) from \(input.debugDescription) → \(out.debugDescription)")
        }
    }
}

@Test func theBackstopHoldsInRenderedNotesToo() {
    for input in shapesThePatternMisses {
        let s = MeetingSession(id: "2026-11-06-090000-call", title: "Weekly Call " + input, sourceApp: "Zoom",
            startedAt: Date(timeIntervalSince1970: 1_780_000_000), endedAt: Date(timeIntervalSince1970: 1_780_003_480),
            status: .processed, audioPath: "/x/recording.m4a", transcriptPath: "/x/transcript.md",
            notePath: "/x/notes.md", recorderLogPath: nil, errorMessage: nil)
        let summary = "## Summary\nok\n\n" + input
        let notes = MarkdownRenderer().renderProcessedNote(session: s, transcriptURL: URL(fileURLWithPath: "/x/transcript.md"),
            noteURL: URL(fileURLWithPath: "/x/notes.md"), summaryMarkdown: summary)
        let main = ObsidianNoteRenderer.mainNote(session: s, summary: summary, entities: MeetingEntities(), transcriptNoteName: "T")
        for note in [notes, main] {
            let bad = parsedLinks(note).filter { !ZMeetText.isOpenableNoteLink($0) && $0.scheme != nil }
            #expect(bad.isEmpty, "live in rendered note: \(bad) from \(input.debugDescription)")
        }
    }
}

@Test func backstopLeavesWebLinksAndOrdinaryBracketsAlone() {
    let md = "- [0:05] Pat: see [the site](https://e.com) and [mail](mailto:a@b.com).\n- Options [a] and [b] are open."
    #expect(ZMeetText.sanitizeNoteMarkdown(md) == md)
    #expect(parsedLinks(ZMeetText.sanitizeNoteMarkdown("[nested [site](https://e.com)](ssh://h)"))
                .map(\.absoluteString) == ["https://e.com"])
}

@Test func frontmatterValuesCarryNoMarkdownBracketsOrTags() {
    // Viewers without frontmatter support render these lines as Markdown, and
    // titles/entity names are attacker-influenced. YAML decodes \uXXXX back to
    // the same characters, so YAML readers see the exact value.
    let quoted = ZMeetText.yamlQuote(#"Deck [final](smb://h) <img src=x> "q" \ end"#)
    #expect(!quoted.contains("[") && !quoted.contains("]") && !quoted.contains("<") && !quoted.contains(">"))
    #expect(quoted == #""Deck \u005Bfinal\u005D(smb://h) \u003Cimg src=x\u003E \"q\" \\ end""#)
}
