import Foundation

public struct MarkdownRenderer {
    public init() {}

    public func renderNote(
        session: MeetingSession,
        transcriptURL: URL,
        noteURL: URL,
        summaryMarkdown: String
    ) -> String {
        let noteDirectory = noteURL.deletingLastPathComponent()
        let transcriptRelativePath = ZMeetPaths.relativePath(fromDirectory: noteDirectory, to: transcriptURL)
        let sourceApp = session.sourceApp ?? "unknown"
        let endedAt = session.endedAt.map(ZMeetDates.iso8601) ?? ""
        let durationSeconds = session.endedAt.map { Int($0.timeIntervalSince(session.startedAt)) }

        var frontmatter: [String] = [
            "---",
            "id: \(ZMeetText.yamlQuote(session.id))",
            "title: \(ZMeetText.yamlQuote(session.title))",
            "started_at: \(ZMeetText.yamlQuote(ZMeetDates.iso8601(session.startedAt)))",
            "ended_at: \(ZMeetText.yamlQuote(endedAt))",
            "source_app: \(ZMeetText.yamlQuote(sourceApp))",
            "status: \(ZMeetText.yamlQuote(session.status.rawValue))",
            "audio_path: \(ZMeetText.yamlQuote(session.audioPath))",
            "transcript: \(ZMeetText.yamlQuote(transcriptRelativePath))"
        ]

        if let durationSeconds {
            frontmatter.append("duration_seconds: \(durationSeconds)")
        }

        frontmatter.append("---")

        return """
        \(frontmatter.joined(separator: "\n"))

        # \(session.title)

        ## Summary

        \(summaryMarkdown.trimmingCharacters(in: .whitespacesAndNewlines))

        ## Decisions

        - 

        ## Follow-ups

        - 

        ## Open Questions

        - 

        ## Notes

        - 

        ## Transcript

        [Open transcript](\(transcriptRelativePath))
        """
    }

    /// Renders a note whose body is an already-structured summary (e.g. from an
    /// on-device LLM), rather than the fixed empty-section template. Frontmatter
    /// plus the summary markdown plus a transcript link.
    public func renderProcessedNote(
        session: MeetingSession,
        transcriptURL: URL,
        noteURL: URL,
        summaryMarkdown: String
    ) -> String {
        let noteDirectory = noteURL.deletingLastPathComponent()
        let transcriptRelativePath = ZMeetPaths.relativePath(fromDirectory: noteDirectory, to: transcriptURL)
        let sourceApp = session.sourceApp ?? "unknown"
        let endedAt = session.endedAt.map(ZMeetDates.iso8601) ?? ""
        let durationSeconds = session.endedAt.map { Int($0.timeIntervalSince(session.startedAt)) }

        var frontmatter: [String] = [
            "---",
            "id: \(ZMeetText.yamlQuote(session.id))",
            "title: \(ZMeetText.yamlQuote(session.title))",
            "started_at: \(ZMeetText.yamlQuote(ZMeetDates.iso8601(session.startedAt)))",
            "ended_at: \(ZMeetText.yamlQuote(endedAt))",
            "source_app: \(ZMeetText.yamlQuote(sourceApp))",
            "status: \(ZMeetText.yamlQuote(session.status.rawValue))",
            "audio_path: \(ZMeetText.yamlQuote(session.audioPath))",
            "transcript: \(ZMeetText.yamlQuote(transcriptRelativePath))"
        ]
        if let durationSeconds {
            frontmatter.append("duration_seconds: \(durationSeconds)")
        }
        frontmatter.append("---")

        return """
        \(frontmatter.joined(separator: "\n"))

        # \(session.title)

        \(summaryMarkdown.trimmingCharacters(in: .whitespacesAndNewlines))

        ## Transcript

        [Open transcript](\(transcriptRelativePath))
        """
    }

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

    public func renderDefaultSummary(session: MeetingSession, transcriptMarkdown: String) -> String {
        if transcriptMarkdown.contains("Transcript generation is not configured yet.") {
            return """
            Summary generation is waiting on transcription.

            Phase 1 has captured the session artifact and created the Markdown note. Configure transcription and summary commands to fill this section automatically.
            """
        }

        let cleaned = transcriptMarkdown
            .split(separator: "\n")
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .prefix(12)
            .joined(separator: "\n")

        return cleaned.isEmpty
            ? "No transcript content was available for summary generation."
            : "Draft summary from transcript excerpt:\n\n\(cleaned)"
    }
}
