import Foundation
import Testing
@testable import ZMeetCore

private func sampleSession() -> MeetingSession {
    MeetingSession(id: "2026-06-01-090000-sync", title: "Weekly Sync", sourceApp: "Microsoft Teams",
        mode: .remote,
        startedAt: Date(timeIntervalSince1970: 1_780_000_000), endedAt: Date(timeIntervalSince1970: 1_780_003_480),
        status: .processed, audioPath: "/x/recording.m4a", transcriptPath: "/x/transcript.md",
        notePath: "/x/notes.md", recorderLogPath: nil, errorMessage: nil)
}

@Test func mainNoteHasFrontmatterLinksAndTranscriptLink() {
    let e = MeetingEntities(people: ["Jonathan"], projects: ["Japan Trip"], topics: ["flights"])
    let note = ObsidianNoteRenderer.mainNote(session: sampleSession(), summary: "## Summary\n- ok",
        entities: e, transcriptNoteName: "2026-06-01 Weekly Sync — Transcript")
    #expect(note.hasPrefix("---\n"))
    #expect(note.contains("source: \"Microsoft Teams\""))
    #expect(note.contains("# Weekly Sync"))
    // People referenced are recorded under "people" — NOT "attendees" (a transcript
    // can't know who was actually present).
    #expect(note.contains("people: [\"Jonathan\"]"))
    #expect(!note.contains("attendees:"))
    #expect(note.contains("[[Jonathan]]"))
    #expect(note.contains("[[Japan Trip]]"))
    #expect(note.contains("[[flights]]"))
    #expect(note.contains("[[2026-06-01 Weekly Sync — Transcript]]"))
}

@Test func inPersonMeetingSourceIsLabeledNotUnknown() {
    let session = MeetingSession(id: "x", title: "Room chat", sourceApp: nil, mode: .inPerson,
        startedAt: Date(timeIntervalSince1970: 1_780_000_000), endedAt: nil, status: .processed,
        audioPath: "", transcriptPath: nil, notePath: nil, recorderLogPath: nil, errorMessage: nil)
    let note = ObsidianNoteRenderer.mainNote(session: session, summary: "body",
        entities: MeetingEntities(), transcriptNoteName: "T")
    #expect(note.contains("source: \"In person\""))
    #expect(!note.contains("Unknown"))
}

@Test func mainNoteOmitsEmptyLinkSections() {
    let note = ObsidianNoteRenderer.mainNote(session: sampleSession(), summary: "body",
        entities: MeetingEntities(), transcriptNoteName: "T")
    #expect(!note.contains("## People"))
    #expect(!note.contains("## Projects"))
    #expect(!note.contains("## Topics"))
}

@Test func transcriptNoteBacklinksMain() {
    let t = ObsidianNoteRenderer.transcriptNote(session: sampleSession(), transcript: "Hello.", mainNoteName: "2026-06-01 Weekly Sync")
    #expect(t.contains("[[2026-06-01 Weekly Sync]]"))
    #expect(t.contains("Hello."))
}

@Test func frontmatterEscapesTrailingBackslashInsteadOfSwallowingQuote() {
    // A value ending in a backslash must not be able to escape its own closing
    // quote — the backslash itself needs escaping first, so the value renders
    // as `"...\\"` (a literal trailing backslash, properly closed).
    let e = MeetingEntities(people: ["C:\\Users\\Jonathan\\"], projects: [], topics: [])
    let note = ObsidianNoteRenderer.mainNote(session: sampleSession(), summary: "body",
        entities: e, transcriptNoteName: "T")
    #expect(note.contains("people: [\"C:\\\\Users\\\\Jonathan\\\\\"]"))
}
