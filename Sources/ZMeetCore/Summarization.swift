import Foundation

/// Which engine produced a meeting's summary. Presentation/attribution only —
/// not persisted on the session.
public enum SummaryEngine: Sendable, Equatable {
    case onDevice
    case cloud

    /// Footer line appended to the rendered note (not indexed for search).
    public var attribution: String {
        switch self {
        case .onDevice: "Summary generated on-device"
        case .cloud: "Summary by Claude Sonnet (cloud)"
        }
    }
}

/// A transcript-to-Markdown summarizer. Both the on-device and cloud engines
/// conform, so the policy can treat them uniformly.
public protocol Summarizer: Sendable {
    func summarize(transcript: String, title: String) async throws -> String
}

/// The single prompt shared by both engines so notes are structurally identical
/// regardless of which engine runs. Callers clip the transcript to their own
/// context budget before calling.
public enum MeetingSummaryPrompt {
    public static func build(transcript: String, title: String) -> String {
        """
        You are writing meeting notes for a meeting titled "\(title)".
        Using only the transcript below, produce concise notes in Markdown with \
        exactly these sections and headers:

        ## Summary
        (2–4 sentences.)

        ## Key Points
        (Bulleted.)

        ## Action Items
        (Bulleted; include an owner if the transcript names one.)

        ## Decisions
        (Bulleted.)

        If a section has nothing, write "- None". Do not invent content that is \
        not supported by the transcript.

        Transcript:
        \(transcript)
        """
    }
}
