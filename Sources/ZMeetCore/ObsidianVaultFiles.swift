import Foundation

/// Stable, Obsidian-safe filenames for a meeting's vault notes, and atomic writes.
public enum ObsidianVaultFiles {
    public static func baseName(for session: MeetingSession) -> String {
        // Date + time (yyyy-MM-dd HHmm), matching the meeting folder convention, so
        // two different meetings on the same day with the same title (e.g. recurring
        // "Standup", or two blank-titled "Untitled Meeting"s) don't collide and
        // overwrite each other's notes in the vault.
        let stamp = ZMeetDates.folderStamp(session.startedAt)
        let safeTitle = sanitizeFilename(session.title.isEmpty ? "Untitled Meeting" : session.title)
        return "\(stamp) \(safeTitle)"
    }
    /// The pre-1.12.1 base name (date-only, no time component). Used once on upgrade
    /// to remove a note published under the old scheme before republishing under the
    /// new date+time scheme, so the vault doesn't keep an orphaned duplicate.
    public static func legacyBaseName(for session: MeetingSession) -> String {
        let date = ZMeetDates.displayDate(session.startedAt)
        let safeTitle = sanitizeFilename(session.title.isEmpty ? "Untitled Meeting" : session.title)
        return "\(date) \(safeTitle)"
    }
    public static func names(for session: MeetingSession) -> (main: String, transcript: String, mainNoteName: String, transcriptNoteName: String) {
        let base = baseName(for: session)
        return ("\(base).md", "\(base) — Transcript.md", base, "\(base) — Transcript")
    }
    public static func write(main: String, transcript: String, mainName: String, transcriptName: String, into vault: URL) throws {
        // Write the transcript first: the main note embeds a [[transcript]] wikilink,
        // so writing the link target first means a partial failure never leaves a
        // main note pointing at a transcript that doesn't exist yet.
        try transcript.write(to: vault.appendingPathComponent(transcriptName), atomically: true, encoding: .utf8)
        try main.write(to: vault.appendingPathComponent(mainName), atomically: true, encoding: .utf8)
    }
    /// Remove a previously-published pair (main note + companion transcript) for the
    /// given base name. Best-effort — used to clean up stale files when a meeting was
    /// renamed and republished under a new name. Missing files are ignored.
    public static func remove(baseName base: String, from vault: URL) {
        try? FileManager.default.removeItem(at: vault.appendingPathComponent("\(base).md"))
        try? FileManager.default.removeItem(at: vault.appendingPathComponent("\(base) — Transcript.md"))
    }
    /// Remove characters illegal in filenames / that confuse Obsidian, then collapse
    /// any runs of whitespace (sanitized chars can leave multiple spaces) to one.
    private static func sanitizeFilename(_ s: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:*?\"<>|#^[]")
        let cleaned = s.components(separatedBy: bad).joined(separator: " ")
        return cleaned.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}
