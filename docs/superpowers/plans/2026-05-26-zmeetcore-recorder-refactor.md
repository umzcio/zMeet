# ZMeetCore Recorder Refactor — Implementation Plan (Plan A of 2)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Refactor `ZMeetCore` so recording is driven by an injected `MeetingRecorder` protocol (not a spawned FFmpeg process), retire the `zmeet` CLI, and update the data model — leaving the engine fully testable via `swift test` and with locked interfaces for the menu-bar app to build against.

**Architecture:** `SessionManager` stops spawning processes and instead orchestrates an injected `MeetingRecorder` (concrete implementation arrives in Plan B, inside the app). The on-disk models lose all FFmpeg/PID fields and gain audio settings. Crash recovery moves from "is the PID alive?" to "is there a non-empty audio file for a session still marked `recording`?".

**Tech Stack:** Swift 6, SwiftPM, Swift Testing (`import Testing`, `@Test`, `#expect`). Tests run with `swift test --disable-sandbox` (filesystem + git access).

**Scope note:** This is Plan A of two. Plan B (the `ZMeet.app` Xcode project: `SCKAudioRecorder`, `RecordingController`, `MenuBarExtra` UI, permissions, signing) is written *after* this plan executes, when the Core interfaces below are concrete.

---

## File Structure

| File | Change | Responsibility after change |
|------|--------|------------------------------|
| `Package.swift` | Modify | Drop `zmeet` executable product + target; bump platform to `.macOS(.v15)`; keep `ZMeetCore` library + test target |
| `Sources/zmeet/` | Delete | (removed — CLI retired) |
| `Sources/ZMeetCore/MeetingRecorder.swift` | Create | `MeetingRecorder` protocol — the seam the app implements |
| `Sources/ZMeetCore/Models.swift` | Modify | `MeetingSession` (no PID/ffmpeg fields, add `recorderLogPath`), `ZMeetConfig` (+`AudioConfig`, `+autoProcessOnStop`, no ffmpeg fields), `AudioConfig` (new), `ZMeetError` (drop `recorderFailedToStart`) |
| `Sources/ZMeetCore/SessionManager.swift` | Modify | Orchestrate injected recorder in `start`/`stop`; add `recoverInterruptedSessions()`; remove Darwin/PID code + `listAudioDevices` |
| `Sources/ZMeetCore/ProcessRunner.swift` | Modify | Remove now-unused `startDetached` |
| `Sources/ZMeetCore/MarkdownRenderer.swift` | Modify | Transcript placeholder text no longer references the retired CLI |
| `Tests/ZMeetCoreTests/ZMeetCoreTests.swift` | Modify | Update config round-trip; add new-schema, recorder-orchestration, and recovery tests |
| `Tests/ZMeetCoreTests/MockRecorder.swift` | Create | Test double implementing `MeetingRecorder` |

---

### Task 1: Retire the `zmeet` CLI

**Files:**
- Modify: `Package.swift`
- Delete: `Sources/zmeet/main.swift` (and the `Sources/zmeet` directory)

- [ ] **Step 1: Delete the CLI source directory**

Run:
```bash
rm -rf Sources/zmeet
```

- [ ] **Step 2: Rewrite `Package.swift` without the executable**

Replace the entire contents of `Package.swift` with:

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "zMeet",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "ZMeetCore", targets: ["ZMeetCore"])
    ],
    targets: [
        .target(name: "ZMeetCore"),
        .testTarget(
            name: "ZMeetCoreTests",
            dependencies: ["ZMeetCore"]
        )
    ]
)
```

- [ ] **Step 3: Verify the package still builds and tests pass**

Run: `swift build --disable-sandbox && swift test --disable-sandbox`
Expected: build succeeds; the 3 existing tests pass. (ZMeetCore is unchanged and still references its FFmpeg fields — that's fine; we change it in later tasks.)

- [ ] **Step 4: Commit**

```bash
git add Package.swift Sources/zmeet
git commit -m "Retire zmeet CLI; ZMeetCore becomes the sole package product"
```

---

### Task 2: Add the `MeetingRecorder` protocol

**Files:**
- Create: `Sources/ZMeetCore/MeetingRecorder.swift`

This is an independent new file (no other code depends on it yet), so no test is needed until Task 4 wires it in.

- [ ] **Step 1: Create the protocol file**

Create `Sources/ZMeetCore/MeetingRecorder.swift`:

```swift
import Foundation

/// Drives audio capture for a recording session. ZMeetCore owns this seam;
/// the concrete implementation (ScreenCaptureKit + AVAudioEngine) lives in the
/// app target, because capture is inseparable from app TCC permissions and
/// cannot be exercised in headless unit tests.
///
/// Implementations are expected to begin writing an AAC `.m4a` file at the URL
/// passed to `start(to:audio:)` and to finalize/close it on `stop()`.
/// `start` may initiate capture asynchronously and return promptly; failures
/// that occur after `start` returns are surfaced by the implementation (e.g.
/// written to the session's recorder log and reflected via recovery on next
/// launch), not thrown here.
public protocol MeetingRecorder {
    /// Begin capturing to `url`. Throws only for synchronous setup failures
    /// (e.g. permission denied up front, no shareable content).
    func start(to url: URL, audio: AudioConfig) throws

    /// Stop capture and finalize the audio file.
    func stop() throws
}
```

> Note: `AudioConfig` is introduced in Task 3. If you execute strictly in order, this file will not compile until Task 3 lands. That is expected — do not run a build between this step and Task 3; the commit below is deferred to Task 3's final commit. (If your workflow requires a green build per task, execute Task 3 immediately after this step and commit them together.)

- [ ] **Step 2: (Deferred) commit with Task 3**

No standalone commit — `AudioConfig` must exist first. Proceed to Task 3.

---

### Task 3: New data model — `AudioConfig`, reshaped `ZMeetConfig` and `MeetingSession`, trimmed `ZMeetError`

**Files:**
- Modify: `Sources/ZMeetCore/Models.swift`
- Test: `Tests/ZMeetCoreTests/ZMeetCoreTests.swift`

- [ ] **Step 1: Write the failing tests for the new schema**

In `Tests/ZMeetCoreTests/ZMeetCoreTests.swift`, replace the existing `configRoundTrips` test and add new ones. The full updated test (replace the `configRoundTrips` function) is:

```swift
@Test func configHasAudioDefaults() {
    let config = ZMeetConfig.default(notesRepoPath: "/tmp/zmeet-notes")
    #expect(config.audio.captureSystemAudio == true)
    #expect(config.audio.captureMicrophone == true)
    #expect(config.audio.sampleRate == 48000)
    #expect(config.audio.bitrate == 128000)
    #expect(config.autoProcessOnStop == true)
}

@Test func configRoundTrips() throws {
    let config = ZMeetConfig.default(notesRepoPath: "/tmp/zmeet-notes")
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
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --disable-sandbox --filter configHasAudioDefaults`
Expected: FAIL to compile — `ZMeetConfig` has no `audio`/`autoProcessOnStop`, `MeetingSession` init no longer matches.

- [ ] **Step 3: Add `AudioConfig` and reshape `ZMeetConfig` in `Models.swift`**

In `Sources/ZMeetCore/Models.swift`, add this struct (place it just above `struct ZMeetConfig`):

```swift
public struct AudioConfig: Codable, Equatable {
    public var captureSystemAudio: Bool
    public var captureMicrophone: Bool
    public var sampleRate: Int
    public var bitrate: Int

    public init(
        captureSystemAudio: Bool = true,
        captureMicrophone: Bool = true,
        sampleRate: Int = 48_000,
        bitrate: Int = 128_000
    ) {
        self.captureSystemAudio = captureSystemAudio
        self.captureMicrophone = captureMicrophone
        self.sampleRate = sampleRate
        self.bitrate = bitrate
    }
}
```

Then replace the entire `struct ZMeetConfig { ... }` with:

```swift
public struct ZMeetConfig: Codable, Equatable {
    public var notesRepoPath: String
    public var appDataPath: String
    public var audio: AudioConfig
    public var transcriptionCommand: String?
    public var summaryCommand: String?
    public var gitAutoCommit: Bool
    public var autoProcessOnStop: Bool

    public init(
        notesRepoPath: String,
        appDataPath: String,
        audio: AudioConfig = AudioConfig(),
        transcriptionCommand: String?,
        summaryCommand: String?,
        gitAutoCommit: Bool,
        autoProcessOnStop: Bool = true
    ) {
        self.notesRepoPath = notesRepoPath
        self.appDataPath = appDataPath
        self.audio = audio
        self.transcriptionCommand = transcriptionCommand
        self.summaryCommand = summaryCommand
        self.gitAutoCommit = gitAutoCommit
        self.autoProcessOnStop = autoProcessOnStop
    }

    public static func `default`(
        notesRepoPath: String,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> ZMeetConfig {
        ZMeetConfig(
            notesRepoPath: notesRepoPath,
            appDataPath: home.appendingPathComponent(".zmeet").path,
            audio: AudioConfig(),
            transcriptionCommand: nil,
            summaryCommand: nil,
            gitAutoCommit: true,
            autoProcessOnStop: true
        )
    }
}
```

> This removes `ffmpegPath` and `ffmpegAudioInput`. Old `~/.zmeet/config.json` files (which carry those keys and lack `audio`) will no longer decode — that is intentional per the design's "regenerate, don't migrate" decision; Plan B's app handles first-run regeneration.

- [ ] **Step 4: Reshape `MeetingSession` in `Models.swift`**

Replace the entire `struct MeetingSession { ... }` with:

```swift
public struct MeetingSession: Codable, Equatable {
    public var id: String
    public var title: String
    public var sourceApp: String?
    public var startedAt: Date
    public var endedAt: Date?
    public var status: SessionStatus
    public var audioPath: String
    public var transcriptPath: String?
    public var notePath: String?
    public var recorderLogPath: String?
    public var errorMessage: String?

    public init(
        id: String,
        title: String,
        sourceApp: String?,
        startedAt: Date,
        endedAt: Date?,
        status: SessionStatus,
        audioPath: String,
        transcriptPath: String?,
        notePath: String?,
        recorderLogPath: String?,
        errorMessage: String?
    ) {
        self.id = id
        self.title = title
        self.sourceApp = sourceApp
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.status = status
        self.audioPath = audioPath
        self.transcriptPath = transcriptPath
        self.notePath = notePath
        self.recorderLogPath = recorderLogPath
        self.errorMessage = errorMessage
    }
}
```

- [ ] **Step 5: Remove the now-unused `recorderFailedToStart` error case**

In `Sources/ZMeetCore/Models.swift`, delete the `case recorderFailedToStart(String)` line from the `ZMeetError` enum, and delete its corresponding arm in the `errorDescription` switch:

```swift
        case .recorderFailedToStart(let detail):
            "Recorder failed to start: \(detail)"
```

> The build will still fail after this task because `SessionManager.swift` and `ProcessRunner.swift` reference removed fields/cases. Those are fixed in Tasks 4 and 5. Do not commit yet — Tasks 3–5 land together. (If your workflow requires green-per-task, continue straight through Task 5 before building/committing.)

---

### Task 4: Refactor `SessionManager` to orchestrate the injected recorder

**Files:**
- Modify: `Sources/ZMeetCore/SessionManager.swift`
- Create: `Tests/ZMeetCoreTests/MockRecorder.swift`
- Test: `Tests/ZMeetCoreTests/ZMeetCoreTests.swift`

- [ ] **Step 1: Create the mock recorder**

Create `Tests/ZMeetCoreTests/MockRecorder.swift`:

```swift
import Foundation
@testable import ZMeetCore

/// Test double for MeetingRecorder. Optionally simulates writing a non-empty
/// audio file on start so tests can exercise the recorded-vs-failed paths.
final class MockRecorder: MeetingRecorder {
    private(set) var startedURL: URL?
    private(set) var stopCount = 0
    var createsAudioFile: Bool
    var startError: Error?

    init(createsAudioFile: Bool = true) {
        self.createsAudioFile = createsAudioFile
    }

    func start(to url: URL, audio: AudioConfig) throws {
        if let startError { throw startError }
        startedURL = url
        if createsAudioFile {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            FileManager.default.createFile(atPath: url.path, contents: Data(repeating: 0, count: 32))
        }
    }

    func stop() throws {
        stopCount += 1
    }
}
```

- [ ] **Step 2: Write the failing start/stop/process test**

Add to `Tests/ZMeetCoreTests/ZMeetCoreTests.swift`:

```swift
private func makeTempConfig() -> (ZMeetConfig, URL) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("zmeet-tests-\(UUID().uuidString)", isDirectory: true)
    let config = ZMeetConfig(
        notesRepoPath: root.appendingPathComponent("notes").path,
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

@Test func startRejectsSecondConcurrentSession() throws {
    let (config, root) = makeTempConfig()
    defer { try? FileManager.default.removeItem(at: root) }

    let manager = SessionManager(config: config, recorder: MockRecorder())
    _ = try manager.start(title: "First", sourceApp: nil)

    #expect(throws: ZMeetError.self) {
        _ = try manager.start(title: "Second", sourceApp: nil)
    }
}
```

- [ ] **Step 3: Run to verify failure**

Run: `swift test --disable-sandbox --filter startStopProcessFlowWithMockRecorder`
Expected: FAIL to compile — `SessionManager` has no `recorder:` initializer parameter yet.

- [ ] **Step 4: Refactor `SessionManager.swift`**

Replace the top of the file (the `import` line, stored properties, and `init`) — i.e. lines from `import Darwin` through the end of `init(...)` — with:

```swift
import Foundation

public final class SessionManager {
    private let config: ZMeetConfig
    private let recorder: MeetingRecorder
    private let runner: ProcessRunner
    private let fileManager: FileManager

    private var appDataURL: URL {
        URL(fileURLWithPath: ZMeetPaths.expandTilde(config.appDataPath), isDirectory: true)
    }

    private var sessionsURL: URL {
        appDataURL.appendingPathComponent("sessions", isDirectory: true)
    }

    private var audioRootURL: URL {
        appDataURL.appendingPathComponent("audio", isDirectory: true)
    }

    private var logsURL: URL {
        appDataURL.appendingPathComponent("logs", isDirectory: true)
    }

    private var notesRepoURL: URL {
        URL(fileURLWithPath: ZMeetPaths.expandTilde(config.notesRepoPath), isDirectory: true)
    }

    public init(
        config: ZMeetConfig,
        recorder: MeetingRecorder,
        runner: ProcessRunner = ProcessRunner(),
        fileManager: FileManager = .default
    ) {
        self.config = config
        self.recorder = recorder
        self.runner = runner
        self.fileManager = fileManager
    }
```

- [ ] **Step 5: Replace `start(...)` with the recorder-driven version**

Replace the entire `public func start(title rawTitle: String, sourceApp: String?) throws -> MeetingSession { ... }` method with:

```swift
    public func start(title rawTitle: String, sourceApp: String?) throws -> MeetingSession {
        if let active = try activeSession() {
            throw ZMeetError.activeSessionExists(active.id)
        }

        try ensureRuntimeDirectories()

        let startedAt = Date()
        let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Untitled Meeting" : rawTitle
        let id = try uniqueSessionID(title: title, startedAt: startedAt)
        let datedAudioDirectory = audioRootURL
            .appendingPathComponent(ZMeetDates.year(startedAt), isDirectory: true)
            .appendingPathComponent(ZMeetDates.month(startedAt), isDirectory: true)
        try ZMeetPaths.ensureDirectory(datedAudioDirectory)

        let audioURL = datedAudioDirectory.appendingPathComponent("\(id).m4a")
        let logURL = logsURL.appendingPathComponent("\(id).recorder.log")

        // Start capture first; only persist a `.recording` session if it succeeds,
        // so a synchronous start failure never leaves a dangling session.
        try recorder.start(to: audioURL, audio: config.audio)

        let session = MeetingSession(
            id: id,
            title: title,
            sourceApp: sourceApp,
            startedAt: startedAt,
            endedAt: nil,
            status: .recording,
            audioPath: audioURL.path,
            transcriptPath: nil,
            notePath: nil,
            recorderLogPath: logURL.path,
            errorMessage: nil
        )

        try save(session)
        return session
    }
```

- [ ] **Step 6: Replace `stop()` with the recorder-driven version**

Replace the entire `public func stop() throws -> MeetingSession { ... }` method with:

```swift
    public func stop() throws -> MeetingSession {
        guard var session = try activeSession() else {
            throw ZMeetError.noActiveSession
        }

        try recorder.stop()

        session.endedAt = Date()
        session.status = .recorded
        try save(session)
        return session
    }
```

- [ ] **Step 7: Delete dead helpers and the FFmpeg device lister**

In `Sources/ZMeetCore/SessionManager.swift`, delete these three members entirely:
- the `public func listAudioDevices() throws -> ProcessResult { ... }` method
- the `private func waitForProcessToExit(pid: Int32, timeoutSeconds: TimeInterval) { ... }` method
- the `private func isProcessAlive(pid: Int32) -> Bool { ... }` method

- [ ] **Step 8: Run the tests to verify they pass**

Run: `swift test --disable-sandbox --filter startStopProcessFlowWithMockRecorder`
Then: `swift test --disable-sandbox --filter startRejectsSecondConcurrentSession`
Expected: PASS for both.

---

### Task 5: Remove `ProcessRunner.startDetached` and rebuild green

**Files:**
- Modify: `Sources/ZMeetCore/ProcessRunner.swift`

- [ ] **Step 1: Delete the unused `startDetached` method**

In `Sources/ZMeetCore/ProcessRunner.swift`, delete the entire `public func startDetached(...) throws -> Int32 { ... }` method. Keep `run`, `runShell`, and `resolveExecutable`.

- [ ] **Step 2: Build and run the full test suite**

Run: `swift build --disable-sandbox && swift test --disable-sandbox`
Expected: build succeeds; all tests pass (the 2 retained original tests + the new schema/recorder tests). No references to `recorderPID`, `ffmpegLogPath`, `ffmpegPath`, `ffmpegAudioInput`, `recorderFailedToStart`, or `startDetached` remain.

- [ ] **Step 3: Commit the coordinated model + recorder refactor (Tasks 2–5)**

```bash
git add Sources/ZMeetCore Tests/ZMeetCoreTests
git commit -m "Drive recording via injected MeetingRecorder; drop FFmpeg/PID model"
```

---

### Task 6: Crash recovery — `recoverInterruptedSessions()`

**Files:**
- Modify: `Sources/ZMeetCore/SessionManager.swift`
- Test: `Tests/ZMeetCoreTests/ZMeetCoreTests.swift`

- [ ] **Step 1: Write the failing recovery tests**

Add to `Tests/ZMeetCoreTests/ZMeetCoreTests.swift`:

```swift
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
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --disable-sandbox --filter recoveryFinalizesSessionWithAudio`
Expected: FAIL to compile — `recoverInterruptedSessions` does not exist.

- [ ] **Step 3: Implement `recoverInterruptedSessions()`**

In `Sources/ZMeetCore/SessionManager.swift`, add this method (place it just after `public func listSessions()`):

```swift
    /// Finalizes sessions left in `.recording` by a crash or force-quit. A session
    /// whose audio file exists and is non-empty becomes `.recorded`; otherwise it
    /// becomes `.failed`. Returns the sessions whose status changed.
    @discardableResult
    public func recoverInterruptedSessions() throws -> [MeetingSession] {
        var recovered: [MeetingSession] = []

        for var session in try listSessions() where session.status == .recording {
            let attributes = try? fileManager.attributesOfItem(atPath: session.audioPath)
            let size = (attributes?[.size] as? Int) ?? 0

            if fileManager.fileExists(atPath: session.audioPath), size > 0 {
                session.status = .recorded
            } else {
                session.status = .failed
                session.errorMessage = "Recording was interrupted before any audio was captured."
            }
            session.endedAt = session.endedAt ?? Date()

            try save(session)
            recovered.append(session)
        }

        return recovered
    }
```

- [ ] **Step 4: Run the recovery tests to verify they pass**

Run: `swift test --disable-sandbox --filter recovery`
Expected: PASS — all three `recovery*` tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/ZMeetCore/SessionManager.swift Tests/ZMeetCoreTests/ZMeetCoreTests.swift
git commit -m "Add crash recovery for interrupted recording sessions"
```

---

### Task 7: Update the transcript placeholder text (no CLI references)

**Files:**
- Modify: `Sources/ZMeetCore/MarkdownRenderer.swift`
- Test: `Tests/ZMeetCoreTests/ZMeetCoreTests.swift`

- [ ] **Step 1: Write the failing test**

Add to `Tests/ZMeetCoreTests/ZMeetCoreTests.swift`:

```swift
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
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --disable-sandbox --filter transcriptPlaceholderDoesNotReferenceRetiredCLI`
Expected: FAIL — the current placeholder contains `zmeet process` / `zmeet config set`.

- [ ] **Step 3: Update the placeholder string**

In `Sources/ZMeetCore/MarkdownRenderer.swift`, replace the entire body of `renderTranscriptPlaceholder(session:)` with:

```swift
    public func renderTranscriptPlaceholder(session: MeetingSession) -> String {
        """
        # Transcript: \(session.title)

        Transcript generation is not configured yet.

        Audio source:

        `\(session.audioPath)`

        Set `transcriptionCommand` in `~/.zmeet/config.json`, then re-process this
        meeting from the ZMeet menu-bar app (it will re-run transcription and
        regenerate this note).
        """
    }
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --disable-sandbox --filter transcriptPlaceholderDoesNotReferenceRetiredCLI`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/ZMeetCore/MarkdownRenderer.swift Tests/ZMeetCoreTests/ZMeetCoreTests.swift
git commit -m "Drop retired-CLI references from transcript placeholder"
```

---

### Task 8: Final verification + phases-doc note

**Files:**
- Modify: `docs/IMPLEMENTATION_PHASES.md`

- [ ] **Step 1: Run the full build and test suite**

Run: `swift build --disable-sandbox && swift test --disable-sandbox`
Expected: build succeeds; every test passes (original `slugifyProducesStableIDs`, `relativePathHandlesSiblingTrees`, plus all tests added in this plan).

- [ ] **Step 2: Record the architecture change in the phases doc**

In `docs/IMPLEMENTATION_PHASES.md`, replace the `## Phase 3: Menu Bar App` section heading line (`## Phase 3: Menu Bar App`) with:

```markdown
## Phase 3: Menu Bar App (pulled forward — see docs/superpowers/specs/2026-05-26-native-recorder-design.md)

The FFmpeg CLI recorder was replaced by a native, signed ZMeet.app menu-bar app
capturing system audio + microphone (ScreenCaptureKit + AVAudioEngine) mixed to
`.m4a`. The `zmeet` CLI is retired; ZMeetCore remains the engine. ZMeetCore work
is Plan A (`docs/superpowers/plans/2026-05-26-zmeetcore-recorder-refactor.md`);
the app is Plan B.
```

- [ ] **Step 3: Commit**

```bash
git add docs/IMPLEMENTATION_PHASES.md
git commit -m "Note menu-bar pivot in implementation phases"
```

---

## Self-Review

**Spec coverage:**
- System+mic mixed `.m4a` contract → preserved as the recorder's responsibility (Plan B); Core keeps `audioPath`/`.m4a` and `AudioConfig` (Task 3). ✓
- Retire CLI, keep ZMeetCore → Task 1. ✓
- macOS 15+ target → `Package.swift` platform bump (Task 1). ✓
- Recorder protocol in Core, implementation in app → Task 2 + Task 4 injection. ✓
- Model changes (drop `recorderPID`/`ffmpegLogPath`, add `recorderLogPath`; drop `ffmpegPath`/`ffmpegAudioInput`, add `audio` + `autoProcessOnStop`) → Task 3. ✓
- Breaking config change, regenerate not migrate → noted in Task 3. ✓
- Dangling-session recovery replacing PID check → Task 6. ✓
- start→stop→process testable with mock recorder → Task 4. ✓
- Capture pipeline / SCStream / AVAudioEngine / menu-bar UI / permissions / signing → **deferred to Plan B** (out of scope for this plan, by design). ✓
- `autoProcessOnStop` *behavior* (auto-triggering process after stop) → config flag added here (Task 3); the wiring that reads it and dispatches `process()` in the background is Plan B (app-side), since Core stays synchronous. Noted.

**Placeholder scan:** No "TBD"/"handle edge cases"/"similar to" placeholders; every code step shows complete code. The deferred-commit notes in Tasks 2–3 are explicit sequencing instructions, not placeholders.

**Type consistency:** `MeetingRecorder.start(to:audio:)` / `stop()` used identically in the protocol (Task 2), `MockRecorder` (Task 4), and `SessionManager` (Task 4). `SessionManager.init(config:recorder:runner:fileManager:)` matches all test call sites. `AudioConfig` field names (`captureSystemAudio`, `captureMicrophone`, `sampleRate`, `bitrate`) consistent across Task 3 definition and Task 3 tests. `MeetingSession` initializer (with `recorderLogPath`, without PID/ffmpeg fields) matches every construction site (Task 3 tests, Task 4 `start`, Task 7 test).
