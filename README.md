# zMeet

zMeet is a local-first meeting capture tool. Phase 1 is intentionally small:

1. Start a manual meeting recording.
2. Stop the recording.
3. Generate transcript and note artifacts.
4. Write Markdown into a Git-backed notes repository.

Auto-detection, MCP, Cloudflare tunnel access, and polished menu bar UI come later.

## Current Shape

- Language: Swift 6
- Runtime target: macOS 14+
- Recorder: `ffmpeg` using the macOS `avfoundation` input
- Notes: Markdown files in a Git repository
- State: `~/.zmeet`

## Quick Start

```sh
cd /Users/zach/Documents/Github/zMeet
swift build
.build/debug/zmeet init --repo ~/Documents/Github/zMeetNotes
.build/debug/zmeet devices
.build/debug/zmeet start --title "Test Meeting" --app zoom
# talk for a few seconds
.build/debug/zmeet stop
.build/debug/zmeet process
```

By default, transcription and summarization are placeholders. Configure external commands when you are ready to wire in Whisper, Parakeet, Ollama, or cloud models.

## Command Templates

`transcriptionCommand` and `summaryCommand` support placeholders:

- `{id}`
- `{title}`
- `{audio}`
- `{transcript}`
- `{transcriptBase}`
- `{summary}`
- `{notesRepo}`

Examples:

```sh
zmeet config set transcriptionCommand 'whisper-cli -f {audio} -otxt -of {transcriptBase}'
zmeet config set summaryCommand 'cat {transcript} | ollama run llama3.2 > {summary}'
```

## Notes Output

The notes repository uses this layout:

```text
meetings/YYYY/MM/<session-id>.md
transcripts/YYYY/MM/<session-id>.transcript.md
```

Audio stays outside the notes repo by default under `~/.zmeet/audio`.
