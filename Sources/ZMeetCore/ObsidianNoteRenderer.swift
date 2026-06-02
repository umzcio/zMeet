import Foundation

/// Pure renderer for Obsidian vault notes: a main note (frontmatter + summary +
/// [[link]] sections + transcript link) and a companion transcript note.
public enum ObsidianNoteRenderer {
    public static func mainNote(session: MeetingSession, summary: String,
                                entities: MeetingEntities, transcriptNoteName: String) -> String {
        let date = ZMeetDates.displayDate(session.startedAt)
        let duration = session.endedAt.map { durationString($0.timeIntervalSince(session.startedAt)) } ?? ""
        let source = session.sourceApp ?? "Unknown"
        let mode = session.mode?.rawValue ?? ""

        var fm: [String] = ["---", "date: \(date)", "source: \(yaml(source))"]
        if !duration.isEmpty { fm.append("duration: \(yaml(duration))") }
        if !mode.isEmpty { fm.append("mode: \(yaml(mode))") }
        if !entities.people.isEmpty { fm.append("attendees: [\(entities.people.map(yaml).joined(separator: ", "))]") }
        fm.append("tags: [meeting]")
        fm.append("---")

        var body = [fm.joined(separator: "\n"), "", "# \(session.title)", "", summary.trimmingCharacters(in: .whitespacesAndNewlines)]
        func linkSection(_ heading: String, _ items: [String]) {
            guard !items.isEmpty else { return }
            body.append("")
            body.append("## \(heading)")
            body.append(items.map { "[[\(sanitizeLink($0))]]" }.joined(separator: " · "))
        }
        linkSection("People", entities.people)
        linkSection("Projects", entities.projects)
        linkSection("Topics", entities.topics)
        body.append("")
        body.append("## Transcript")
        body.append("[[\(transcriptNoteName)]]")
        return body.joined(separator: "\n") + "\n"
    }

    public static func transcriptNote(session: MeetingSession, transcript: String, mainNoteName: String) -> String {
        """
        ---
        date: \(ZMeetDates.displayDate(session.startedAt))
        type: transcript
        ---

        # \(session.title) — Transcript

        Meeting: [[\(mainNoteName)]]

        \(transcript.trimmingCharacters(in: .whitespacesAndNewlines))
        """ + "\n"
    }

    // Helpers
    private static func durationString(_ s: TimeInterval) -> String {
        let m = max(0, Int(s) / 60); return m >= 60 ? "\(m/60)h \(m%60)m" : "\(m)m"
    }
    private static func yaml(_ s: String) -> String { "\"\(s.replacingOccurrences(of: "\"", with: "'"))\"" }
    /// Strip characters that break a [[wikilink]].
    private static func sanitizeLink(_ s: String) -> String {
        s.components(separatedBy: CharacterSet(charactersIn: "[]|#^")).joined(separator: " ")
         .trimmingCharacters(in: .whitespaces)
    }
}
