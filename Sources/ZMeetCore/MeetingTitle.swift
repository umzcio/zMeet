import Foundation

/// Cleans a model-generated meeting title into a safe, single-line title.
public enum MeetingTitle {
    /// Strips a leading "Title:" label, surrounding quotes / markdown / list markers,
    /// keeps only the first line, collapses internal whitespace, and clips length.
    /// Returns nil if nothing usable remains.
    public static func clean(_ raw: String) -> String? {
        var t = raw.split(whereSeparator: { $0.isNewline }).first.map(String.init) ?? ""
        if let label = t.range(of: "^\\s*title\\s*:\\s*", options: [.regularExpression, .caseInsensitive]) {
            t.removeSubrange(label)
        }
        // Trim surrounding quotes, markdown emphasis, and list markers from both ends.
        t = t.trimmingCharacters(in: CharacterSet(charactersIn: " \t\"'`*#-•"))
        t = t.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard !t.isEmpty else { return nil }
        return String(t.prefix(80))
    }
}
