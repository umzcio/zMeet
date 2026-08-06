import Foundation

public enum ZMeetPaths {
    public static func expandTilde(_ path: String, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String {
        guard path == "~" || path.hasPrefix("~/") else {
            return path
        }

        if path == "~" {
            return home.path
        }

        return home.appendingPathComponent(String(path.dropFirst(2))).path
    }

    public static func ensureDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    /// Creates the directory (if needed) and restricts it to the current user.
    /// zMeet's data dirs hold meeting audio/transcripts — never world-readable.
    public static func ensurePrivateDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        // createDirectory attributes only apply on creation; enforce on the leaf
        // for pre-existing dirs.
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    /// Owner-only permissions on an existing file (0600). Best-effort.
    public static func restrictFile(_ url: URL) {
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public static func relativePath(fromDirectory baseDirectory: URL, to target: URL) -> String {
        let baseComponents = baseDirectory.standardizedFileURL.pathComponents
        let targetComponents = target.standardizedFileURL.pathComponents

        var sharedCount = 0
        while sharedCount < baseComponents.count,
              sharedCount < targetComponents.count,
              baseComponents[sharedCount] == targetComponents[sharedCount] {
            sharedCount += 1
        }

        let upCount = baseComponents.count - sharedCount
        let upComponents = Array(repeating: "..", count: upCount)
        let downComponents = Array(targetComponents.dropFirst(sharedCount))
        let components = upComponents + downComponents

        return components.isEmpty ? "." : components.joined(separator: "/")
    }
}

public enum ZMeetText {
    public static func slugify(_ input: String) -> String {
        let lowercased = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var output = ""
        var previousWasDash = false

        for scalar in lowercased.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                output.unicodeScalars.append(scalar)
                previousWasDash = false
            } else if !previousWasDash {
                output.append("-")
                previousWasDash = true
            }
        }

        let trimmed = output.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "untitled-meeting" : trimmed
    }

    /// Sanitizes a meeting title for use as a folder or file name: strips path
    /// separators, control characters, and other characters that are awkward
    /// on disk, collapses whitespace, clamps to `maxBytes` of UTF-8 (so a long
    /// title can't push a folder/file name past filesystem component limits),
    /// and falls back to a default when empty.
    public static func sanitizeFileName(_ input: String, maxBytes: Int = 120) -> String {
        let illegal = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters)
        let cleaned = input
            .components(separatedBy: illegal)
            .joined(separator: "-")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: " .-"))
        let capped = clampUTF8(cleaned, maxBytes: maxBytes)
        return capped.isEmpty ? "Untitled Meeting" : capped
    }

    /// Truncates to at most `maxBytes` of UTF-8 without splitting a character,
    /// then re-trims trailing space/dot/dash left by the cut.
    static func clampUTF8(_ s: String, maxBytes: Int) -> String {
        guard s.utf8.count > maxBytes else { return s }
        var result = ""
        for ch in s {
            if (result.utf8.count + String(ch).utf8.count) > maxBytes { break }
            result.append(ch)
        }
        return result.trimmingCharacters(in: CharacterSet(charactersIn: " .-"))
    }

    /// Normalizes a human-entered or window-derived meeting title for storage:
    /// strips control characters (incl. newlines — YAML/heading safety), collapses
    /// whitespace runs, trims. Returns "" if nothing remains (callers substitute
    /// their placeholder).
    public static func sanitizeTitle(_ raw: String) -> String {
        // Replace (not delete) control characters with a space so an interior
        // newline/tab/CR becomes a word break rather than fusing the two
        // neighboring words together; the whitespace-run collapse below then
        // normalizes runs of these (and any pre-existing) spaces to one.
        let spaced = raw.unicodeScalars.map {
            CharacterSet.controlCharacters.contains($0) ? Unicode.Scalar(" ") : $0
        }
        return String(String.UnicodeScalarView(spaced))
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    public static func yamlQuote(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
        return "\"\(escaped)\""
    }

    /// Extracts the searchable prose from a rendered `notes.md`: drops the YAML
    /// frontmatter, Markdown heading lines (which repeat the title), and the
    /// trailing transcript-link section, leaving the summary body. Keeps the
    /// search index free of title/path/frontmatter noise.
    public static func noteSearchBody(_ markdown: String) -> String {
        var lines = markdown.components(separatedBy: "\n")

        // Drop a leading YAML frontmatter block (--- ... ---).
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---",
           let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) {
            lines = Array(lines[(end + 1)...])
        }

        var body: [String] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.lowercased() == "## transcript" { break }  // tab/section covers it
            if trimmed.hasPrefix("#") { continue }            // headings repeat the title
            body.append(line)
        }
        return body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

}

/// Guards the offline noise-cleanup pass from replacing a recording with a
/// truncated render. A cleaned render may only swap in for the original when
/// the render loop consumed the entire source and the encoded output length
/// is within tolerance of the source length.
public enum AudioCleanupPolicy {
    /// A cleaned render may replace the original only when the render loop
    /// consumed the whole source and the output length is within `tolerance`
    /// frames of the source length.
    public static func mayReplaceOriginal(
        sourceFrames: Int64, renderedFrames: Int64,
        loopCompleted: Bool, toleranceFrames: Int64
    ) -> Bool {
        loopCompleted && renderedFrames >= sourceFrames - toleranceFrames
    }
}

public enum ZMeetDates {
    public static func iso8601(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    public static func fileStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter.string(from: date)
    }

    /// Human-friendly stamp for per-meeting folder names, e.g. "2026-05-26 1755".
    public static func folderStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HHmm"
        return formatter.string(from: date)
    }

    public static func year(_ date: Date) -> String {
        component("yyyy", from: date)
    }

    public static func month(_ date: Date) -> String {
        component("MM", from: date)
    }

    public static func displayDate(_ date: Date) -> String {
        component("yyyy-MM-dd", from: date)
    }

    private static func component(_ format: String, from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        return formatter.string(from: date)
    }
}
