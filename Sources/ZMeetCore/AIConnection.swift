import Foundation

/// Everything needed to call the selected non-Apple provider, resolved from
/// config + Keychain at the moment of use. The app target adds the network
/// calls (`complete`, `listModels`) in an extension.
public struct AIConnection: Sendable, Equatable {
    public let provider: AIProvider
    public let model: String
    public let key: String?
    public let ollamaAddress: String

    public init(provider: AIProvider, model: String, key: String?, ollamaAddress: String) {
        self.provider = provider
        self.model = model
        self.key = key
        self.ollamaAddress = ollamaAddress
    }

    /// The selected provider's connection, or nil when it's on-device.
    public static func current(config: ZMeetConfig, secrets: SecretStore) -> AIConnection? {
        let provider = config.aiProvider
        guard provider != .onDevice else { return nil }
        return AIConnection(
            provider: provider,
            model: config.model(for: provider),
            key: provider.secretAccount.flatMap { secrets.read(account: $0) },
            ollamaAddress: config.ollamaAddress)
    }

    /// Ready to generate: a model, a key when the provider needs one, and a
    /// usable address for Ollama.
    public var isUsable: Bool {
        guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        if provider.requiresKey, (key ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }
        if provider == .ollama, OllamaAddress.normalized(ollamaAddress) == nil { return false }
        return true
    }

    /// Map-reduce under the provider's chunk budget, or one capped request.
    public func summarizer(complete: @escaping MapReduceSummarizer.Complete) -> any Summarizer {
        if let budget = provider.chunkBudget {
            return MapReduceSummarizer(maxChunkCharacters: budget, complete: complete)
        }
        return SinglePassSummarizer(complete: complete)
    }
}
