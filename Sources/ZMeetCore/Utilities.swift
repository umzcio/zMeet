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
    /// separators and other characters that are awkward on disk, collapses
    /// whitespace, and falls back to a default when empty.
    public static func sanitizeFileName(_ input: String) -> String {
        let illegal = CharacterSet(charactersIn: "/\\:*?\"<>|")
        let cleaned = input
            .components(separatedBy: illegal)
            .joined(separator: "-")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: " .-"))
        return cleaned.isEmpty ? "Untitled Meeting" : cleaned
    }

    public static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    public static func yamlQuote(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
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
            if trimmed.hasPrefix("#") { continue }            // headings repeat the title
            if trimmed.lowercased() == "## transcript" { break }  // tab/section covers it
            body.append(line)
        }
        return body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func expandCommandTemplate(_ template: String, values: [String: String]) -> String {
        var command = template
        for (key, value) in values {
            command = command.replacingOccurrences(of: "{\(key)}", with: shellQuote(value))
        }
        return command
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
