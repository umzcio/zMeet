# CLAUDE.md

macOS menu-bar meeting recorder: records system audio + mic, transcribes and
summarizes on-device, one folder per meeting under ~/Documents/zMeet.

## Build & test
- `swift test` — ZMeetCore unit tests (Swift Testing). The app layer (ZMeetApp)
  is an executable target with NO tests — verify app changes by build.
- `swift build -c release --product ZMeetApp` — the app binary.
- Sparkle "XCFramework Info.plist not found" error on any build:
  `rm -rf .build && swift build` (stale artifact cache after a repo move).
- CI (.github/workflows/ci.yml) runs tests + a release build on every PR
  (macos-26 runner; the package floor is macOS 26).

## Architecture (the one rule)
ZMeetCore = engine: no UI/AV imports, unit-tested, defines protocols
(MeetingRecorder etc.). ZMeetApp implements them with macOS frameworks
(ScreenCaptureKit, SpeechAnalyzer, FoundationModels). Never import
AppKit/AVFoundation into ZMeetCore. Sources/CSpeexDSP is vendored C
(BSD-3; see THIRD-PARTY-NOTICES.md) — don't edit it.

## Versioning & release
- The version lives ONLY in scripts/build-app.sh (VERSION/BUILD,
  env-overridable defaults). release.sh asserts its argument matches and
  refuses otherwise; it runs the tests before building and auto-tags on a
  clean tree. Full procedure: docs/RELEASING.md.

## Repo conventions
- Commits: single short imperative summary line.
- docs/ is gitignored EXCEPT docs/RELEASING.md (local planning notes stay
  local). plans/ (untracked) holds advisor audit plans + statuses — read
  plans/README.md before improvement work; update statuses there.
- Runtime state: ~/.zmeet (config.json, sessions/, logs/, search.db);
  meetings in the configured output folder.

## Sharp edges
- SCKAudioRecorder: all mutable state is confined to its capture queue;
  stop() cancels/awaits startTask first. Don't add cross-thread access.
- AppState.Phase has NO .processing case — processing is
  processingSessionID/isProcessing; recording and processing can overlap.
- The notes.md format is written by MarkdownRenderer and parsed in several
  places (Library reader, search indexing, Obsidian backfill) — template
  changes break all three differently.
- Colors: use ZMeetPalette (Sources/ZMeetApp/ZMeetPalette.swift) — add members
  there, never new one-off hex literals. Known drifted residuals awaiting a
  visual pass: SettingsView.sidebarBG/hairline, ModeChoicePopup.bg/card.
