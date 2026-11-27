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
                         "\\\\`$= x`"]

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
        for note in [main, transcript, notes] {
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
