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
