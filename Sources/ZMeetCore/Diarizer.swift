import Foundation

/// One transcribed chunk with its start offset (seconds) in the source audio.
public struct TranscriptSegment: Sendable, Equatable {
    public var text: String
    public var start: TimeInterval
    public init(text: String, start: TimeInterval) {
        self.text = text
        self.start = start
    }
}

/// Merges per-side transcript segments ("You" = mic, "Others" = system) into one
/// chronological, speaker-labeled Markdown transcript. Pure and Sendable.
public struct Diarizer: Sendable {
    public init() {}

    public func merge(you: [TranscriptSegment], others: [TranscriptSegment]) -> String {
        struct Tagged { let speaker: String; let start: TimeInterval; let text: String }
        // Swift's sort isn't guaranteed stable, so tie-break on a stable index
        // for equal starts. You-segments enumerate first, so equal starts keep
        // You before Others deterministically.
        let tagged = (you.map { Tagged(speaker: "You", start: $0.start, text: $0.text) }
                      + others.map { Tagged(speaker: "Others", start: $0.start, text: $0.text) })
            .enumerated()
            .sorted { ($0.element.start, $0.offset) < ($1.element.start, $1.offset) }
            .map(\.element)

        var blocks: [(speaker: String, text: String)] = []
        for t in tagged {
            let text = t.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if blocks.last?.speaker == t.speaker {
                blocks[blocks.count - 1].text += " " + text
            } else {
                blocks.append((t.speaker, text))
            }
        }
        return blocks.map { "**\($0.speaker):** \($0.text)" }.joined(separator: "\n\n")
    }
}
