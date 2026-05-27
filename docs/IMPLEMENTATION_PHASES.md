# zMeet Implementation Phases — v1.0 (shipped)

**v1.0 is complete (2026-05-26): the MVP works end to end** — detect a
Zoom/Teams meeting → record system audio + mic → on-device transcription +
summary → per-meeting folder under `~/Documents/zMeet`.

Everything below shipped in v1.0. Future work (Library window, Settings, Search,
and backlog) lives in **`ROADMAP-v2.md`**.

Status: ✅ done

## ✅ Phase 1 — Manual capture core (ZMeetCore engine)

- Session lifecycle (start/stop/process/recover), markdown note + transcript rendering, config.
- Recorder is an injected `MeetingRecorder` protocol; the `zmeet` CLI was retired.
- See `docs/superpowers/specs/2026-05-26-native-recorder-design.md` and
  `docs/superpowers/plans/2026-05-26-zmeetcore-recorder-refactor.md` (Plan A).

## ✅ Phase 3 (pulled forward) — Menu-bar app + native recorder

- Signed `zMeet.app` (SwiftUI `MenuBarExtra`, Developer ID, `scripts/build-app.sh`).
- Start/stop, status, recent list, permission flow, crash recovery on launch.
- Native recorder: system audio (ScreenCaptureKit) + microphone, mixed → AAC `.m4a`.
- Output consolidated into one folder per meeting under `~/Documents/zMeet`
  (`recording.m4a`, `transcript.md`, `notes.md`).
- Plan B: `docs/superpowers/plans/2026-05-26-zmeet-app-plan-b.md`.

## ✅ Phase 2 — On-device transcription + summary

- Transcription via macOS 26 `SpeechTranscriber`/`SpeechAnalyzer` → real `transcript.md`.
- Summary via Apple Foundation Models (on-device LLM) → real `notes.md`
  (Summary / Key Points / Action Items / Decisions), with extractive fallback.
- Local-only today; cloud is a future opt-in (below).

## ✅ Phase 4 — Meeting detection + "Take notes" popup

- Detects Zoom / Teams meeting windows (via the Screen Recording permission).
- Floating, non-activating "meeting detected" panel offering to record
  (with a close button + 15s auto-dismiss); always-confirm, no auto-record.

---

## What's next → v2.0

v1.0 is done. The Library/Reader window, Settings UI, Search, and the rest of the
backlog are planned for **v2.0 — see `ROADMAP-v2.md`**.
