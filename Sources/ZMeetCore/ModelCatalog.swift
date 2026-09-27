import Foundation

/// Parses each provider's model list for the Settings picker and Test
/// connection. Pure; the requests are sent by `AIConnection.listModels`.
public enum ModelCatalog {
    /// Ollama `GET /api/tags` → `models[].name`, in server order.
    public static func parseOllamaTags(_ data: Data) throws -> [String] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = obj["models"] as? [[String: Any]]
        else { throw AIProviderError.decode }
        return models.compactMap { $0["name"] as? String }
    }

    /// OpenAI `GET /v1/models` → chat-capable ids, newest first (by `created`),
    /// ties broken alphabetically.
    public static func parseOpenAIModels(_ data: Data) throws -> [String] {
        let entries = try dataEntries(data)
        return entries
            .compactMap { entry -> (id: String, created: Int)? in
                guard let id = entry["id"] as? String, isOpenAIChatModel(id) else { return nil }
                return (id, entry["created"] as? Int ?? 0)
            }
            .sorted { $0.created != $1.created ? $0.created > $1.created : $0.id < $1.id }
            .map(\.id)
    }

    /// Anthropic `GET /v1/models` → `data[].id`, in API order (newest first).
    public static func parseAnthropicModels(_ data: Data) throws -> [String] {
        try dataEntries(data).compactMap { $0["id"] as? String }
    }

    /// OpenAI's list mixes chat models with image, speech, embedding, and
    /// moderation models. Keep chat families; drop the rest. A heuristic — the
    /// Settings model field accepts any name as the escape hatch.
    public static func isOpenAIChatModel(_ id: String) -> Bool {
        let lower = id.lowercased()
        let chatPrefixes = ["gpt-", "o1", "o3", "o4", "chatgpt-"]
        let excluded = ["audio", "realtime", "tts", "transcribe", "image", "search",
                        "embedding", "moderation", "whisper", "dall-e"]
        guard chatPrefixes.contains(where: lower.hasPrefix) else { return false }
        return !excluded.contains(where: lower.contains)
    }

    /// Whether `model` is in the list. Ollama treats a name without a tag as
    /// ":latest", so "llama3.1" matches "llama3.1:latest".
    public static func contains(_ models: [String], model: String) -> Bool {
        if models.contains(model) { return true }
        return !model.contains(":") && models.contains(model + ":latest")
    }

    /// `GET <address>/api/tags`, with a bearer token only when a key is set.
    /// nil when the address is unusable.
    public static func makeOllamaTagsRequest(address: String, key: String?) -> URLRequest? {
        guard let url = OllamaAddress.tagsURL(address) else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        OpenAIChat.applyAuth(&req, key: key)
        return req
    }

    private static func dataEntries(_ data: Data) throws -> [[String: Any]] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = obj["data"] as? [[String: Any]]
        else { throw AIProviderError.decode }
        return entries
    }
}
