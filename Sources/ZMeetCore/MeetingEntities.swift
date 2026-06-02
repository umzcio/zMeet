import Foundation

public struct MeetingEntities: Sendable, Equatable {
    public var people: [String]
    public var projects: [String]
    public var topics: [String]
    public init(people: [String] = [], projects: [String] = [], topics: [String] = []) {
        self.people = people; self.projects = projects; self.topics = topics
    }
    public var isEmpty: Bool { people.isEmpty && projects.isEmpty && topics.isEmpty }
}

/// Parses the model's labeled extraction output (PEOPLE:/PROJECTS:/TOPICS: lines)
/// into entities. Tolerant of surrounding prose, missing lines, "none", blanks,
/// and case-insensitive duplicates.
public enum EntityParser {
    public static func parse(_ text: String) -> MeetingEntities {
        var people: [String] = [], projects: [String] = [], topics: [String] = []
        for rawLine in text.split(whereSeparator: { $0.isNewline }) {
            let line = String(rawLine)
            guard let colon = line.firstIndex(of: ":") else { continue }
            let label = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let values = line[line.index(after: colon)...]
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && $0.lowercased() != "none" }
            let deduped = values.reduce(into: [String]()) { acc, v in
                if !acc.contains(where: { $0.caseInsensitiveCompare(v) == .orderedSame }) { acc.append(v) }
            }
            switch label {
            case "people", "attendees", "participants": people = deduped
            case "projects", "project": projects = deduped
            case "topics", "topic": topics = deduped
            default: break
            }
        }
        return MeetingEntities(people: people, projects: projects, topics: topics)
    }
}
