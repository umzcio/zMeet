import Foundation
import FoundationModels
import ZMeetCore

/// Runs a prompt through whichever summary engine is active — cloud Anthropic when
/// cloud summaries are on and a key is present, otherwise on-device FoundationModels.
/// Best-effort: returns nil on any failure or unavailability so callers can degrade
/// gracefully. Shared by EntityExtractor and TitleGenerator.
struct LLMRunner {
    let useCloud: Bool
    /// Anthropic key when cloud is selected; nil/empty falls back to on-device.
    let apiKey: String?

    func run(prompt: String) async -> String? {
        if useCloud, let key = apiKey, !key.isEmpty {
            return await runCloud(prompt: prompt, key: key)
        }
        return await runOnDevice(prompt: prompt)
    }

    private func runCloud(prompt: String, key: String) async -> String? {
        do {
            let request = try AnthropicSummary.makeRequest(key: key, prompt: prompt)
            let (data, response) = try await AnthropicHTTP.session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            return try AnthropicSummary.parseSummary(data: data, status: status)
        } catch {
            return nil
        }
    }

    private func runOnDevice(prompt: String) async -> String? {
        let model = SystemLanguageModel.default
        guard case .available = model.availability else { return nil }
        do {
            return try await LanguageModelSession().respond(to: prompt).content
        } catch {
            return nil
        }
    }
}
