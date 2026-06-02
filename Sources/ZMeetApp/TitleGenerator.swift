import Foundation
import ZMeetCore

/// Generates a short, descriptive title for a meeting that has no real one (in-person
/// or manual recordings titled "Untitled Meeting"), from its summary. Best-effort:
/// returns nil on any failure, leaving the existing title untouched.
struct TitleGenerator {
    let useCloud: Bool
    let apiKey: String?

    func title(summary: String) async -> String? {
        let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let prompt = MeetingSummaryPrompt.titlePrompt(summary: trimmed)
        guard let raw = await LLMRunner(useCloud: useCloud, apiKey: apiKey).run(prompt: prompt) else { return nil }
        return MeetingTitle.clean(raw)
    }
}
