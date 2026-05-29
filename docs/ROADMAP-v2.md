# zMeet v2.0 Roadmap

**Status:** Planning. v1.0 (the MVP) is complete — see `IMPLEMENTATION_PHASES.md`.

**v1.0 recap (shipped 2026-05-26):** a signed menu-bar app that detects Zoom/Teams
meetings, records system audio + microphone (mixed `.m4a`), transcribes and
summarizes fully on-device, and saves one folder per meeting under
`~/Documents/zMeet`. The core loop — *click → record → notes* — works.

## v2.0 theme

Turn the working MVP into a **daily-driver app**: make captured meetings
browsable, readable, and searchable *inside* the app; configurable through a real
UI; and higher quality. v1.0 proved the pipeline; v2.0 makes it pleasant to live in.

> Each phase below gets its own spec + implementation plan when we start it
> (brainstorm → spec → plan → build), the same way v1.0 phases were built. This
> document is the roadmap, not the task breakdown.

## Phase 5 — Library & Reader window (highest value)

The actual window you open to work with past meetings (today the menu bar only
reveals files in Finder).

- A real app window (brought up from the menu, e.g. "Open zMeet").
- List/browse all meetings from `~/Documents/zMeet`, newest first.
- Read the rendered `notes.md` and `transcript.md` in-app (formatted Markdown).
- Play back `recording.m4a` with basic transport (play/pause/scrub).
- Per-meeting actions: rename, delete, reveal in Finder, re-process.
- Sets up the app to have a Dock presence when the window is open (it's currently
  a pure menu-bar agent).

## Phase 6 — Settings window

A proper preferences UI replacing hand-editing `~/.zmeet/config.json`.

- Output folder location (with a folder picker).
- Audio options: capture system/mic toggles, sample rate, bitrate.
- Processing: local (default) vs. cloud toggle; auto-process-on-stop.
- Transcription/summary provider + model choices.
- Permissions status with one-click "grant" shortcuts.
- Meeting detection on/off and which apps.

## Phase 7 — Search

- A disposable local index over the meeting Markdown (SQLite FTS first;
  embeddings/semantic search later).
- Search UI integrated into the Library window.
- Optional: expose read-only MCP tools over the notes folder so other tools
  (and Claude) can query your meetings.

## Beyond v2.0 (backlog — pull in when wanted)

- **Noise suppression, take 2.** The v1 attempt (AVAudioEngine voice-processing
  input) broke the recorder with `-10875` and was reverted. Retry with a safer
  approach — an offline noise-reduction pass on the captured file, or an isolated
  voice-processing graph for the mic only — tested before committing.
- **Cloud processing (opt-in).** Behind the Settings toggle: send only the text
  transcript to the Claude API for higher-quality summaries (audio stays local),
  and/or a cloud transcription option. Needs API-key handling.
- **Private remote access.** A read-only remote endpoint (behind a Cloudflare
  tunnel + strong auth) sourced from the local index, to reach your notes away
  from your Mac.
- **In-person / hybrid recording mode.** A meeting-type switch so capture adapts:
  *Remote* (current default — system audio + mic, lean toward a clean voice signal)
  vs. *In-person/Hybrid* (emphasize the room — capture ambient mic without noise
  suppression, possibly higher mic gain/sensitivity, and make system audio optional
  since an in-person meeting has no remote stream). Open question: the built-in mic
  may not capture a full room well; explore input-device selection (external/USB mic)
  and gain. Pairs with the noise-suppression item (suppression helps remote, hurts
  in-person). Surface the toggle in Settings and/or the start-recording control.
- **Live level meter** in the recording UI (confidence that audio is flowing).
- **Speaker diarization** (who said what) in transcripts.
- **Pre-publish scrub** before open-sourcing: rewrite git history to a neutral
  author email, auto-detect the signing identity, and remove `/Users/<name>` paths
  and the `edu.umontana.*` identifiers. (Tracked separately; do as one pass right
  before the first public push.)

## Suggested order

5 → 6 → 7, with backlog items slotted in as desired. Phase 5 delivers the most
visible value (you stop bouncing to Finder); Phase 6 unlocks the cloud toggle and
removes config-file editing; Phase 7 builds naturally on the Library window.
