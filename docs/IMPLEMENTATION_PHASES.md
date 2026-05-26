# zMeet Implementation Phases

## Phase 1: Manual Capture Core

Goal: prove the durable local workflow.

- Manual start/stop recording.
- Local audio file saved under `~/.zmeet/audio`.
- Configurable transcription command.
- Configurable summary command.
- Markdown note and transcript written to a Git repo.
- Optional Git commit after processing.

## Phase 2: Better Local Processing

- Bundle or discover Whisper/Parakeet runners.
- Add model profiles.
- Add speaker/timestamp cleanup.
- Improve note templates.
- Add retryable processing jobs.

## Phase 3: Menu Bar App

- SwiftUI menu bar wrapper around the core.
- Active recording status.
- Start/stop controls.
- Permission checks.
- Recent meetings list.

## Phase 4: Meeting Detection

- Zoom and Teams native app detection.
- Browser-based Google Meet detection.
- User confirmation prompt before auto-recording.
- Per-app auto-start settings.

## Phase 5: Search and MCP

- Build a disposable local index from Markdown.
- Add SQLite FTS first.
- Add embeddings later.
- Expose read-only MCP tools over the notes repo.

## Phase 6: Private Remote Access

- Keep local MCP as the source.
- Add a read-only remote MCP endpoint.
- Put access behind Cloudflare tunnel and strong auth.
