# zMeet Native Recorder + Menu-Bar App — Design

**Date:** 2026-05-26
**Status:** Approved for planning
**Supersedes:** The FFmpeg CLI recorder path from Phase 1; pulls Phase 3 (menu-bar app) forward.

## Problem

Phase 1 records audio by spawning the FFmpeg CLI with an AVFoundation input. That fails:
FFmpeg launched from a terminal cannot reliably see an AVFoundation audio device and has no
durable macOS capture permissions, so `zmeet start` errors with *Invalid audio device index*.

The deeper issue is the permission model, not FFmpeg. A meeting recorder needs **system audio**
(remote participants) plus the **microphone**, mixed into one track. System-audio capture requires
the Screen Recording TCC permission, and macOS keys permission grants to a stable code signature.
A terminal-launched binary has neither a stable signature nor a reliable path to those grants.

## Decisions

These were settled during brainstorming and are fixed inputs to the plan:

1. **Audio sources:** system audio + microphone, **mixed into a single track**, encoded to the
   existing `.m4a` / AAC contract.
2. **Product shape:** `ZMeet.app`, a menu-bar app, becomes the product. **`ZMeetCore` is retained**
   as the reusable engine. The `zmeet` CLI is **retired**.
3. **OS target:** macOS 15+ (development machine is macOS 26). This unlocks `SCStream` native
   microphone capture, so a single capture subsystem provides both audio streams.
4. **Packaging:** **hybrid** — `ZMeetCore` stays a SwiftPM package (keeps `swift test`); a new
   Xcode project builds `ZMeet.app` and references the package by path.
5. **Signing:** Developer ID (paid account). Hardened runtime; TCC grants persist across rebuilds.
6. **Capture pipeline:** **Approach A** — one `SCStream` (system + mic) → `AVAudioEngine` mixer →
   AAC `.m4a` via `AVAudioFile`. `AVAudioEngine` handles resampling and clock-drift between streams.
7. **Processing trigger:** auto-process after Stop, controlled by an `autoProcessOnStop` config flag
   (default `true`).
8. **Menu-bar footprint:** a single always-on monochrome template icon (one slot). No elapsed-time
   text in the bar; the timer lives in the dropdown. No global hotkey and no hide-when-idle for now
   (revisit if the 13" screen feels tight).

## Architecture

```
ZMeet.app  (Xcode target, signed, LSUIElement menu-bar app, macOS 15+)
│  ├─ MenuBarExtra UI        — start/stop, status, recent meetings, permissions/settings
│  ├─ RecordingController    — owns capture lifecycle; bridges UI ↔ ZMeetCore ↔ recorder
│  └─ SCKAudioRecorder       — SCStream + AVAudioEngine → .m4a (concrete MeetingRecorder)
│
└─ depends on ──▶ ZMeetCore  (SwiftPM package — the engine)
                   ├─ SessionManager      — session lifecycle + process() (recorder-agnostic)
                   ├─ Models              — MeetingSession, ZMeetConfig (FFmpeg fields removed)
                   ├─ MeetingRecorder     — protocol the app implements; lets Core stay testable
                   ├─ MarkdownRenderer, GitRepository, ConfigStore, ProcessRunner, Utilities
                   └─ (unchanged otherwise)
```

### Boundaries

- **ZMeetCore knows nothing about ScreenCaptureKit.** It defines a `MeetingRecorder` protocol; the
  concrete `SCKAudioRecorder` lives in the app target, because capture is inseparable from app
  permissions and cannot be unit-tested headlessly. `swift test` continues to cover the engine.
- **The Xcode project lives in-repo** (e.g. `app/ZMeet.xcodeproj`), references the local package by
  path, and is signed with Developer ID + hardened runtime.
- **The `zmeet` executable target is removed** from `Package.swift`. (Re-addable later against the
  same Core if a debug CLI is ever wanted.)

## Components

### MeetingRecorder (protocol, in ZMeetCore)

```
protocol MeetingRecorder {
    func start(to url: URL, config: AudioConfig) throws
    func stop() throws            // finalizes and closes the audio file
    var levelPublisher: ... { get } // RMS level for the UI meter (optional/observed)
}
```

A mock implementation is used in ZMeetCore tests to drive `start → stop → process` without audio.

### SCKAudioRecorder (concrete, in the app)

Capture pipeline (Approach A):

```
SCStream (captureMicrophone = true)
   ├─ .audio buffers (system) ─┐
   └─ .microphone buffers ─────┤
                               ▼
   CMSampleBuffer → AVAudioPCMBuffer (per stream)
                               ▼
   AVAudioEngine:  sysPlayerNode ─┐
                   micPlayerNode ─┴─▶ mainMixerNode ─▶ tap / manual render
                               ▼
   AVAudioFile (AAC, .m4a, configurable sample rate + bitrate) at session.audioPath
```

- A live **RMS level** is read off the mixer tap and published for the menu-bar meter — cheap, and
  it's what tells the user audio is actually being captured.
- On stop: stop the stream, drain and close the `AVAudioFile`, then hand back to the controller.

### RecordingController (in the app)

- `start(title:)` → `SessionManager.start` (writes session JSON `status: .recording`, returns audio
  URL) → `SCKAudioRecorder.start(to:)`.
- `stop()` → `SCKAudioRecorder.stop()` → `SessionManager.stop()` (sets `endedAt`, `status:
  .recorded`) → if `autoProcessOnStop`, kick off `SessionManager.process()` in the background.
- Surfaces recorder/processing state to the UI.

### Menu-bar UI (MenuBarExtra)

Single monochrome template icon; red dot while recording. Dropdown:

```
IDLE                              RECORDING
┌────────────────────────────┐   ┌────────────────────────────┐
│ Title: [ Weekly Sync     ]  │   │ ● Recording      04:12      │
│ ⏺  Start Recording          │   │ ▁▃▅▇▅▃▁  (live level meter) │
│ ──────────────────────────  │   │ ──────────────────────────  │
│ Recent                      │   │ ⏹  Stop                     │
│  ✓ 05-26 Standup     →notes │   └────────────────────────────┘
│  ⟳ 05-25 1:1   (processing) │
│  ⚠ 05-24 Sync (failed)   ↻  │
│ ──────────────────────────  │
│ ⚙ Permissions · Settings    │
└────────────────────────────┘
```

- Recent list comes from `SessionManager.listSessions()` (last ~10); rows show status and reveal the
  note in Finder; failed rows offer Retry (re-runs `process`).
- Settings area shows Screen Recording + Microphone status with a Grant button, plus the notes-repo
  path and the `autoProcessOnStop` toggle.

## Data / state model changes (ZMeetCore)

**`MeetingSession`** — remove `recorderPID` and `ffmpegLogPath`; add `recorderLogPath: String?`
(app writes capture diagnostics there). Retain `id, title, sourceApp, startedAt, endedAt, status,
audioPath, transcriptPath, notePath, errorMessage`.

**`ZMeetConfig`** — remove `ffmpegPath` and `ffmpegAudioInput`; add:

```
audio: { captureSystemAudio: Bool = true,
         captureMicrophone:  Bool = true,
         sampleRate: Int = 48000,
         bitrate:    Int = 128000 }
autoProcessOnStop: Bool = true
```

Retain `notesRepoPath, appDataPath, transcriptionCommand, summaryCommand, gitAutoCommit`.

> Note: this is a breaking change to the on-disk config schema. Since the project is unreleased and
> uncommitted, we regenerate config via the app's first-run setup rather than writing a migration.

## Permissions flow

- On first record: request **Microphone** (`AVCaptureDevice.requestAccess(for: .audio)`) and check
  **Screen Recording** (`CGPreflightScreenCaptureAccess`; `CGRequestScreenCaptureAccess()` to prompt;
  enumerate `SCShareableContent` to confirm). If denied, show a panel deep-linking to
  System Settings → Privacy & Security. Recording is blocked with a clear message until both granted.
- `Info.plist`: `NSMicrophoneUsageDescription`, `LSUIElement = true`.
- Entitlements: hardened runtime with `com.apple.security.device.audio-input`. Signed Developer ID.

## Error handling

- **Capture start failure** (permission revoked, no shareable content): readable message in the menu;
  no dangling `recording` session left behind.
- **Mid-recording stream error:** stop cleanly, finalize whatever audio exists, mark `.recorded` so
  the file is never lost; record the error on the session.
- **Processing failure:** `status: .failed` + `errorMessage`; retryable from the recent list (uses
  the existing `process` recovery path).
- **Dangling-session recovery on launch:** in-process recording means a crash can leave a session in
  `recording`. On launch the app detects such a session: if the audio file exists and is non-empty,
  offer to finalize as `.recorded`; if empty/zero-length, mark `.failed`. This replaces the old
  "is the PID alive?" check.

## Testing

- **ZMeetCore (`swift test`):** extend for the model/config changes; add a `SessionManager` test that
  injects a mock `MeetingRecorder` and exercises `start → stop → process` end-to-end without audio.
  Cover dangling-session recovery logic.
- **SCKAudioRecorder:** verified manually — record a short clip and confirm a playable `.m4a` with
  both system audio and microphone audible at reasonable levels. Capture cannot be unit-tested
  headlessly; the protocol boundary exists precisely so everything around it stays automated.
- **App:** manual smoke test of the permission flow (grant, deny, revoke-mid-recording) and the
  menu-bar states (idle / recording / processing / failed-retry).

## Out of scope (future phases)

- Whisper/Parakeet bundling and model profiles (Phase 2).
- Meeting auto-detection (Phase 4), search/MCP (Phase 5), remote access (Phase 6).
- Global hotkey and hide-icon-when-idle (revisit only if the menu bar feels tight).
- Separate per-speaker audio tracks / speaker diarization.
