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
        let tagged = (you.map { Tagged(speaker: "You", start: $0.start, text: $0.text) }
                      + others.map { Tagged(speaker: "Others", start: $0.start, text: $0.text) })
            .sorted { $0.start < $1.start }

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
