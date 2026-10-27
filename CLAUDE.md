# CLAUDE.md

macOS menu-bar meeting recorder: records system audio + mic, transcribes and
summarizes on-device, one folder per meeting under ~/Documents/zMeet.

## Build & test
- `swift test` — ZMeetCore unit tests (Swift Testing). The app layer (ZMeetApp)
  is an executable target with NO tests — verify app changes by build.
- `swift build -c release --product ZMeetApp` — the app binary.
- `scripts/build-app.sh` compiles the app icon from assets/app-icon/zMeet.icon
  (Icon Composer) with Xcode's actool — edit the .icon, never a flat .icns.
- Sparkle "XCFramework Info.plist not found" error on any build:
  `rm -rf .build && swift build` (stale artifact cache after a repo move).
- CI (.github/workflows/ci.yml) runs tests + a release build on every PR
  (macos-26 runner; the package floor is macOS 26).

## Architecture (the one rule)
ZMeetCore = engine: no UI/AV imports, unit-tested, defines protocols
(MeetingRecorder etc.). ZMeetApp implements them with macOS frameworks
(ScreenCaptureKit, SpeechAnalyzer, FoundationModels). Never import
AppKit/AVFoundation into ZMeetCore. Sources/CWebRTCAPM is vendored WebRTC
APM 2.1 + Abseil (see THIRD-PARTY-NOTICES.md): regenerate with
scripts/vendor-webrtc-apm.sh, never hand-edit; only Sources/CWebRTCAPM/zmeet/
and include/zm_apm.h are ours.

## Versioning & release
- The version lives ONLY in scripts/build-app.sh (VERSION/BUILD,
  env-overridable defaults). release.sh asserts its argument matches and
  refuses otherwise; it runs the tests before building and auto-tags on a
  clean tree. Full procedure: docs/RELEASING.md.
- The installer DMG is always built by scripts/make-dmg.sh with create-dmg
  (brew install create-dmg) and a background from render-dmg-background.swift;
  release.sh calls it — no extra step per release.

## Repo conventions
- Layout: assets/ holds all art (app-icon/, brand/, menubar/, fonts/; each
  generated image has its source/ beside it and a scripts/make-*.py generator);
  scripts/ holds scripts only.
- Commits: single short imperative summary line.
- docs/ is gitignored EXCEPT docs/RELEASING.md (local planning notes stay
  local). plans/ (untracked) holds advisor audit plans + statuses — read
  plans/README.md before improvement work; update statuses there.
- Runtime state: ~/.zmeet (config.json, sessions/, logs/, search.db);
  meetings in the configured output folder.

## Sharp edges
- SCKAudioRecorder: all mutable state is confined to its capture queue;
  stop() cancels/awaits startTask first. Don't add cross-thread access.
- Echo cancellation: AEC3 needs strictly paired 10 ms render/capture calls —
  all EchoCapture/EchoAligner calls (including the 10 ms poll timer) happen on
  SCKAudioRecorder's capture queue. Mix alignment comes from each player's
  observed queue depth (PlaybackQueueController): system target 300 ms, mic
  target 300 ms − the released frame's age − AEC3's 430-sample latency;
  silence only ever goes to the players, never into mic.m4a/system.m4a.
  stop() cancels the poll, flushes the aligner and drains both players
  (100 ms marker) before removing the tap. Tune on real audio with
  `defaults write edu.umontana.zmeet ZMeetEchoDebugTracks -bool YES` (writes
  echo-debug/ tracks) and `aec-probe`.
- AppState.Phase has NO .processing case — processing lives in
  ProcessingRegistry (Core); recording and processing can overlap.
- Meeting detection: the banner is a one-shot nudge; DetectedMeetingTracker
  (Core) is the live-meeting truth behind the menu's Record row and badge.
  Polling cadence rules live in DetectorCadence — keep the latency-budget
  test (callIsConfirmedWithinLatencyBudgetFromIdleCadence) passing.
- Menu bar: an AppKit NSStatusItem (StatusItemController), not SwiftUI
  MenuBarExtra — MenuBarExtra can't tell right-click. The popover content
  (MenuContentView) closes itself via the closeMenuBarPopover environment
  action. The App's empty Settings scene exists only to keep the default main
  menu (Edit ⌘C/⌘V); keep its .appSettings replacement.
- AI providers: one selected AIProvider (Core) drives summaries, auto-titles,
  and entity links. Non-Apple output goes through SummarizationPolicy (clean →
  anchor check → one retry → on-device fallback with an honest footer).
  Cloud models extract facts then write (FactFirstSummarizer); on-device and
  Ollama map-reduce fact lists (MapReduceSummarizer), and on-device falls back
  to compact four-section notes (StructuredNotesSummarizer). Anthropic replies
  stream (AnthropicStream) — current models think by default and thinking
  counts toward max_tokens. Every provider request goes through
  AIHTTP.session (redirect-refusing) — never a new URLSession; the dev-only
  notes-probe keeps its own copy. Request-building/parsing stays in Core;
  ZMeetApp only sends.
- Notes prompts (MeetingSummaryPrompt) are tuned with `notes-probe <transcript>
  --provider anthropic|ondevice [--no-fallback]` on a copy of a real transcript;
  it never writes into the meetings folder. Transcripts have no speaker labels,
  so attribution rules are deliberately strict.
- The notes.md format is written by MarkdownRenderer and parsed in several
  places (Library reader, search indexing, Obsidian backfill) — template
  changes break all three differently. A valid note starts with `## Summary`
  and has `## Decisions` + `## Action Items` + one more section
  (SummaryOutput.hasRequiredSections); old four-section notes still pass.
  Pipe tables parse to NoteElement.table (ragged ones stay paragraphs).
  SummaryOutput.clean renames a model-written `## Transcript` heading, since
  every parser stops there.
- Colors: use ZMeetPalette (Sources/ZMeetApp/ZMeetPalette.swift) — add members
  there, never new one-off hex literals. Known drifted residuals awaiting a
  visual pass: SettingsView.sidebarBG/hairline, ModeChoicePopup.bg/card.
