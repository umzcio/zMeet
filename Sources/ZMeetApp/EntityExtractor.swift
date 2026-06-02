import Foundation
import ZMeetCore

/// Extracts linkable entities (people/projects/topics) for the Obsidian export by
/// running the entity-extraction prompt through whichever summary engine is active.
/// Best-effort: any failure yields empty entities so it never blocks publishing.
struct EntityExtractor {
    let useCloud: Bool
    /// Anthropic key when cloud extraction is selected; nil/empty falls back to on-device.
    let apiKey: String?

    func extract(summary: String, transcript: String) async -> MeetingEntities {
        let prompt = MeetingSummaryPrompt.extractEntities(summary: summary, transcript: transcript)
        guard let raw = await LLMRunner(useCloud: useCloud, apiKey: apiKey).run(prompt: prompt) else {
            return MeetingEntities()
        }
        return EntityParser.parse(raw)
    }
}
