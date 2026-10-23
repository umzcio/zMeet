import Foundation

/// One transcribed chunk with its start and end offsets (seconds) in the source audio.
public struct TranscriptSegment: Sendable, Equatable {
    public var text: String
    public var start: TimeInterval
    /// End offset in seconds; `start` when unknown.
    public var end: TimeInterval
    public init(text: String, start: TimeInterval, end: TimeInterval? = nil) {
        self.text = text
        self.start = start
        self.end = end ?? start
    }
}

/// Merges per-side transcript segments ("You" = mic, "Others" = system) into one
/// chronological, speaker-labeled Markdown transcript, paragraphed and timestamped
/// by `TranscriptFormatter`. Pure and Sendable.
public struct Diarizer: Sendable {
    public init() {}

    public func merge(you: [TranscriptSegment], others: [TranscriptSegment]) -> String {
        TranscriptFormatter().format(labelled: [("You", you), ("Others", others)])
    }
}
