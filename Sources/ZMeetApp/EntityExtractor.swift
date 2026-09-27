import Foundation
import ZMeetCore

/// Extracts linkable entities (people/projects/topics) for the Obsidian export by
/// running the entity-extraction prompt through whichever summary engine is active.
/// Best-effort: any failure yields empty entities so it never blocks publishing.
struct EntityExtractor {
    /// The selected provider; nil (or not set up) runs on-device.
    let connection: AIConnection?

    func extract(summary: String, transcript: String) async -> MeetingEntities {
        let prompt = MeetingSummaryPrompt.extractEntities(summary: summary, transcript: transcript)
        guard let raw = await LLMRunner(connection: connection).run(prompt: prompt) else {
            return MeetingEntities()
        }
        return EntityParser.parse(raw)
    }
}
