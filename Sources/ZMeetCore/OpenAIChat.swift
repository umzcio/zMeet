import Foundation

/// Pure request-building and parsing for the OpenAI chat-completions format,
/// which OpenAI serves at api.openai.com/v1 and Ollama serves at <address>/v1.
/// The URLSession call is done by `AIConnection.complete` in the app target.
public enum OpenAIChat {
    public static let openAIBaseURL = URL(string: "https://api.openai.com/v1")!

    /// `POST <base>/chat/completions` with one user message. Deliberately omits
    /// temperature and max_tokens: some OpenAI reasoning models reject them.
    public static func makeRequest(baseURL: URL, key: String?, model: String, prompt: String) throws -> URLRequest {
        var req = URLRequest(url: baseURL.appending(path: "chat/completions"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyAuth(&req, key: key)
        let payload: [String: Any] = [
            "model": model,
            "messages": [["role": "user", "content": prompt]],
            "stream": false,
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        return req
    }

    /// `GET <base>/models`: zero-token, used for the model list and Test connection.
    public static func makeModelsRequest(baseURL: URL, key: String?) -> URLRequest {
        var req = URLRequest(url: baseURL.appending(path: "models"))
        req.httpMethod = "GET"
        applyAuth(&req, key: key)
        return req
    }

    public static func parseCompletion(data: Data, status: Int) throws -> String {
        guard status == 200 else { throw AIProviderError.http(status: status) }
        guard
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = obj["choices"] as? [[String: Any]],
            let message = choices.first?["message"] as? [String: Any],
            let content = message["content"] as? String,
            !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw AIProviderError.decode }
        return content
    }

    /// Adds a bearer token only when a non-blank key is set — a local Ollama
    /// needs none.
    public static func applyAuth(_ req: inout URLRequest, key: String?) {
        if let key = key?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
    }
}
