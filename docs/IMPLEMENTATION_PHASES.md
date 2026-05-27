# zMeet Implementation Phases

Status: ✅ done · 🔜 next · ⬜ planned

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

## 🔜 Phase 4 — Meeting detection + "Take notes" popup

- Detect Zoom / Teams native apps and browser-based Google Meet.
- Zoom-style notification offering to start recording when a meeting is detected.
- User confirmation before auto-recording; per-app auto-start settings.

## ⬜ Phase 5 — Library & Reader window

The actual app window you open to work with past meetings (today the menu bar only
reveals files in Finder).

- List/browse all meetings from `~/Documents/zMeet`.
- Read the rendered `notes.md` and `transcript.md` in-app.
- Play back the `recording.m4a`.
- Rename / delete / reveal-in-Finder a meeting.
- (Search lives in Phase 7.)

## ⬜ Phase 6 — Settings window

A proper preferences UI replacing hand-editing `~/.zmeet/config.json`.

- Output folder location.
- Audio options (system/mic capture, sample rate, bitrate).
- Processing: local (default) vs. cloud toggle; auto-process-on-stop.
- Transcription/summary provider + model choices.
- Permission status + shortcuts to grant.

## ⬜ Phase 7 — Search

- Disposable local index over the markdown (SQLite FTS first, embeddings later).
- Optional: expose read-only MCP tools over the notes folder.

## ⬜ Backlog / deferred

- **Noise suppression (take 2).** First attempt (AVAudioEngine voice-processing
  input) broke the recorder with `-10875` and was reverted; retry with a safer
  approach (e.g. offline noise-reduction pass, or an isolated VPIO mic graph),
  tested before committing.
- **Cloud processing (opt-in).** Claude API summary (transcript text only) and/or
  cloud transcription, behind the Settings toggle.
- **Private remote access.** Read-only remote endpoint behind a Cloudflare tunnel
  + strong auth, sourced from the local index.
- **Live level meter** in the recording UI.
- **Speaker diarization** (who said what).
