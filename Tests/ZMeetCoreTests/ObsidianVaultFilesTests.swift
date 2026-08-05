import Foundation
import Testing
@testable import ZMeetCore

@Test func vaultFilenamesAreStableAndSafe() {
    let s = MeetingSession(id: "x", title: "Q3 Plan: Budget / Review", sourceApp: nil,
        startedAt: Date(timeIntervalSince1970: 1_780_000_000), endedAt: nil, status: .processed,
        audioPath: "", transcriptPath: nil, notePath: nil, recorderLogPath: nil, errorMessage: nil)
    let names = ObsidianVaultFiles.names(for: s)
    #expect(!names.main.contains("/") && !names.main.contains(":"))
    #expect(names.main.hasSuffix(".md"))
    #expect(names.transcript.contains("Transcript"))
    // Stable: same session → same names.
    #expect(ObsidianVaultFiles.names(for: s).main == names.main)
}

@Test func writeCreatesAndOverwritesBothFiles() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vault-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try ObsidianVaultFiles.write(main: "MAIN", transcript: "T", mainName: "Note.md", transcriptName: "Note — Transcript.md", into: dir)
    try ObsidianVaultFiles.write(main: "MAIN2", transcript: "T2", mainName: "Note.md", transcriptName: "Note — Transcript.md", into: dir)
    let main = try String(contentsOf: dir.appendingPathComponent("Note.md"), encoding: .utf8)
    #expect(main == "MAIN2")  // overwritten in place
}

@Test func sameDaySameTitleDistinctMeetingsDoNotCollide() {
    // Two different meetings, same calendar day, identical title (the recurring-
    // meeting / "Untitled Meeting" case) must produce different filenames so one
    // doesn't overwrite the other's vault notes.
    let base = Date(timeIntervalSince1970: 1_780_000_000)
    let a = MeetingSession(id: "a", title: "Weekly Sync", sourceApp: nil, startedAt: base,
        endedAt: nil, status: .processed, audioPath: "", transcriptPath: nil, notePath: nil,
        recorderLogPath: nil, errorMessage: nil)
    let b = MeetingSession(id: "b", title: "Weekly Sync", sourceApp: nil, startedAt: base.addingTimeInterval(3_600),
        endedAt: nil, status: .processed, audioPath: "", transcriptPath: nil, notePath: nil,
        recorderLogPath: nil, errorMessage: nil)
    #expect(ObsidianVaultFiles.names(for: a).main != ObsidianVaultFiles.names(for: b).main)
}

@Test func filenameHasNoDoubleSpacesAfterSanitizing() {
    let s = MeetingSession(id: "x", title: "Q3 Plan: Budget / Review", sourceApp: nil,
        startedAt: Date(timeIntervalSince1970: 1_780_000_000), endedAt: nil, status: .processed,
        audioPath: "", transcriptPath: nil, notePath: nil, recorderLogPath: nil, errorMessage: nil)
    #expect(!ObsidianVaultFiles.names(for: s).main.contains("  "))
}

@Test func legacyBaseNameIsDateOnlyAndDiffersFromCurrent() {
    // The pre-1.12.1 (date-only) name must differ from the current date+time name
    // so the upgrade cleanup actually removes the old orphaned pair.
    let s = MeetingSession(id: "x", title: "Weekly Sync", sourceApp: nil,
        startedAt: Date(timeIntervalSince1970: 1_780_000_000), endedAt: nil, status: .processed,
        audioPath: "", transcriptPath: nil, notePath: nil, recorderLogPath: nil, errorMessage: nil)
    let legacy = ObsidianVaultFiles.legacyBaseName(for: s)
    #expect(legacy == "\(ZMeetDates.displayDate(s.startedAt)) Weekly Sync")
    #expect(legacy != ObsidianVaultFiles.names(for: s).mainNoteName)
}

@Test func vaultNamesStayUnderComponentLimit() {
    // A very long (e.g. remote-controlled or LLM-generated) title must not push
    // the published filename past APFS's 255-byte component limit, even after
    // the "  — Transcript.md" suffix is appended.
    let longTitle = String(repeating: "a", count: 400)
    let s = MeetingSession(id: "x", title: longTitle, sourceApp: nil,
        startedAt: Date(timeIntervalSince1970: 1_780_000_000), endedAt: nil, status: .processed,
        audioPath: "", transcriptPath: nil, notePath: nil, recorderLogPath: nil, errorMessage: nil)
    #expect(ObsidianVaultFiles.names(for: s).transcript.utf8.count < 255)
}

@Test func removeDeletesBothPublishedFiles() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vault-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try ObsidianVaultFiles.write(main: "M", transcript: "T", mainName: "Old.md", transcriptName: "Old — Transcript.md", into: dir)
    ObsidianVaultFiles.remove(baseName: "Old", from: dir)
    #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("Old.md").path))
    #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("Old — Transcript.md").path))
}

@Test func removeIgnoresTraversalBaseName() throws {
    // A tampered/hand-edited `obsidianBaseName` of "../escape" read back from
    // ~/.zmeet/sessions/<id>.json must not be able to delete anything outside
    // the vault. Sentinel files sit exactly where that base name would resolve
    // to (one level above the vault) and must survive the call.
    let parent = FileManager.default.temporaryDirectory.appendingPathComponent("vault-parent-\(UUID().uuidString)")
    let vault = parent.appendingPathComponent("vault")
    try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: parent) }
    let sentinelMain = parent.appendingPathComponent("escape.md")
    let sentinelTranscript = parent.appendingPathComponent("escape — Transcript.md")
    try "keep me".write(to: sentinelMain, atomically: true, encoding: .utf8)
    try "keep me too".write(to: sentinelTranscript, atomically: true, encoding: .utf8)
    ObsidianVaultFiles.remove(baseName: "../escape", from: vault)
    #expect(FileManager.default.fileExists(atPath: sentinelMain.path))
    #expect(FileManager.default.fileExists(atPath: sentinelTranscript.path))
}

@Test func writeThrowsOnTraversalName() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vault-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    #expect(throws: (any Error).self) {
        try ObsidianVaultFiles.write(main: "M", transcript: "T", mainName: "../x.md", transcriptName: "Note — Transcript.md", into: dir)
    }
}
