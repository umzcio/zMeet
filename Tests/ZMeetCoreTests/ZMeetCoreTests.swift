import Foundation
import Testing
@testable import ZMeetCore

@Test func slugifyProducesStableIDs() {
    #expect(ZMeetText.slugify("Weekly Product Sync") == "weekly-product-sync")
    #expect(ZMeetText.slugify("  Zach's 1:1 / Roadmap  ") == "zach-s-1-1-roadmap")
    #expect(ZMeetText.slugify("!!!") == "untitled-meeting")
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

private func makeTempConfig() -> (ZMeetConfig, URL) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("zmeet-tests-\(UUID().uuidString)", isDirectory: true)
    let config = ZMeetConfig(
        outputPath: root.appendingPathComponent("zMeet").path,
        appDataPath: root.appendingPathComponent("data").path,
        transcriptionCommand: nil,
        summaryCommand: nil,
        gitAutoCommit: false,
        autoProcessOnStop: false
    )
    return (config, root)
}

@Test func startStopProcessFlowWithMockRecorder() throws {
    let (config, root) = makeTempConfig()
    defer { try? FileManager.default.removeItem(at: root) }

    let recorder = MockRecorder()
    let manager = SessionManager(config: config, recorder: recorder)

    let started = try manager.start(title: "Weekly Sync", sourceApp: nil)
    #expect(started.status == .recording)
    #expect(recorder.startedURL?.path == started.audioPath)
    #expect(FileManager.default.fileExists(atPath: started.audioPath))

    let stopped = try manager.stop()
    #expect(stopped.status == .recorded)
    #expect(stopped.endedAt != nil)
    #expect(recorder.stopCount == 1)

    let processed = try manager.process(id: stopped.id)
    #expect(processed.status == .processed)
    #expect(processed.notePath != nil)
    #expect(FileManager.default.fileExists(atPath: processed.notePath!))
}

@Test func stopFailureMarksSessionFailed() throws {
    let (config, root) = makeTempConfig()
    defer { try? FileManager.default.removeItem(at: root) }

    let recorder = MockRecorder()
    let manager = SessionManager(config: config, recorder: recorder)
    let started = try manager.start(title: "Flaky", sourceApp: nil)

    recorder.stopError = ZMeetError.noActiveSession  // any error
    #expect(throws: (any Error).self) {
        _ = try manager.stop()
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

@Test func transcriptPlaceholderDoesNotReferenceRetiredCLI() {
    let session = MeetingSession(
        id: "2026-05-26-120000-demo",
        title: "Demo",
        sourceApp: nil,
        startedAt: Date(),
        endedAt: nil,
        status: .recorded,
        audioPath: "/tmp/demo.m4a",
        transcriptPath: nil,
        notePath: nil,
        recorderLogPath: nil,
        errorMessage: nil
    )
    let text = MarkdownRenderer().renderTranscriptPlaceholder(session: session)
    #expect(!text.contains("zmeet process"))
    #expect(!text.contains("zmeet config"))
    #expect(text.contains("~/.zmeet/config.json"))
}

@Test func recoveryIgnoresAlreadyFinalizedSessions() throws {
    let (config, root) = makeTempConfig()
    defer { try? FileManager.default.removeItem(at: root) }

    let manager = SessionManager(config: config, recorder: MockRecorder())
    let started = try manager.start(title: "Clean", sourceApp: nil)
    _ = try manager.stop()

    let recovered = try manager.recoverInterruptedSessions()
    #expect(recovered.isEmpty)
    // The stopped session is untouched.
    let listed = try manager.listSessions().first { $0.id == started.id }
    #expect(listed?.status == .recorded)
}
