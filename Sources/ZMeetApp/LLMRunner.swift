import Foundation
import FoundationModels
import ZMeetCore

/// Runs a prompt through the selected provider, falling back to on-device
/// FoundationModels when the provider isn't set up or fails. Best-effort:
/// returns nil when both fail, so callers degrade gracefully. Shared by
/// EntityExtractor and TitleGenerator.
struct LLMRunner {
    /// The selected non-Apple provider, or nil for on-device.
    let connection: AIConnection?

    func run(prompt: String) async -> String? {
        if let connection, connection.isUsable,
           let text = try? await connection.complete(prompt: prompt) {
            // Reasoning models prefix a <think> block; it must never become a title.
            return SummaryOutput.clean(text)
        }
        return await runOnDevice(prompt: prompt)
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
