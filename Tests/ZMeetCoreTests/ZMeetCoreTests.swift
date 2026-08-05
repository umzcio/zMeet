import Foundation
import Testing
@testable import ZMeetCore

@Test func slugifyProducesStableIDs() {
    #expect(ZMeetText.slugify("Weekly Product Sync") == "weekly-product-sync")
    #expect(ZMeetText.slugify("  Zach's 1:1 / Roadmap  ") == "zach-s-1-1-roadmap")
    #expect(ZMeetText.slugify("!!!") == "untitled-meeting")
}

@Test func noteSearchBodyStripsFrontmatterHeadingsAndTranscriptLink() {
    let note = """
    ---
    id: "abc"
    title: "Weekly Sync"
    ---

    # Weekly Sync

    ## Summary

    We shipped the detector and agreed on next steps.

    ## Transcript

    [Open transcript](transcript.md)
    """
    let body = ZMeetText.noteSearchBody(note)
    #expect(body.contains("We shipped the detector"))
    #expect(!body.contains("title:"))          // frontmatter gone
    #expect(!body.contains("# Weekly Sync"))    // heading gone
    #expect(!body.contains("Open transcript"))  // transcript link gone
}

@Test func relativePathHandlesSiblingTrees() {
    let from = URL(fileURLWithPath: "/tmp/repo/meetings/2026/05", isDirectory: true)
    let to = URL(fileURLWithPath: "/tmp/repo/transcripts/2026/05/demo.transcript.md")

    #expect(ZMeetPaths.relativePath(fromDirectory: from, to: to) == "../../../transcripts/2026/05/demo.transcript.md")
}

@Test func audioConfigDefaultValues() {
    let config = ZMeetConfig.default(outputPath: "/tmp/zmeet-output")
    #expect(config.audio.captureSystemAudio == true)
    #expect(config.audio.captureMicrophone == true)
    #expect(config.audio.sampleRate == 48000)
    #expect(config.audio.bitrate == 128000)
    #expect(config.autoProcessOnStop == true)
}

@Test func obsidianConfigDefaultsAndRoundTrips() throws {
    let c0 = ZMeetConfig.default(outputPath: "/tmp/zmeet-output")
    #expect(c0.publishToObsidian == false)
    #expect(c0.obsidianVaultPath == nil)
    var c = c0; c.publishToObsidian = true; c.obsidianVaultPath = "/tmp/Vault"
    let data = try JSONEncoder.zmeet.encode(c)
    let decoded = try JSONDecoder.zmeet.decode(ZMeetConfig.self, from: data)
    #expect(decoded.publishToObsidian == true)
    #expect(decoded.obsidianVaultPath == "/tmp/Vault")
}

@Test func configRoundTrips() throws {
    let config = ZMeetConfig.default(outputPath: "/tmp/zmeet-output")
    let data = try JSONEncoder.zmeet.encode(config)
    let decoded = try JSONDecoder.zmeet.decode(ZMeetConfig.self, from: data)

    #expect(decoded == config)
}

@Test func sessionRoundTripsWithoutFFmpegFields() throws {
    let session = MeetingSession(
        id: "2026-05-26-120000-demo",
        title: "Demo",
        sourceApp: nil,
        startedAt: Date(timeIntervalSince1970: 1_700_000_000),
        endedAt: nil,
        status: .recording,
        audioPath: "/tmp/demo.m4a",
        transcriptPath: nil,
        notePath: nil,
        recorderLogPath: "/tmp/demo.recorder.log",
        errorMessage: nil
    )
    let data = try JSONEncoder.zmeet.encode(session)
    let decoded = try JSONDecoder.zmeet.decode(MeetingSession.self, from: data)

    #expect(decoded == session)
}

@Test func startStampsRecordingModeOnSession() throws {
    let (config, root) = makeTempConfig()
    defer { try? FileManager.default.removeItem(at: root) }
    let manager = SessionManager(config: config, recorder: MockRecorder())
    let started = try manager.start(title: "Room", sourceApp: nil, mode: .inPerson)
    #expect(started.mode == .inPerson)
}

private func makeTempConfig() -> (ZMeetConfig, URL) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("zmeet-tests-\(UUID().uuidString)", isDirectory: true)
    let config = ZMeetConfig(
        outputPath: root.appendingPathComponent("zMeet").path,
        appDataPath: root.appendingPathComponent("data").path,
        autoProcessOnStop: false
    )
    return (config, root)
}

@Test func updateConfigPropagatesAudioWithoutRecreation() throws {
    var (config, root) = makeTempConfig()
    defer { try? FileManager.default.removeItem(at: root) }
    config.audio.captureSystemAudio = false
    let recorder = MockRecorder()
    let manager = SessionManager(config: config, recorder: recorder)

    // Flip an audio field via the live manager (no recreation).
    config.audio.captureSystemAudio = true
    manager.updateConfig(config)

    _ = try manager.start(title: "Demo", sourceApp: nil)

    #expect(recorder.startedAudio?.captureSystemAudio == true)
}

@Test func startStopProcessFlowWithMockRecorder() async throws {
    let (config, root) = makeTempConfig()
    defer { try? FileManager.default.removeItem(at: root) }

    let recorder = MockRecorder()
    let manager = SessionManager(config: config, recorder: recorder)

    let started = try manager.start(title: "Weekly Sync", sourceApp: nil)
    #expect(started.status == .recording)
    #expect(recorder.startedURL?.path == started.audioPath)
    #expect(FileManager.default.fileExists(atPath: started.audioPath))

    let stopped = try await manager.stop()
    #expect(stopped.status == .recorded)
    #expect(stopped.endedAt != nil)
    #expect(recorder.stopCount == 1)

    let processed = try manager.applyProcessedText(id: stopped.id, transcript: "Hello, this is the transcript.", summary: "## Summary\n\n- Discussed the plan.")
    #expect(processed.status == .processed)
    #expect(processed.notePath != nil)
    #expect(FileManager.default.fileExists(atPath: processed.notePath!))
}

/// A re-process (of an already-`.processed` meeting) that fails mid-write must
/// not downgrade the session — its prior notes are still intact on disk and the
/// Library must keep showing them.
@Test func reprocessFailurePreservesProcessedStatus() async throws {
    let (config, root) = makeTempConfig()
    defer { try? FileManager.default.removeItem(at: root) }

    let recorder = MockRecorder()
    let manager = SessionManager(config: config, recorder: recorder)

    let started = try manager.start(title: "Weekly Sync", sourceApp: nil)
    let stopped = try await manager.stop()
    let processed = try manager.applyProcessedText(id: stopped.id, transcript: "First pass.", summary: "## Summary\n\n- First.")
    #expect(processed.status == .processed)

    // Force the second write to fail mid-write (inside the catch-guarded block):
    // make the meeting folder read-only so `transcript.write(...)` throws.
    let folder = URL(fileURLWithPath: processed.audioPath).deletingLastPathComponent()
    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }

    #expect(throws: (any Error).self) {
        _ = try manager.applyProcessedText(id: started.id, transcript: "Second pass.", summary: "## Summary\n\n- Second.")
    }

    let reloaded = try manager.session(id: started.id)
    #expect(reloaded.status == .processed)
    #expect(reloaded.errorMessage != nil)
}

/// Protects existing behavior: a first-ever process failure (on a `.recorded`
/// session with no prior notes) still marks the session `.failed`.
@Test func firstProcessFailureStillMarksFailed() async throws {
    let (config, root) = makeTempConfig()
    defer { try? FileManager.default.removeItem(at: root) }

    let recorder = MockRecorder()
    let manager = SessionManager(config: config, recorder: recorder)

    let started = try manager.start(title: "Flaky Notes", sourceApp: nil)
    let stopped = try await manager.stop()
    #expect(stopped.status == .recorded)

    // Force the write to fail the same way, before any successful process.
    let folder = URL(fileURLWithPath: stopped.audioPath).deletingLastPathComponent()
    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }

    #expect(throws: (any Error).self) {
        _ = try manager.applyProcessedText(id: started.id, transcript: "Never lands.", summary: "## Summary\n\n- Never.")
    }

    let reloaded = try manager.session(id: started.id)
    #expect(reloaded.status == .failed)
    #expect(reloaded.errorMessage != nil)
}

@Test func stopFailureMarksSessionFailed() async throws {
    let (config, root) = makeTempConfig()
    defer { try? FileManager.default.removeItem(at: root) }

    let recorder = MockRecorder()
    let manager = SessionManager(config: config, recorder: recorder)
    let started = try manager.start(title: "Flaky", sourceApp: nil)

    recorder.stopError = ZMeetError.noActiveSession  // any error
    await #expect(throws: (any Error).self) {
        _ = try await manager.stop()
    }

    // The error is recorded and the session is finalized as .failed, not left .recording.
    let listed = try manager.listSessions().first { $0.id == started.id }
    #expect(listed?.status == .failed)
    #expect(listed?.errorMessage != nil)
    #expect(listed?.endedAt != nil)
}

@Test func startRejectsSecondConcurrentSession() throws {
    let (config, root) = makeTempConfig()
    defer { try? FileManager.default.removeItem(at: root) }

    let manager = SessionManager(config: config, recorder: MockRecorder())
    _ = try manager.start(title: "First", sourceApp: nil)

    #expect(throws: ZMeetError.self) {
        _ = try manager.start(title: "Second", sourceApp: nil)
    }
}

/// A `save()` failure AFTER `recorder.start()` succeeded must not leave an
/// unowned live capture behind: the recorder is stopped and the meeting
/// folder is removed.
@Test func startCompensatesWhenSaveFails() async throws {
    let (config, root) = makeTempConfig()
    defer { try? FileManager.default.removeItem(at: root) }

    // Pre-create the sessions directory (ensureDirectory on an already-existing
    // dir succeeds even when it's read-only), then lock it down so only the
    // final `save()` write inside `start()` fails — recorder.start() and the
    // meeting-folder creation happen elsewhere and must still succeed.
    let sessionsDir = URL(fileURLWithPath: ZMeetPaths.expandTilde(config.appDataPath), isDirectory: true)
        .appendingPathComponent("sessions", isDirectory: true)
    try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: sessionsDir.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: sessionsDir.path) }

    let mock = MockRecorder()
    let manager = SessionManager(config: config, recorder: mock)

    #expect(throws: (any Error).self) {
        _ = try manager.start(title: "Doomed", sourceApp: nil)
    }

    // The compensating stop is fire-and-forget in a Task; poll briefly for it.
    var waited = 0
    while mock.stopCount == 0 && waited < 100 {
        try? await Task.sleep(nanoseconds: 10_000_000)
        waited += 1
    }
    // Regression guard: if the compensation is ever dropped, this must fail
    // rather than silently pass after the poll window.
    #expect(mock.stopCount == 1)

    let outputDir = URL(fileURLWithPath: ZMeetPaths.expandTilde(config.outputPath), isDirectory: true)
    let leftover = (try? FileManager.default.contentsOfDirectory(at: outputDir, includingPropertiesForKeys: nil)) ?? []
    #expect(leftover.isEmpty)
}

@Test func markFailedTransitionsSession() async throws {
    let (config, root) = makeTempConfig()
    defer { try? FileManager.default.removeItem(at: root) }
    let manager = SessionManager(config: config, recorder: MockRecorder())

    // A recording session is marked failed with the message + timestamp set.
    let started = try manager.start(title: "Live", sourceApp: nil)
    let failed = try manager.markFailed(id: started.id, message: "boom")
    #expect(failed.status == .failed)
    #expect(failed.errorMessage == "boom")
    #expect(failed.endedAt != nil)

    // A processed session is left alone by markFailed — its notes stay intact.
    _ = try manager.start(title: "Done", sourceApp: nil)
    let stopped = try await manager.stop()
    let processed = try manager.applyProcessedText(id: stopped.id, transcript: "t", summary: "s")
    #expect(processed.status == .processed)
    let untouched = try manager.markFailed(id: processed.id, message: "should not apply")
    #expect(untouched.status == .processed)
}

@Test func mockCaptureFailureCallbackFires() {
    let mock = MockRecorder()
    let box = CapturedMessageBox()
    mock.onCaptureFailure = { message in box.value = message }
    mock.simulateCaptureFailure("boom")
    #expect(box.value == "boom")
}

/// Reference-type box so the `@Sendable` `onCaptureFailure` closure above can
/// record its argument without tripping Swift 6's captured-var diagnostics —
/// the mock invokes it synchronously, so there's no actual concurrent access.
private final class CapturedMessageBox: @unchecked Sendable {
    var value: String?
}

@Test func startFailureDoesNotPersistSession() throws {
    let (config, root) = makeTempConfig()
    defer { try? FileManager.default.removeItem(at: root) }

    let recorder = MockRecorder()
    recorder.startError = ZMeetError.noActiveSession  // any error
    let manager = SessionManager(config: config, recorder: recorder)

    #expect(throws: (any Error).self) {
        _ = try manager.start(title: "Fail", sourceApp: nil)
    }
    #expect(try manager.listSessions().isEmpty)
}

@Test func recoveryFinalizesSessionWithAudio() throws {
    let (config, root) = makeTempConfig()
    defer { try? FileManager.default.removeItem(at: root) }

    // A recorder that writes a non-empty file simulates "audio was captured".
    let manager = SessionManager(config: config, recorder: MockRecorder(createsAudioFile: true))
    let started = try manager.start(title: "Interrupted", sourceApp: nil)
    #expect(started.status == .recording)   // never stopped → still recording on disk

    let recovered = try manager.recoverInterruptedSessions()
    #expect(recovered.count == 1)
    #expect(recovered.first?.status == .recorded)
    #expect(recovered.first?.endedAt != nil)
}

@Test func recoveryFailsSessionWithoutAudio() throws {
    let (config, root) = makeTempConfig()
    defer { try? FileManager.default.removeItem(at: root) }

    // A recorder that writes no file simulates "crashed before any audio".
    let manager = SessionManager(config: config, recorder: MockRecorder(createsAudioFile: false))
    _ = try manager.start(title: "Empty", sourceApp: nil)

    let recovered = try manager.recoverInterruptedSessions()
    #expect(recovered.count == 1)
    #expect(recovered.first?.status == .failed)
    #expect(recovered.first?.errorMessage != nil)
}

@Test func recoveryFailsSessionWithZeroByteAudioFile() throws {
    let (config, root) = makeTempConfig()
    defer { try? FileManager.default.removeItem(at: root) }

    // Recorder created the .m4a container but crashed before writing frames.
    let manager = SessionManager(config: config, recorder: MockRecorder(createsAudioFile: true, audioFileSize: 0))
    _ = try manager.start(title: "ZeroByte", sourceApp: nil)

    let recovered = try manager.recoverInterruptedSessions()
    #expect(recovered.count == 1)
    #expect(recovered.first?.status == .failed)
    #expect(recovered.first?.errorMessage != nil)
}

@Test func recoveryIgnoresAlreadyFinalizedSessions() async throws {
    let (config, root) = makeTempConfig()
    defer { try? FileManager.default.removeItem(at: root) }

    let manager = SessionManager(config: config, recorder: MockRecorder())
    let started = try manager.start(title: "Clean", sourceApp: nil)
    _ = try await manager.stop()

    let recovered = try manager.recoverInterruptedSessions()
    #expect(recovered.isEmpty)
    // The stopped session is untouched.
    let listed = try manager.listSessions().first { $0.id == started.id }
    #expect(listed?.status == .recorded)
}

@Test func deleteRefusesActivelyRecordingSession() throws {
    let (config, root) = makeTempConfig()
    defer { try? FileManager.default.removeItem(at: root) }
    let manager = SessionManager(config: config, recorder: MockRecorder())
    let started = try manager.start(title: "Live", sourceApp: nil)  // status .recording

    #expect(throws: (any Error).self) { try manager.delete(id: started.id) }
    #expect(try manager.session(id: started.id).status == .recording)
    #expect(FileManager.default.fileExists(atPath: started.audioPath))
}

@Test func setTitleUpdatesDisplayTitleInPlace() throws {
    let (config, root) = makeTempConfig()
    defer { try? FileManager.default.removeItem(at: root) }

    let manager = SessionManager(config: config, recorder: MockRecorder())
    let started = try manager.start(title: "Old Name", sourceApp: nil)
    let audioPath = started.audioPath

    let renamed = try manager.setTitle(id: started.id, to: "  New Name  ")
    #expect(renamed.title == "New Name")
    // The on-disk folder (and audio path) is unchanged — only the title updates.
    #expect(renamed.audioPath == audioPath)
    #expect(try manager.session(id: started.id).title == "New Name")

    // Empty/whitespace titles fall back to the default.
    let blank = try manager.setTitle(id: started.id, to: "   ")
    #expect(blank.title == "Untitled Meeting")
}

@Test func deleteRemovesFolderAndSession() async throws {
    let (config, root) = makeTempConfig()
    defer { try? FileManager.default.removeItem(at: root) }

    let manager = SessionManager(config: config, recorder: MockRecorder())
    let started = try manager.start(title: "Disposable", sourceApp: nil)
    _ = try await manager.stop()
    let folder = URL(fileURLWithPath: started.audioPath).deletingLastPathComponent()
    #expect(FileManager.default.fileExists(atPath: folder.path))

    try manager.delete(id: started.id)

    #expect(!FileManager.default.fileExists(atPath: folder.path))
    #expect(try manager.listSessions().contains { $0.id == started.id } == false)
    #expect(throws: (any Error).self) { _ = try manager.session(id: started.id) }
}

@Test func audioRetentionDaysDefaultsToZeroAndRoundTrips() throws {
    #expect(ZMeetConfig.default(outputPath: "/tmp/x").audioRetentionDays == 0)

    var config = ZMeetConfig.default(outputPath: "/tmp/x")
    config.audioRetentionDays = 30
    let data = try JSONEncoder.zmeet.encode(config)
    let decoded = try JSONDecoder.zmeet.decode(ZMeetConfig.self, from: data)
    #expect(decoded.audioRetentionDays == 30)

    // Older config.json without the key still decodes, defaulting to 0 (Never).
    let legacy = #"{"outputPath":"/tmp/x","appDataPath":"/tmp/x/data"}"#.data(using: .utf8)!
    let fromLegacy = try JSONDecoder.zmeet.decode(ZMeetConfig.self, from: legacy)
    #expect(fromLegacy.audioRetentionDays == 0)
}

@Test func useCloudSummariesDefaultsToFalseAndRoundTrips() throws {
    let config = ZMeetConfig.default(outputPath: "/tmp/zmeet-output")
    #expect(config.useCloudSummaries == false)

    var enabled = config
    enabled.useCloudSummaries = true
    let data = try JSONEncoder.zmeet.encode(enabled)
    let decoded = try JSONDecoder.zmeet.decode(ZMeetConfig.self, from: data)
    #expect(decoded.useCloudSummaries == true)
}

@Test func noiseSuppressionDefaultsToFalseAndRoundTrips() throws {
    let config = ZMeetConfig.default(outputPath: "/tmp/zmeet-output")
    #expect(config.noiseSuppression == false)

    var enabled = config
    enabled.noiseSuppression = true
    let data = try JSONEncoder.zmeet.encode(enabled)
    let decoded = try JSONDecoder.zmeet.decode(ZMeetConfig.self, from: data)
    #expect(decoded.noiseSuppression == true)
}

@Test func labelSpeakersAndSeparateTracksDefaultFalseAndRoundTrip() throws {
    let config = ZMeetConfig.default(outputPath: "/tmp/zmeet-output")
    #expect(config.labelSpeakers == false)
    #expect(config.audio.separateTracks == false)

    var c = config
    c.labelSpeakers = true
    c.audio.separateTracks = true
    let data = try JSONEncoder.zmeet.encode(c)
    let decoded = try JSONDecoder.zmeet.decode(ZMeetConfig.self, from: data)
    #expect(decoded.labelSpeakers == true)
    #expect(decoded.audio.separateTracks == true)
}

@Test func processingIndexesMeetingForSearch() async throws {
    let (config, root) = makeTempConfig()
    defer { try? FileManager.default.removeItem(at: root) }
    let manager = SessionManager(config: config, recorder: MockRecorder())

    let started = try manager.start(title: "Roadmap Review", sourceApp: nil)
    _ = try await manager.stop()
    _ = try manager.applyProcessedText(
        id: started.id,
        transcript: "we agreed to ship the meeting detector next sprint",
        summary: "Shipping detection."
    )

    let store = try #require(manager.searchStore)
    // Findable by a transcript term...
    #expect(store.search("detector", limit: 10).map(\.sessionID) == [started.id])
    // ...and by title.
    #expect(store.search("roadmap", limit: 10).map(\.sessionID) == [started.id])

    // Rename updates the indexed title.
    _ = try manager.setTitle(id: started.id, to: "Quarterly Planning")
    #expect(store.search("quarterly", limit: 10).map(\.sessionID) == [started.id])
    #expect(store.search("roadmap", limit: 10).isEmpty)

    // Renaming must NOT drop the meeting's body from search.
    #expect(store.search("detector", limit: 10).map(\.sessionID) == [started.id])

    // Delete removes it.
    try manager.delete(id: started.id)
    #expect(store.search("detector", limit: 10).isEmpty)
}

@Test func applyProcessedTextAddsEngineAttributionToNoteOnly() async throws {
    let (config, root) = makeTempConfig()
    defer { try? FileManager.default.removeItem(at: root) }
    let manager = SessionManager(config: config, recorder: MockRecorder())
    let started = try manager.start(title: "Sync", sourceApp: nil)
    _ = try await manager.stop()

    let processed = try manager.applyProcessedText(
        id: started.id, transcript: "hello world", summary: "## Summary\n- ok", engine: .cloud)

    let note = try String(contentsOfFile: processed.notePath!, encoding: .utf8)
    #expect(note.contains("Summary by Claude Sonnet (cloud)"))
}

/// Helper: make a processed meeting with a real audio file, dated `daysAgo`.
private func makeProcessedMeeting(_ manager: SessionManager, title: String, daysAgo: Int) async throws -> MeetingSession {
    let started = try manager.start(title: title, sourceApp: nil)
    _ = try await manager.stop()
    let processed = try manager.applyProcessedText(id: started.id, transcript: "t", summary: "s")
    // Backdate the session so retention math sees it as old.
    var dated = processed
    dated.startedAt = Date().addingTimeInterval(-Double(daysAgo) * 86_400)
    dated.endedAt = dated.startedAt.addingTimeInterval(60)
    try manager.overwriteSessionForTesting(dated)
    return dated
}

@Test func purgeExpiredAudioRemovesOldProcessedAudioOnly() async throws {
    let (config0, root) = makeTempConfig()
    defer { try? FileManager.default.removeItem(at: root) }
    var config = config0
    config.audioRetentionDays = 30
    let manager = SessionManager(config: config, recorder: MockRecorder())

    let old = try await makeProcessedMeeting(manager, title: "Old", daysAgo: 60)
    let recent = try await makeProcessedMeeting(manager, title: "Recent", daysAgo: 5)

    let purged = manager.purgeExpiredAudio()
    #expect(purged == 1)
    #expect(!FileManager.default.fileExists(atPath: old.audioPath))
    #expect(FileManager.default.fileExists(atPath: old.transcriptPath!))
    #expect(FileManager.default.fileExists(atPath: old.notePath!))
    #expect(try manager.session(id: old.id).status == .processed)
    #expect(FileManager.default.fileExists(atPath: recent.audioPath))
}

@Test func purgeNeverWhenRetentionIsZero() async throws {
    let (config, root) = makeTempConfig()  // default audioRetentionDays == 0
    defer { try? FileManager.default.removeItem(at: root) }
    let manager = SessionManager(config: config, recorder: MockRecorder())
    let old = try await makeProcessedMeeting(manager, title: "Old", daysAgo: 365)

    #expect(manager.purgeExpiredAudio() == 0)
    #expect(FileManager.default.fileExists(atPath: old.audioPath))
}

@Test func purgeNeverTouchesUnprocessedAudio() async throws {
    let (config0, root) = makeTempConfig()
    defer { try? FileManager.default.removeItem(at: root) }
    var config = config0
    config.audioRetentionDays = 1
    let manager = SessionManager(config: config, recorder: MockRecorder())

    _ = try manager.start(title: "Unprocessed", sourceApp: nil)
    var stopped = try await manager.stop()
    stopped.startedAt = Date().addingTimeInterval(-100 * 86_400)
    stopped.endedAt = stopped.startedAt.addingTimeInterval(60)
    try manager.overwriteSessionForTesting(stopped)

    #expect(manager.purgeExpiredAudio() == 0)
    #expect(FileManager.default.fileExists(atPath: stopped.audioPath))
}

@Test func deleteAudioRemovesOnlyProcessedAudio() async throws {
    let (config, root) = makeTempConfig()
    defer { try? FileManager.default.removeItem(at: root) }
    let manager = SessionManager(config: config, recorder: MockRecorder())
    let m = try await makeProcessedMeeting(manager, title: "M", daysAgo: 1)

    try manager.deleteAudio(id: m.id)
    #expect(!FileManager.default.fileExists(atPath: m.audioPath))
    #expect(FileManager.default.fileExists(atPath: m.notePath!))
}

@Test func deleteAudioAlsoRemovesDiarizationTracks() async throws {
    let (config, root) = makeTempConfig()
    defer { try? FileManager.default.removeItem(at: root) }
    let manager = SessionManager(config: config, recorder: MockRecorder())
    let m = try await makeProcessedMeeting(manager, title: "Tracked", daysAgo: 1)

    // Simulate leftover dual-track files in the meeting folder.
    let folder = URL(fileURLWithPath: m.audioPath).deletingLastPathComponent()
    let mic = folder.appendingPathComponent("mic.m4a")
    let system = folder.appendingPathComponent("system.m4a")
    FileManager.default.createFile(atPath: mic.path, contents: Data("m".utf8))
    FileManager.default.createFile(atPath: system.path, contents: Data("s".utf8))

    try manager.deleteAudio(id: m.id)
    #expect(!FileManager.default.fileExists(atPath: m.audioPath))
    #expect(!FileManager.default.fileExists(atPath: mic.path))
    #expect(!FileManager.default.fileExists(atPath: system.path))
}

@Test func reclaimableAudioBytesSumsProcessedAudio() async throws {
    let (config, root) = makeTempConfig()
    defer { try? FileManager.default.removeItem(at: root) }
    let manager = SessionManager(config: config, recorder: MockRecorder(audioFileSize: 100))
    _ = try await makeProcessedMeeting(manager, title: "A", daysAgo: 1)
    _ = try await makeProcessedMeeting(manager, title: "B", daysAgo: 1)

    #expect(manager.reclaimableAudioBytes() == 200)
}

/// A temp config rooted under the real home directory (not `/tmp`, which on
/// macOS resolves outside `homeDirectoryForCurrentUser`), needed by tests that
/// exercise the home-guarded `purgeSessionsWithMissingFolders`.
private func makeTempConfigUnderHome() -> (ZMeetConfig, URL) {
    let root = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".zmeet-test-\(UUID().uuidString)", isDirectory: true)
    let config = ZMeetConfig(
        outputPath: root.appendingPathComponent("zMeet").path,
        appDataPath: root.appendingPathComponent("data").path,
        autoProcessOnStop: false
    )
    return (config, root)
}

@Test func deleteRemovesRecorderLog() async throws {
    let (config, root) = makeTempConfig()
    defer { try? FileManager.default.removeItem(at: root) }
    let manager = SessionManager(config: config, recorder: MockRecorder())

    let started = try manager.start(title: "Logged", sourceApp: nil)
    let stopped = try await manager.stop()
    _ = try manager.applyProcessedText(id: stopped.id, transcript: "t", summary: "s")

    // MockRecorder doesn't write a log file — create the one the session record
    // points at so we can verify delete() removes it.
    let session = try manager.session(id: started.id)
    let logPath = try #require(session.recorderLogPath)
    try FileManager.default.createDirectory(
        at: URL(fileURLWithPath: logPath).deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    FileManager.default.createFile(atPath: logPath, contents: Data("log".utf8))
    #expect(FileManager.default.fileExists(atPath: logPath))

    try manager.delete(id: started.id)
    #expect(!FileManager.default.fileExists(atPath: logPath))
}

@Test func finderDeletedFolderPurgesSessionAndIndex() async throws {
    let (config, root) = makeTempConfigUnderHome()
    defer { try? FileManager.default.removeItem(at: root) }
    let manager = SessionManager(config: config, recorder: MockRecorder())

    let started = try manager.start(title: "Vanishing", sourceApp: nil)
    let stopped = try await manager.stop()
    let processed = try manager.applyProcessedText(id: stopped.id, transcript: "t", summary: "s")

    let logPath = try #require(processed.recorderLogPath)
    try FileManager.default.createDirectory(
        at: URL(fileURLWithPath: logPath).deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    FileManager.default.createFile(atPath: logPath, contents: Data("log".utf8))

    let store = try #require(manager.searchStore)
    #expect(try store.indexedIDs().contains(processed.id))

    // Simulate the user deleting the meeting folder in Finder.
    let folder = URL(fileURLWithPath: processed.audioPath).deletingLastPathComponent()
    try FileManager.default.removeItem(at: folder)

    let purged = manager.purgeSessionsWithMissingFolders()
    #expect(purged == [processed.id])

    #expect(throws: (any Error).self) { _ = try manager.session(id: processed.id) }
    #expect(!(try store.indexedIDs().contains(processed.id)))
    #expect(!FileManager.default.fileExists(atPath: logPath))
}

@Test func deleteWorksAfterOutputRootChanges() async throws {
    let (config, root) = makeTempConfig()
    defer { try? FileManager.default.removeItem(at: root) }
    let manager = SessionManager(config: config, recorder: MockRecorder())

    let started = try manager.start(title: "Moving", sourceApp: nil)
    let stopped = try await manager.stop()
    let processed = try manager.applyProcessedText(id: stopped.id, transcript: "t", summary: "s")
    let folder = URL(fileURLWithPath: processed.audioPath).deletingLastPathComponent()
    #expect(FileManager.default.fileExists(atPath: folder.path))

    // Rebuild a SessionManager pointing at a DIFFERENT output root, as happens
    // when the user changes the notes folder in Settings.
    var movedConfig = config
    movedConfig.outputPath = root.appendingPathComponent("zMeetElsewhere").path
    let movedManager = SessionManager(config: movedConfig, recorder: MockRecorder())

    try movedManager.delete(id: processed.id)

    // The original folder (under the OLD root, remembered via outputRoot) is gone.
    #expect(!FileManager.default.fileExists(atPath: folder.path))
    #expect(throws: (any Error).self) { _ = try movedManager.session(id: processed.id) }
}

/// `reclaimableAudioBytes` must never report bytes that `removeAudioFile` would
/// then refuse to remove. Simulates a legacy session (predates `outputRoot`,
/// so it decodes with `outputRoot == nil`) whose config output root then moves:
/// the shared `audioURLIfRemovable` predicate falls back to the CURRENT output
/// root for such a session, so its audio (still sitting under the OLD root) is
/// correctly excluded from both reclaimable-bytes accounting and deletion.
@Test func reclaimableMatchesRemovable() async throws {
    let (config, root) = makeTempConfig()
    defer { try? FileManager.default.removeItem(at: root) }
    let manager = SessionManager(config: config, recorder: MockRecorder(audioFileSize: 100))

    let processed = try await makeProcessedMeeting(manager, title: "Legacy", daysAgo: 1)
    #expect(manager.reclaimableAudioBytes() == 100)

    // Strip `outputRoot` from the on-disk session record to simulate a session
    // created before this field existed.
    let sessionURL = URL(fileURLWithPath: ZMeetPaths.expandTilde(config.appDataPath), isDirectory: true)
        .appendingPathComponent("sessions", isDirectory: true)
        .appendingPathComponent("\(processed.id).json")
    let data = try Data(contentsOf: sessionURL)
    var dict = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    dict.removeValue(forKey: "outputRoot")
    let strippedData = try JSONSerialization.data(withJSONObject: dict)
    try strippedData.write(to: sessionURL)

    // Now move the output root and rebuild the manager, as Settings does.
    var movedConfig = config
    movedConfig.outputPath = root.appendingPathComponent("zMeetElsewhere").path
    let movedManager = SessionManager(config: movedConfig, recorder: MockRecorder())

    // The legacy session's audio still lives under the OLD root, which is no
    // longer reachable via the (now current) output root fallback — reclaimable
    // bytes must reflect that it will NOT be removed.
    #expect(movedManager.reclaimableAudioBytes() == 0)
    try movedManager.deleteAudio(id: processed.id)
    #expect(FileManager.default.fileExists(atPath: processed.audioPath))
}

@Test func micGainDefaultsToUnityAndRoundTrips() throws {
    let config = ZMeetConfig.default(outputPath: "/tmp/zmeet-output")
    #expect(config.audio.micGain == 1.0)

    var enabled = config
    enabled.audio.micGain = 2.0
    let data = try JSONEncoder.zmeet.encode(enabled)
    let decoded = try JSONDecoder.zmeet.decode(ZMeetConfig.self, from: data)
    #expect(decoded.audio.micGain == 2.0)
}
