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

}
