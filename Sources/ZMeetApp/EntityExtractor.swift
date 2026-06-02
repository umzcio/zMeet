import Foundation
import FoundationModels
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
        guard let raw = await runModel(prompt: prompt) else { return MeetingEntities() }
        return EntityParser.parse(raw)
    }

    /// Returns raw model text, or nil on any failure.
    private func runModel(prompt: String) async -> String? {
        if useCloud, let key = apiKey, !key.isEmpty {
            return await runCloud(prompt: prompt, key: key)
        }
        return await runOnDevice(prompt: prompt)
    }

    private func runCloud(prompt: String, key: String) async -> String? {
        do {
            let request = try AnthropicSummary.makeRequest(key: key, prompt: prompt)
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            return try AnthropicSummary.parseSummary(data: data, status: status)
        } catch {
            return nil
        }
    }

    private func runOnDevice(prompt: String) async -> String? {
        guard #available(macOS 26, *) else { return nil }
        let model = SystemLanguageModel.default
        guard case .available = model.availability else { return nil }
        do {
            return try await LanguageModelSession().respond(to: prompt).content
        } catch {
            return nil
        }
    }
}
