import Foundation

/// Errors from any non-Apple AI provider. The summarization policy catches all
/// of these and falls back to on-device; Settings' Test connection shows them
/// via `AICopy.failureMessage`.
public enum AIProviderError: Error, Equatable {
    case missingKey
    case http(status: Int)
    case network
    case decode
}

/// Pure request-building and response-parsing for the Anthropic Messages API.
/// Lives in Core so it is unit-testable without a live network call; the actual
/// URLSession call is done by `AIConnection.complete` in the app target.
public enum AnthropicSummary {
    public static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    public static let modelsEndpoint = URL(string: "https://api.anthropic.com/v1/models")!
    public static let model = "claude-sonnet-5"

    /// Human-readable name of `model`, for Settings — derived rather than stored
    /// separately, so it always names the model the requests actually use.
    public static var modelDisplayName: String { displayName(forModel: model) }

    /// "claude-sonnet-4-6" → "Claude Sonnet 4.6": words capitalized, trailing
    /// version numbers joined with a dot. A trailing 8-digit date snapshot
    /// ("-20250929") is dropped.
    public static func displayName(forModel id: String) -> String {
        var parts = id.split(separator: "-").map(String.init)
        if let last = parts.last, last.count == 8, Int(last) != nil { parts.removeLast() }
        let words = parts.prefix { Int($0) == nil }.map { $0.prefix(1).uppercased() + $0.dropFirst() }
        let version = parts.drop { Int($0) == nil }.joined(separator: ".")
        return (words + (version.isEmpty ? [] : [version])).joined(separator: " ")
    }

    /// A zero-cost key-validation request: `GET /v1/models` authenticates the key
    /// (200 = valid, 401 = rejected) without generating any tokens. Used by the
    /// Settings "Test key" button instead of running a real summary.
    public static func makeValidationRequest(key: String) -> URLRequest {
        var req = URLRequest(url: modelsEndpoint)
        req.httpMethod = "GET"
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        return req
    }

    public static func makeRequest(key: String, model: String = AnthropicSummary.model, prompt: String, maxTokens: Int = 1500) throws -> URLRequest {
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        let payload: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "messages": [["role": "user", "content": prompt]],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        return req
    }

    public static func parseSummary(data: Data, status: Int) throws -> String {
        guard status == 200 else { throw AIProviderError.http(status: status) }
        guard
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let content = obj["content"] as? [[String: Any]]
        else { throw AIProviderError.decode }
        let text = content.compactMap { $0["text"] as? String }.joined()
        guard !text.isEmpty else { throw AIProviderError.decode }
        return text
    }
}
