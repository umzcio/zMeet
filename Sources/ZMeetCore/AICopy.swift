import Foundation

/// Every user-facing sentence about AI providers, in one tested place.
public enum AICopy {
    /// Settings' privacy note: where transcripts go for the selected provider.
    public static func privacyNote(provider: AIProvider, ollamaAddress: String) -> String {
        switch provider {
        case .onDevice:
            return "Everything stays on this Mac."
        case .ollama:
            guard let host = OllamaAddress.host(ollamaAddress) else {
                return "Enter your Ollama server's address."
            }
            return OllamaAddress.isThisMac(ollamaAddress)
                ? "Transcripts go to Ollama on this Mac. Nothing leaves your computer."
                : "Transcripts go to your Ollama server at \(host) on your network."
        case .openAI, .anthropic:
            return "When selected, text from your meetings is sent to \(provider.displayName) for: summaries (transcript + title), the linked-note entities used by Obsidian publishing (notes + part of the transcript), and auto-titles (notes). This includes the Obsidian backfill, which processes every meeting you publish. Your audio always stays on your Mac."
        }
    }

    /// Extra sentence for the Obsidian backfill row, or nil when nothing leaves
    /// this Mac.
    public static func backfillWarning(provider: AIProvider, ollamaAddress: String) -> String? {
        switch provider {
        case .onDevice:
            return nil
        case .ollama:
            guard let host = OllamaAddress.host(ollamaAddress), !OllamaAddress.isThisMac(ollamaAddress) else { return nil }
            return " Entity extraction sends each published meeting's text to your Ollama server at \(host)."
        case .openAI, .anthropic:
            return " Entity extraction sends each published meeting's text to \(provider.displayName)."
        }
    }

    /// Short explanation of a failed request, for Test connection and the model list.
    public static func failureMessage(_ error: Error, provider: AIProvider) -> String {
        guard let error = error as? AIProviderError else {
            return "Test failed: \(error.localizedDescription)"
        }
        switch error {
        case .missingKey:
            return "No API key saved."
        case .http(let status) where status == 401 || status == 403:
            return "Key rejected (\(status))."
        case .http(404) where provider == .ollama:
            return "No Ollama server answered at that address (HTTP 404)."
        case .http(let status):
            return "Request failed (HTTP \(status))."
        case .network where provider == .ollama:
            return "Couldn't reach Ollama at that address. Is it running?"
        case .network:
            return "Network error — check your connection."
        case .decode:
            return "Unexpected response from \(provider.displayName)."
        }
    }

    /// Result of Test connection once the model list loaded.
    public static func connectionCheck(models: [String], model: String, provider: AIProvider) -> (ok: Bool, message: String) {
        let name = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return (false, "Connected, but no model is chosen yet.") }
        guard ModelCatalog.contains(models, model: name) else {
            return (false, "Connected, but \(provider.displayName) has no model named “\(name)”.")
        }
        return (true, "Connected. \(name) is available.")
    }

    /// Menu warning when the provider was attempted and on-device wrote the notes.
    public static func fallbackNotice(provider: AIProvider) -> String {
        "\(provider.displayName) summary failed — this meeting's notes were generated on-device. Check Settings → AI."
    }

    /// Menu warning when the selected provider couldn't be attempted (no key,
    /// model, or usable address).
    public static func notConfiguredNotice(provider: AIProvider) -> String {
        "\(provider.displayName) isn't set up yet, so this meeting's notes were generated on-device. Finish setup in Settings → AI."
    }
}
