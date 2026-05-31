import Foundation

/// Errors from the cloud summary path. The policy catches all of these and falls
/// back to on-device; "Test key" in Settings surfaces them directly.
public enum CloudSummaryError: Error, Equatable {
    case missingKey
    case http(status: Int)
    case network
    case decode
}

/// Pure request-building and response-parsing for the Anthropic Messages API.
/// Lives in Core so it is unit-testable without a live network call; the actual
/// URLSession call is done by `CloudSummarizer` in the app target.
public enum AnthropicSummary {
    public static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    public static let model = "claude-sonnet-4-6"

    public static func makeRequest(key: String, prompt: String, maxTokens: Int = 1500) throws -> URLRequest {
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
        guard status == 200 else { throw CloudSummaryError.http(status: status) }
        guard
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let content = obj["content"] as? [[String: Any]]
        else { throw CloudSummaryError.decode }
        let text = content.compactMap { $0["text"] as? String }.joined()
        guard !text.isEmpty else { throw CloudSummaryError.decode }
        return text
    }
}
