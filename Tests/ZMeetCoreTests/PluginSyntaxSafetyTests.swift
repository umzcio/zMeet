import Foundation
import Testing
@testable import ZMeetCore

// Obsidian plugins execute some note syntax: Templater runs <% … %> tags in new
// files, and Dataview runs `$= …` / `= …` code spans and dataview/dataviewjs
// fences. Titles (organizer-set) and summaries (steerable) must never carry them.

/// Whether a Markdown parser finds any code span or code block in `text`.
private func hasCode(_ text: String) -> Bool {
    guard let attributed = try? AttributedString(
        markdown: text, options: .init(interpretedSyntax: .full, failurePolicy: .returnPartiallyParsedIfPossible))
    else { return false }
    return attributed.runs.contains { run in
        run.inlinePresentationIntent?.contains(.code) == true
            || run.presentationIntent?.components.contains { if case .codeBlock = $0.kind { return true } else { return false } } == true
    }
}

private let templaterTags = ["Weekly <% tp.system.exec('id') %> Meeting", "<%* await tp.file.create_new() %>",
                             "<%+ tp.date.now() %>", "<%- x -%>", "<\u{301}% x %>"]
private let codeForms = ["`$= dv.pages().length`", "`= this.file.name`", "```dataviewjs\ndv.span(1)\n```",
                         "~~~dataviewjs\ndv.span(1)\n~~~", "- ```js\nx\n```", "> ~~~\nx\n~~~", "``double ` tick``",
                         "\\\\`$= x`"] + indentedCodeForms
// Indented code blocks: 4+ columns past the container's content column, after a
// blank line (an indented line can't interrupt a paragraph), with spaces or tabs,
// at top level, inside a list item or block quote, or right after a marker.
private let indentedCodeForms = ["\n\n    $= dv.pages().length", "\n\n\t= this.file.name", "\n\n \t = x",
                                 "\n\n- item\n\n      = this.file.name", "\n\n- a\n  - b\n\n          = x",
                                 "\n\n> quote\n>\n>     = this.file.name", "\n\n-     = this.file.name",
                                 "\n\n1.      = x", "\n\n> -      = x", "\n\n>\t\t= x", "\n\n-\n\n      = x",
                                 // CRLF and bare CR are line endings too.
                                 "\r\n\r\n    = x", "\r\r    = x", "\n\r\n    = x", "\r\n\r\n-      = x",
                                 // A defanged link's text lands at the line start, or right after a marker.
                                 "\n\n[    = x](smb://h)", "\n\n- [     = x](smb://h)", "\n\n> [\t\t= x](smb://h)",
                                 "\n\n[-      = x](smb://h)", "\n\n   [ \t= x](smb://h)", "\n\n[x\r    = x](smb://h)"]

@Test func templaterTagsNeverSurvive() {
    for input in templaterTags {
        for out in [ZMeetText.sanitizeNoteMarkdown(input), ZMeetText.sanitizeTitle(input)] {
            #expect(!out.unicodeScalars.split(separator: "<").dropFirst().contains { $0.first == "%" }
                    && !out.contains("<%"), "live: \(out.debugDescription)")
        }
    }
}

@Test func noCodeSpanOrFenceCanForm() {
    for input in codeForms {
        for out in [ZMeetText.sanitizeNoteMarkdown(input), ZMeetText.sanitizeNoteMarkdown(ZMeetText.sanitizeTitle(input))] {
            #expect(!hasCode(out), "code survives: \(input.debugDescription) → \(out.debugDescription)")
        }
    }
}

@Test func pluginSyntaxIsInertInEveryVaultNote() {
    for input in templaterTags + codeForms {
        let s = MeetingSession(id: "2026-11-20-090000-call", title: "Call " + input, sourceApp: "Microsoft Teams",
            startedAt: Date(timeIntervalSince1970: 1_780_000_000), endedAt: Date(timeIntervalSince1970: 1_780_003_480),
            status: .processed, audioPath: "/x/recording.m4a", transcriptPath: "/x/transcript.md",
            notePath: "/x/notes.md", recorderLogPath: nil, errorMessage: nil)
        let main = ObsidianNoteRenderer.mainNote(session: s, summary: "## Summary\nok " + input,
            entities: MeetingEntities(), transcriptNoteName: "T")
        let transcript = ObsidianNoteRenderer.transcriptNote(session: s, transcript: "[0:00] " + input, mainNoteName: "M")
        let notes = MarkdownRenderer().renderProcessedNote(session: s, transcriptURL: URL(fileURLWithPath: "/x/transcript.md"),
            noteURL: URL(fileURLWithPath: "/x/notes.md"), summaryMarkdown: "## Summary\nok " + input)
        let republished = ObsidianNoteRenderer.mainNote(session: s,
            summary: MarkdownRenderer().summaryBody(fromProcessedNote: notes), entities: MeetingEntities(), transcriptNoteName: "T")
        for note in [main, transcript, notes, republished] {
            #expect(!note.contains("<%"), "templater tag in note from \(input.debugDescription)")
            #expect(!hasCode(note), "code in note from \(input.debugDescription)")
        }
    }
}

@Test func ordinaryProseIsUnchanged() {
    for prose in ["Budget < $5M and 20% growth", "a ~ b, ~~struck~~ and 3<4 is spaced: 3 < 4", "Q3 20%>15%"] {
        #expect(ZMeetText.sanitizeNoteMarkdown(prose) == prose.replacingOccurrences(of: "3<4", with: "3<4"))
    }
}

@Test func listNestingSurvivesIndentLimits() {
    // Models nest bullets with 2 or 4 spaces; both must still nest after sanitizing.
    for input in ["- a\n  - b", "- a\n    - b", "- a\n\t- b"] {
        let out = ZMeetText.sanitizeNoteMarkdown(input)
        let parsed = try! AttributedString(markdown: out, options: .init(interpretedSyntax: .full))
        let depth = parsed.runs.map { run in
            run.presentationIntent?.components.filter { if case .listItem = $0.kind { return true } else { return false } }.count ?? 0
        }.max()
        #expect(depth == 2, "nesting lost: \(input.debugDescription) → \(out.debugDescription)")
    }
}

@Test func sanitizingTwiceChangesNothing() {
    // notes.md is re-read and sanitized again on re-publish.
    for input in templaterTags + codeForms + ["- a\n    - b\n\n        c", "1.  two\n2)\tthree"] {
        let once = ZMeetText.sanitizeNoteMarkdown(input)
        #expect(ZMeetText.sanitizeNoteMarkdown(once) == once, "not stable: \(input.debugDescription)")
    }
}

@Test func noIndentedCodeInRandomContainerNesting() {
    // Seeded: random lines of indentation, quote and list markers around "= x".
    var seed: UInt64 = 0x5EED
    func next(_ n: Int) -> Int {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return Int((seed >> 33) % UInt64(n))
    }
    let pieces = [" ", "  ", "    ", "\t", ">", "> ", "-", "- ", "* ", "1.", "1. ", "10) ", "     ", ""]
    let separators = ["\n", "\n", "\r\n", "\r"]
    for _ in 0..<2_000 {
        let lines = (0..<(2 + next(5))).map { _ -> String in
            if next(3) == 0 { return "" }
            let indent = { (0..<(1 + next(4))).map { _ in pieces[next(pieces.count)] }.joined() }
            let content = indent() + (next(2) == 0 ? "= x" : "text")
            // Sometimes inside a link that gets defanged to its text.
            return next(3) == 0 ? indent() + "[" + content + "](smb://h)" : content
        }
        let input = lines.reduce("") { $0.isEmpty ? $1 : $0 + separators[next(separators.count)] + $1 }
        let out = ZMeetText.sanitizeNoteMarkdown(input)
        #expect(!hasCode(out), "code survives: \(input.debugDescription) → \(out.debugDescription)")
        #expect(ZMeetText.sanitizeNoteMarkdown(out) == out, "not stable: \(input.debugDescription)")
    }
}

@Test func outdentingNeverRevivesAReferenceLink() {
    // Four spaces make this code in the input; once outdented it would define a link.
    for input in ["\n\n    [s]: smb://host/share\n\n[go][s]", "\r\n\r\n\t[s]: ssh://h\r\n\r\n[go][s]"] {
        let out = ZMeetText.sanitizeNoteMarkdown(input)
        let parsed = try! AttributedString(markdown: out, options: .init(interpretedSyntax: .full))
        #expect(!parsed.runs.contains { $0.link != nil }, "live link: \(out.debugDescription)")
    }
}
