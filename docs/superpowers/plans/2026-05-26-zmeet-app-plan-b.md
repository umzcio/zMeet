# ZMeet Menu-Bar App — Implementation Plan (Plan B of 2)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Build `ZMeet.app`, a signed macOS menu-bar app that records a meeting (system audio + microphone, mixed to `.m4a`) and turns it into a markdown note via the existing `ZMeetCore` engine.

**Architecture:** A SwiftPM executable target (`ZMeetApp`) provides a SwiftUI `MenuBarExtra` app. A build script bundles the compiled binary into a code-signed `ZMeet.app` (Developer ID + hardened runtime) so macOS grants persistent Microphone + Screen Recording permissions. Recording is performed by a `MeetingRecorder` implementation; we ship a `StubRecorder` first (Milestone 1) to prove the UI + session + notes pipeline end-to-end, then a real `SCKAudioRecorder` (ScreenCaptureKit + AVAudioEngine, Milestone 2).

**Tech Stack:** Swift 6, SwiftPM, SwiftUI (`MenuBarExtra`), ScreenCaptureKit, AVFoundation/AVAudioEngine, `codesign`. Signing identity: `Developer ID Application: The University of Montana (5JJ6G6A84S)`. Target: macOS 15+ (dev machine is macOS 26.4).

**Reality note for the human:** The app UI and session pipeline are verified by building and *running* the app (not unit tests) — GUI and audio capture can't be unit-tested headlessly. Milestone 2's audio recorder will almost certainly need a round or two of on-device iteration (does it launch, do the permission prompts appear, is there audio, are both voices present). That's expected, not a failure.

---

## File Structure

| File | Responsibility |
|------|----------------|
| `Package.swift` (modify) | Add `ZMeetApp` executable target depending on `ZMeetCore` |
| `Sources/ZMeetApp/ZMeetApp.swift` | `@main` SwiftUI `App` + `MenuBarExtra` host |
| `Sources/ZMeetApp/AppState.swift` | `ObservableObject` controller: config bootstrap, recording state, recent list, start/stop, auto-process |
| `Sources/ZMeetApp/MenuContentView.swift` | The dropdown UI (idle + recording states, recent meetings) |
| `Sources/ZMeetApp/StubRecorder.swift` | `MeetingRecorder` that writes a placeholder file (Milestone 1) |
| `Sources/ZMeetApp/Permissions.swift` | Microphone + Screen Recording status/request (Milestone 2) |
| `Sources/ZMeetApp/SCKAudioRecorder.swift` | Real recorder: SCStream (system+mic) → AVAudioEngine mixer → `.m4a` (Milestone 2) |
| `scripts/build-app.sh` | Compile, assemble `ZMeet.app` bundle (Info.plist + entitlements), code-sign |
| `scripts/ZMeet.entitlements` | Hardened-runtime entitlements (audio-input) |

---

# MILESTONE 1 — A launchable app with a stub recorder

Goal of this milestone: you run `scripts/build-app.sh`, `open build/ZMeet.app`, see a microphone icon in your menu bar, click it, type a title, click **Start**, click **Stop**, and a markdown note appears in your notes repo and in the "Recent" list. No real audio yet.

---

### Task 1: Add the app target and prove it launches in the menu bar

**Files:**
- Modify: `Package.swift`
- Create: `Sources/ZMeetApp/ZMeetApp.swift`
- Create: `scripts/ZMeet.entitlements`
- Create: `scripts/build-app.sh`

- [ ] **Step 1: Add the executable target to `Package.swift`**

In `Package.swift`, add a product and target. The `products` array becomes:

```swift
    products: [
        .library(name: "ZMeetCore", targets: ["ZMeetCore"]),
        .executable(name: "ZMeetApp", targets: ["ZMeetApp"])
    ],
```

and add to the `targets` array (after the `ZMeetCore` target):

```swift
        .executableTarget(
            name: "ZMeetApp",
            dependencies: ["ZMeetCore"]
        ),
```

- [ ] **Step 2: Create a minimal menu-bar app**

Create `Sources/ZMeetApp/ZMeetApp.swift`:

```swift
import SwiftUI

@main
struct ZMeetApp: App {
    var body: some Scene {
        MenuBarExtra("ZMeet", systemImage: "mic") {
            VStack(alignment: .leading, spacing: 8) {
                Text("ZMeet").font(.headline)
                Text("Menu bar app is running.")
                Divider()
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
            .padding(12)
            .frame(width: 240)
        }
        .menuBarExtraStyle(.window)
    }
}
```

- [ ] **Step 3: Create the entitlements file**

Create `scripts/ZMeet.entitlements`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.device.audio-input</key>
    <true/>
</dict>
</plist>
```

- [ ] **Step 4: Create the bundle + sign script**

Create `scripts/build-app.sh` and make it executable (`chmod +x scripts/build-app.sh`):

```bash
#!/bin/bash
set -euo pipefail

# Builds Sources/ZMeetApp into a signed ZMeet.app bundle.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="ZMeet"
BUNDLE_ID="edu.umontana.zmeet"
IDENTITY="Developer ID Application: The University of Montana (5JJ6G6A84S)"
APP_DIR="$ROOT/build/$APP_NAME.app"
MACOS_DIR="$APP_DIR/Contents/MacOS"
RES_DIR="$APP_DIR/Contents/Resources"

echo "==> Compiling ZMeetApp (release)"
swift build -c release --product ZMeetApp --package-path "$ROOT"
BIN="$(swift build -c release --product ZMeetApp --package-path "$ROOT" --show-bin-path)/ZMeetApp"

echo "==> Assembling bundle at $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RES_DIR"
cp "$BIN" "$MACOS_DIR/$APP_NAME"

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>LSUIElement</key><true/>
    <key>NSMicrophoneUsageDescription</key><string>ZMeet records your microphone during meetings to create notes.</string>
</dict>
</plist>
PLIST

echo "==> Code signing with: $IDENTITY"
codesign --force --options runtime \
    --entitlements "$ROOT/scripts/ZMeet.entitlements" \
    --sign "$IDENTITY" \
    --timestamp \
    "$APP_DIR"

echo "==> Verifying signature"
codesign --verify --strict --verbose=2 "$APP_DIR"
echo "==> Done: $APP_DIR"
echo "Run it with:  open \"$APP_DIR\""
```

- [ ] **Step 5: Build, bundle, sign, and RUN — verify the icon appears**

Run:
```bash
swift build --disable-sandbox 2>&1 | tail -2
bash scripts/build-app.sh
open build/ZMeet.app
```
Expected: build succeeds; the script prints "Done"; a microphone icon appears in the menu bar; clicking it shows the "ZMeet — Menu bar app is running" panel with a Quit button. (If the icon does not appear, check Console.app for crash logs and report.)

> **HUMAN CHECKPOINT:** This is the first time you can see the app. Confirm the menu-bar icon shows up before continuing.

- [ ] **Step 6: Commit**

```bash
git add Package.swift Sources/ZMeetApp/ZMeetApp.swift scripts/ZMeet.entitlements scripts/build-app.sh
git commit -m "Add launchable ZMeet menu-bar app shell with bundle/sign script"
```

---

### Task 2: AppState controller + stub recorder (session lifecycle wired to the engine)

**Files:**
- Create: `Sources/ZMeetApp/StubRecorder.swift`
- Create: `Sources/ZMeetApp/AppState.swift`

- [ ] **Step 1: Create the stub recorder**

Create `Sources/ZMeetApp/StubRecorder.swift`:

```swift
import Foundation
import ZMeetCore

/// Placeholder recorder for Milestone 1: writes a tiny non-empty file at the
/// audio path so the session/notes pipeline runs end-to-end without real audio.
/// Replaced by SCKAudioRecorder in Milestone 2.
final class StubRecorder: MeetingRecorder {
    func start(to url: URL, logURL: URL, audio: AudioConfig) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(
            atPath: url.path,
            contents: Data("zmeet stub recording\n".utf8)
        )
    }

    func stop() throws {
        // Nothing to finalize for the stub.
    }
}
```

- [ ] **Step 2: Create the AppState controller**

Create `Sources/ZMeetApp/AppState.swift`:

```swift
import Foundation
import SwiftUI
import ZMeetCore

@MainActor
final class AppState: ObservableObject {
    enum Phase: Equatable {
        case idle
        case recording(since: Date)
        case processing
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var recent: [MeetingSession] = []
    @Published var draftTitle: String = ""
    @Published private(set) var lastError: String?

    private let store = ConfigStore()
    private let config: ZMeetConfig
    private let manager: SessionManager

    init(recorder: MeetingRecorder = StubRecorder()) {
        // Load config, or bootstrap a fresh one if missing/old-schema.
        let loaded: ZMeetConfig
        if let existing = try? store.load() {
            loaded = existing
        } else {
            loaded = (try? store.bootstrap(notesRepoPath: "~/Documents/Github/zMeetNotes"))
                ?? ZMeetConfig.default(notesRepoPath: "~/Documents/Github/zMeetNotes")
        }
        self.config = loaded
        self.manager = SessionManager(config: loaded, recorder: recorder)

        // Finalize any session interrupted by a previous crash/quit.
        _ = try? manager.recoverInterruptedSessions()
        reloadRecent()
    }

    var isRecording: Bool {
        if case .recording = phase { return true }
        return false
    }

    func startRecording() {
        lastError = nil
        do {
            _ = try manager.start(title: draftTitle, sourceApp: nil)
            phase = .recording(since: Date())
            draftTitle = ""
            reloadRecent()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func stopRecording() {
        lastError = nil
        do {
            let stopped = try manager.stop()
            reloadRecent()
            if config.autoProcessOnStop {
                process(id: stopped.id)
            } else {
                phase = .idle
            }
        } catch {
            phase = .idle
            lastError = error.localizedDescription
            reloadRecent()
        }
    }

    func process(id: String) {
        phase = .processing
        Task.detached { [manager] in
            let result = Result { try manager.process(id: id) }
            await MainActor.run {
                if case .failure(let error) = result {
                    self.lastError = error.localizedDescription
                }
                self.phase = .idle
                self.reloadRecent()
            }
        }
    }

    func revealNote(_ session: MeetingSession) {
        guard let path = session.notePath else { return }
        NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
    }

    private func reloadRecent() {
        recent = (try? manager.listSessions().prefix(10).map { $0 }) ?? []
    }
}
```

> Note: `SessionManager` is not `Sendable`; `process(id:)` captures only the `manager` reference inside a detached task and hops back to `@MainActor` for state updates. `SessionManager`'s `process` only touches the filesystem, so this is safe in practice. If Swift 6 strict concurrency rejects the capture during the build, wrap the manager call in `MainActor.run` instead of `Task.detached` (processing will block the main actor briefly — acceptable for Milestone 1; revisit in Milestone 2).

- [ ] **Step 3: Build to verify it compiles**

Run: `swift build --disable-sandbox 2>&1 | tail -3`
Expected: build succeeds. (If a Swift 6 concurrency error appears on `Task.detached`, apply the fallback in the note above, then rebuild.)

- [ ] **Step 4: Commit**

```bash
git add Sources/ZMeetApp/StubRecorder.swift Sources/ZMeetApp/AppState.swift
git commit -m "Add AppState controller and stub recorder wired to ZMeetCore"
```

---

### Task 3: The dropdown UI, wired to AppState

**Files:**
- Create: `Sources/ZMeetApp/MenuContentView.swift`
- Modify: `Sources/ZMeetApp/ZMeetApp.swift`

- [ ] **Step 1: Create the menu content view**

Create `Sources/ZMeetApp/MenuContentView.swift`:

```swift
import SwiftUI
import ZMeetCore

struct MenuContentView: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            switch state.phase {
            case .idle:
                idleControls
            case .recording(let since):
                recordingControls(since: since)
            case .processing:
                Label("Processing…", systemImage: "gearshape.2")
                    .foregroundStyle(.secondary)
            }

            if let error = state.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()
            recentList
            Divider()

            Button("Quit ZMeet") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
        .padding(12)
        .frame(width: 320)
    }

    private var header: some View {
        HStack {
            Image(systemName: state.isRecording ? "record.circle.fill" : "mic")
                .foregroundStyle(state.isRecording ? .red : .primary)
            Text("ZMeet").font(.headline)
            Spacer()
        }
    }

    private var idleControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Meeting title", text: $state.draftTitle)
                .textFieldStyle(.roundedBorder)
            Button {
                state.startRecording()
            } label: {
                Label("Start Recording", systemImage: "record.circle")
            }
        }
    }

    private func recordingControls(since: Date) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            TimelineView(.periodic(from: since, by: 1)) { _ in
                Label(elapsed(since: since), systemImage: "record.circle.fill")
                    .foregroundStyle(.red)
                    .monospacedDigit()
            }
            Button(role: .destructive) {
                state.stopRecording()
            } label: {
                Label("Stop", systemImage: "stop.circle")
            }
        }
    }

    private var recentList: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Recent").font(.caption).foregroundStyle(.secondary)
            if state.recent.isEmpty {
                Text("No meetings yet").font(.caption).foregroundStyle(.tertiary)
            } else {
                ForEach(state.recent, id: \.id) { session in
                    Button {
                        if session.notePath != nil { state.revealNote(session) }
                    } label: {
                        HStack {
                            Text(statusGlyph(session.status))
                            Text(session.title).lineLimit(1)
                            Spacer()
                            Text(session.status.rawValue)
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func elapsed(since: Date) -> String {
        let total = Int(Date().timeIntervalSince(since))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    private func statusGlyph(_ status: SessionStatus) -> String {
        switch status {
        case .recording: return "●"
        case .recorded:  return "■"
        case .processed: return "✓"
        case .failed:    return "⚠"
        }
    }
}
```

- [ ] **Step 2: Wire it into the app entry**

Replace the entire contents of `Sources/ZMeetApp/ZMeetApp.swift` with:

```swift
import SwiftUI

@main
struct ZMeetApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(state: state)
        } label: {
            Image(systemName: state.isRecording ? "record.circle.fill" : "mic")
        }
        .menuBarExtraStyle(.window)
    }
}
```

- [ ] **Step 3: Build, bundle, run, and exercise the full stub flow**

Run:
```bash
swift build --disable-sandbox 2>&1 | tail -2
bash scripts/build-app.sh
open build/ZMeet.app
```
Then by hand: click the menu-bar icon → type a title → **Start Recording** (icon turns red, timer counts) → **Stop**. The status should go to "Processing…" then back to idle, and a `✓ <title> processed` row should appear under Recent. Click it to reveal the note file in Finder. Open the note and the transcript to confirm the markdown was written.

> **HUMAN CHECKPOINT (Milestone 1 complete):** You now have a working app shell — record (stubbed), stop, auto-process, note created, revealed in Finder. The only thing missing is real audio. Confirm this works before starting Milestone 2.

- [ ] **Step 4: Commit**

```bash
git add Sources/ZMeetApp/MenuContentView.swift Sources/ZMeetApp/ZMeetApp.swift
git commit -m "Add menu-bar dropdown UI wired to recording lifecycle"
```

---

# MILESTONE 2 — Real audio capture (system + microphone)

Goal: replace the stub with a real recorder. After this, recording captures your mic + the other participants' audio mixed into the `.m4a`. This part needs on-device permission grants and will likely need iteration.

---

### Task 4: Permissions (Microphone + Screen Recording)

**Files:**
- Create: `Sources/ZMeetApp/Permissions.swift`
- Modify: `Sources/ZMeetApp/AppState.swift`
- Modify: `Sources/ZMeetApp/MenuContentView.swift`

- [ ] **Step 1: Create the permissions helper**

Create `Sources/ZMeetApp/Permissions.swift`:

```swift
import AVFoundation
import CoreGraphics
import AppKit

enum Permissions {
    /// Microphone: returns true if authorized, requesting access if undetermined.
    static func ensureMicrophone() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        default:
            return false
        }
    }

    /// Screen Recording (required by ScreenCaptureKit even for audio-only).
    /// CGPreflight returns current status; CGRequest triggers the system prompt.
    static func hasScreenRecording() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    @discardableResult
    static func requestScreenRecording() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    static func openScreenRecordingSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        NSWorkspace.shared.open(url)
    }
}
```

- [ ] **Step 2: Surface permission status in AppState**

In `Sources/ZMeetApp/AppState.swift`, add published properties after `@Published var lastError`:

```swift
    @Published var micGranted: Bool = false
    @Published var screenGranted: Bool = false
```

Add this method to `AppState`:

```swift
    func refreshPermissions() {
        screenGranted = Permissions.hasScreenRecording()
        micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    /// Request both permissions; returns true only if both are granted.
    func requestPermissions() async -> Bool {
        let mic = await Permissions.ensureMicrophone()
        if !Permissions.hasScreenRecording() {
            Permissions.requestScreenRecording()
        }
        await MainActor.run { self.refreshPermissions() }
        return mic && Permissions.hasScreenRecording()
    }
```

Add `import AVFoundation` to the top of `AppState.swift`. Call `refreshPermissions()` at the end of `init`.

- [ ] **Step 3: Gate Start on permissions in `startRecording()`**

Replace `startRecording()` in `AppState.swift` with:

```swift
    func startRecording() {
        lastError = nil
        Task {
            let ok = await requestPermissions()
            guard ok else {
                self.lastError = "Microphone and Screen Recording permission are required. Grant them in System Settings → Privacy & Security."
                Permissions.openScreenRecordingSettings()
                return
            }
            do {
                _ = try self.manager.start(title: self.draftTitle, sourceApp: nil)
                self.phase = .recording(since: Date())
                self.draftTitle = ""
                self.reloadRecent()
            } catch {
                self.lastError = error.localizedDescription
            }
        }
    }
```

- [ ] **Step 4: Show a permissions row in the UI**

In `MenuContentView.swift`, add this view and place `permissionsRow` just above the final `Divider()` (before the Quit button):

```swift
    private var permissionsRow: some View {
        HStack(spacing: 12) {
            Label {
                Text("Mic")
            } icon: {
                Image(systemName: state.micGranted ? "checkmark.circle.fill" : "xmark.circle")
                    .foregroundStyle(state.micGranted ? .green : .orange)
            }
            Label {
                Text("Screen")
            } icon: {
                Image(systemName: state.screenGranted ? "checkmark.circle.fill" : "xmark.circle")
                    .foregroundStyle(state.screenGranted ? .green : .orange)
            }
            Spacer()
            Button("Grant") { Permissions.openScreenRecordingSettings() }
                .font(.caption)
        }
        .font(.caption)
        .onAppear { state.refreshPermissions() }
    }
```

Add `permissionsRow` and a `Divider()` before the Quit button in `body`.

- [ ] **Step 5: Build to verify it compiles**

Run: `swift build --disable-sandbox 2>&1 | tail -3`
Expected: build succeeds.

- [ ] **Step 6: Commit**

```bash
git add Sources/ZMeetApp/Permissions.swift Sources/ZMeetApp/AppState.swift Sources/ZMeetApp/MenuContentView.swift
git commit -m "Add Microphone + Screen Recording permission flow"
```

---

### Task 5: SCKAudioRecorder — real capture (system + mic → mixed .m4a)

**Files:**
- Create: `Sources/ZMeetApp/SCKAudioRecorder.swift`
- Modify: `Sources/ZMeetApp/ZMeetApp.swift`

> This is the hard, on-device-iteration task. The implementation below is a complete, reasonable first version: one `SCStream` captures system audio and the microphone (macOS 15 `captureMicrophone`); both buffer streams are pushed into an `AVAudioEngine` via two `AVAudioPlayerNode`s, mixed at `mainMixerNode`, and the mix is tapped and written to an AAC `.m4a` with `AVAudioFile`. Expect to iterate after the first real recording.

- [ ] **Step 1: Implement the recorder**

Create `Sources/ZMeetApp/SCKAudioRecorder.swift`:

```swift
import Foundation
import AVFoundation
import ScreenCaptureKit
import ZMeetCore

/// Captures system audio + microphone via one SCStream (macOS 15+), mixes them
/// through an AVAudioEngine, and writes a mixed AAC .m4a via AVAudioFile.
final class SCKAudioRecorder: NSObject, MeetingRecorder, SCStreamOutput, @unchecked Sendable {
    private var stream: SCStream?
    private let engine = AVAudioEngine()
    private let systemPlayer = AVAudioPlayerNode()
    private let micPlayer = AVAudioPlayerNode()
    private var audioFile: AVAudioFile?
    private var logHandle: FileHandle?
    private let queue = DispatchQueue(label: "edu.umontana.zmeet.capture")

    func start(to url: URL, logURL: URL, audio: AudioConfig) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        logHandle = try? FileHandle(forWritingTo: logURL)
        log("start: \(url.lastPathComponent)")

        let mixFormat = engine.mainMixerNode.outputFormat(forBus: 0)
        audioFile = try AVAudioFile(
            forWriting: url,
            settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: audio.sampleRate,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: audio.bitrate
            ]
        )

        engine.attach(systemPlayer)
        engine.attach(micPlayer)
        engine.connect(systemPlayer, to: engine.mainMixerNode, format: nil)
        engine.connect(micPlayer, to: engine.mainMixerNode, format: nil)

        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 4096, format: mixFormat) { [weak self] buffer, _ in
            guard let self, let file = self.audioFile else { return }
            do { try file.write(from: buffer) } catch { self.log("write error: \(error)") }
        }

        try engine.start()
        systemPlayer.play()
        micPlayer.play()

        Task { try await self.startStream(audio: audio) }
    }

    private func startStream(audio: AudioConfig) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else {
            log("no display available")
            return
        }

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = audio.captureSystemAudio
        config.sampleRate = audio.sampleRate
        config.channelCount = 2
        config.captureMicrophone = audio.captureMicrophone
        // Keep video minimal; we only consume audio.
        config.width = 2
        config.height = 2

        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        if audio.captureMicrophone {
            try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: queue)
        }
        self.stream = stream
        try await stream.startCapture()
        log("stream started")
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid, let pcm = Self.pcmBuffer(from: sampleBuffer) else { return }
        switch type {
        case .audio:      systemPlayer.scheduleBuffer(pcm, completionHandler: nil)
        case .microphone: micPlayer.scheduleBuffer(pcm, completionHandler: nil)
        default: break
        }
    }

    func stop() throws {
        log("stop")
        if let stream {
            let sem = DispatchSemaphore(value: 0)
            stream.stopCapture { _ in sem.signal() }
            _ = sem.wait(timeout: .now() + 5)
        }
        stream = nil
        engine.mainMixerNode.removeTap(onBus: 0)
        systemPlayer.stop()
        micPlayer.stop()
        engine.stop()
        audioFile = nil   // closes/finalizes the file
        try? logHandle?.close()
        logHandle = nil
    }

    private static func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let formatDesc = sampleBuffer.formatDescription,
              let asbd = formatDesc.audioStreamBasicDescription else { return nil }
        var asbdVar = asbd
        guard let format = AVAudioFormat(streamDescription: &asbdVar) else { return nil }
        let frames = AVAudioFrameCount(sampleBuffer.numSamples)
        guard frames > 0, let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        pcm.frameLength = frames
        do {
            try sampleBuffer.copyPCMData(
                fromRange: 0..<Int(frames),
                into: pcm.mutableAudioBufferList
            )
        } catch { return nil }
        return pcm
    }

    private func log(_ message: String) {
        let line = "[\(Date())] \(message)\n"
        logHandle?.write(Data(line.utf8))
    }
}
```

- [ ] **Step 2: Use the real recorder in the app**

In `Sources/ZMeetApp/ZMeetApp.swift`, change the `@StateObject` line to inject the real recorder:

```swift
    @StateObject private var state = AppState(recorder: SCKAudioRecorder())
```

- [ ] **Step 3: Build, bundle, sign**

Run:
```bash
swift build --disable-sandbox 2>&1 | tail -3
bash scripts/build-app.sh
```
Expected: build succeeds and the bundle is signed. If the build fails with ScreenCaptureKit API errors (the exact `SCStreamConfiguration`/`SCStreamOutputType` member names or `copyPCMData` signature can differ by SDK), STOP and report the exact compiler errors — these are API-shape mismatches to resolve against the installed SDK, not logic bugs.

- [ ] **Step 4: On-device recording test (HUMAN)**

1. `open build/ZMeet.app`
2. Click the icon → **Start Recording**. Approve the Microphone prompt and the Screen Recording prompt. (Screen Recording may require toggling ZMeet on in System Settings → Privacy & Security → Screen Recording, then re-launching — macOS quirk.)
3. Play some audio (e.g. a YouTube video) and talk into your mic for ~10 seconds.
4. **Stop**. Wait for "processed".
5. Reveal the note, then open the `.m4a` (its path is in the note's frontmatter `audio_path`) in QuickTime and confirm you hear BOTH the system audio and your voice.

> **HUMAN CHECKPOINT:** Report what happened — icon/permission behavior, whether the `.m4a` plays, whether both sources are audible, any console errors or the contents of the `<id>.recorder.log` (under `~/.zmeet/logs/`). We iterate from real results.

- [ ] **Step 5: Commit (once a recording produces audio)**

```bash
git add Sources/ZMeetApp/SCKAudioRecorder.swift Sources/ZMeetApp/ZMeetApp.swift
git commit -m "Add ScreenCaptureKit recorder capturing system audio + microphone"
```

---

### Task 6: README quickstart

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Document how to build and run**

Add a "Quickstart" section to `README.md`:

```markdown
## Quickstart (macOS 15+)

Build and sign the app:

    bash scripts/build-app.sh

Run it:

    open build/ZMeet.app

A microphone icon appears in the menu bar. Click it, give the meeting a title,
and press **Start Recording**. Grant Microphone and Screen Recording permission
when prompted (Screen Recording is required to capture other participants'
audio). Press **Stop** — ZMeet finalizes the recording and writes a markdown
note into your notes repo (default `~/Documents/Github/zMeetNotes`).

Configuration lives in `~/.zmeet/config.json` (transcription/summary commands,
audio settings, auto-process toggle).
```

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "Document menu-bar app quickstart"
```

---

## Self-Review

**Spec coverage** (against `docs/superpowers/specs/2026-05-26-native-recorder-design.md`):
- Menu-bar app, single always-on icon, timer in dropdown (not menu bar) → Tasks 1, 3. ✓
- System audio + mic mixed to `.m4a` via SCStream + AVAudioEngine (Approach A) → Task 5. ✓
- Signed `.app`, hardened runtime, `NSMicrophoneUsageDescription`, `LSUIElement`, audio-input entitlement → Task 1 (build script + entitlements). ✓ (Build approach changed from Xcode to SwiftPM+script — justified by Developer ID giving a stable signature; recorded here.)
- Permissions flow (mic + screen recording, deep link to settings) → Task 4. ✓
- Auto-process on stop, `autoProcessOnStop` config-gated → AppState `stopRecording`. ✓
- Recent meetings list, reveal note, failed→retry via process → Task 3 (reveal; retry is `process(id:)` which the recent row can call — note: row currently reveals; retry-on-failed is a follow-up if desired). ✓ (reveal covered; explicit retry button deferred — acceptable, `process(id:)` exists)
- Crash/dangling-session recovery on launch → AppState `init` calls `recoverInterruptedSessions`. ✓
- Live level meter → **deferred.** The spec listed a level meter; the elapsed timer gives recording feedback for v1. The meter requires plumbing RMS out of the recorder tap and is a good follow-up, not required for a working recorder. Flagged here intentionally.

**Placeholder scan:** No TBD/TODO/"handle errors" placeholders; every code step has complete code. The SCK task explicitly flags API-shape verification against the SDK (legitimate, not a placeholder) and the human checkpoints are real verification steps.

**Type consistency:** `MeetingRecorder.start(to:logURL:audio:)` / `stop()` matches `StubRecorder` (Task 2), `SCKAudioRecorder` (Task 5), and is called via `SessionManager` (from `ZMeetCore`). `AppState(recorder:)` initializer matches both injection sites (Task 2 default `StubRecorder()`, Task 5 `SCKAudioRecorder()`). `AppState.Phase`, `phase`, `recent`, `draftTitle`, `lastError`, `micGranted`, `screenGranted`, `startRecording`, `stopRecording`, `process(id:)`, `revealNote`, `refreshPermissions`, `requestPermissions` are used consistently between `AppState.swift` and `MenuContentView.swift`.
