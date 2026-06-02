import Foundation

public struct MarkdownRenderer {
    public init() {}

    /// Renders a note whose body is an already-structured summary (e.g. from an
    /// on-device LLM), rather than the fixed empty-section template. Frontmatter
    /// plus the summary markdown plus a transcript link.
    public func renderProcessedNote(
        session: MeetingSession,
        transcriptURL: URL,
        noteURL: URL,
        summaryMarkdown: String,
        summaryEngine: SummaryEngine = .onDevice
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

        _\(summaryEngine.attribution)_
        """
    }

    /// Extracts just the summary body from a note produced by `renderProcessedNote`:
    /// drops the YAML frontmatter, the leading "# Title" heading, and everything from
    /// the "## Transcript" section onward (the transcript link + engine attribution).
    /// Lets the Obsidian backfill reuse a meeting's existing summary without
    /// re-summarizing. Defensive: tolerates a missing frontmatter or transcript section.
    public func summaryBody(fromProcessedNote note: String) -> String {
        var lines = note.components(separatedBy: "\n")
        // Strip a leading YAML frontmatter block ("---" … "---").
        if lines.first == "---", let close = lines.dropFirst().firstIndex(of: "---") {
            lines.removeSubrange(0...close)
        }
        // Cut from the Transcript section onward.
        if let transcript = lines.firstIndex(where: { $0.hasPrefix("## Transcript") }) {
            lines.removeSubrange(transcript...)
        }
        // Drop leading blank lines and the "# Title" heading.
        while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeFirst()
        }
        if let first = lines.first, first.hasPrefix("# ") {
            lines.removeFirst()
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

}
