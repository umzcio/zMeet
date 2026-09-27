import Foundation

/// Which AI service writes meeting notes, auto-titles, and Obsidian entity links.
/// One selection drives all three.
public enum AIProvider: String, Codable, CaseIterable, Sendable, Identifiable {
    case onDevice, ollama, openAI, anthropic

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .onDevice: "On-device"
        case .ollama: "Ollama"
        case .openAI: "OpenAI"
        case .anthropic: "Anthropic"
        }
    }

    /// Keychain account holding this provider's key; nil when it has no key.
    public var secretAccount: String? {
        switch self {
        case .onDevice: nil
        case .ollama: SecretAccount.ollamaAPIKey
        case .openAI: SecretAccount.openAIAPIKey
        case .anthropic: SecretAccount.anthropicAPIKey
        }
    }

    /// Whether requests can't be made without a key. Ollama's key is optional
    /// (only for servers behind an authenticating proxy).
    public var requiresKey: Bool { self == .openAI || self == .anthropic }

    /// The model used when none has been chosen for this provider.
    public var defaultModel: String { self == .anthropic ? AnthropicSummary.model : "" }

    /// Per-chunk transcript budget (characters) for map-reduce summarization, or
    /// nil to send the whole (capped) transcript in one request. Ollama's common
    /// default context is 4,096 tokens: ~2k tokens of transcript plus the prompt
    /// and the reply fits.
    public var chunkBudget: Int? {
        switch self {
        case .onDevice: 10_000
        case .ollama: 8_000
        case .openAI, .anthropic: nil
        }
    }

    public static let defaultOllamaAddress = "http://localhost:11434"
}
