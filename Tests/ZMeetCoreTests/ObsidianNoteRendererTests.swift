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
    #expect(note.contains("[[Jonathan]]"))
    #expect(note.contains("[[Japan Trip]]"))
    #expect(note.contains("[[flights]]"))
    #expect(note.contains("[[2026-06-01 Weekly Sync — Transcript]]"))
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
