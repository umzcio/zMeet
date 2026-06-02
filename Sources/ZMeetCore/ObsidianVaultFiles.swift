import Foundation

/// Stable, Obsidian-safe filenames for a meeting's vault notes, and atomic writes.
public enum ObsidianVaultFiles {
    public static func baseName(for session: MeetingSession) -> String {
        let date = ZMeetDates.displayDate(session.startedAt)
        let safeTitle = sanitizeFilename(session.title.isEmpty ? "Untitled Meeting" : session.title)
        return "\(date) \(safeTitle)"
    }
    public static func names(for session: MeetingSession) -> (main: String, transcript: String, mainNoteName: String, transcriptNoteName: String) {
        let base = baseName(for: session)
        return ("\(base).md", "\(base) — Transcript.md", base, "\(base) — Transcript")
    }
    public static func write(main: String, transcript: String, mainName: String, transcriptName: String, into vault: URL) throws {
        try main.write(to: vault.appendingPathComponent(mainName), atomically: true, encoding: .utf8)
        try transcript.write(to: vault.appendingPathComponent(transcriptName), atomically: true, encoding: .utf8)
    }
    /// Remove characters illegal in filenames / that confuse Obsidian.
    private static func sanitizeFilename(_ s: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:*?\"<>|#^[]")
        let cleaned = s.components(separatedBy: bad).joined(separator: " ")
        return cleaned.replacingOccurrences(of: "  ", with: " ").trimmingCharacters(in: .whitespaces)
    }
}
