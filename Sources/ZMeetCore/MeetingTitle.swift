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

    /// Generic titles the meeting apps put in their window names, or our own
    /// placeholder. A meeting with one of these gets an AI-written title after
    /// processing; any real subject or user-typed title is kept.
    private static let genericTitles: Set<String> = [
        "untitled meeting", "zoom", "zoom meeting", "zoom webinar",
        "teams meeting", "microsoft teams", "microsoft teams meeting",
    ]
    private static let teamsWindowSuffix = " | microsoft teams"

    /// Whether `title` carries no real information about the meeting: blank, our
    /// "Untitled Meeting", an app's generic window title ("Zoom Meeting", "Microsoft
    /// Teams Meeting"), a Zoom personal room ("Pat's Zoom Meeting"), or a Teams
    /// ad-hoc call window ("Meeting with Doe, Jane | Microsoft Teams"). Case-insensitive.
    public static func isPlaceholder(_ title: String) -> Bool {
        var t = title.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        if t.isEmpty || genericTitles.contains(t) { return true }
        if t.hasSuffix("'s zoom meeting") || t.hasSuffix("'s personal meeting room") { return true }
        guard t.hasSuffix(teamsWindowSuffix) else { return false }
        t.removeLast(teamsWindowSuffix.count)
        return genericTitles.contains(t) || t.hasPrefix("meeting with ")
    }
}
