import Foundation

/// Interprets the Ollama server address typed in Settings. Accepts the forms
/// people actually paste — "192.168.1.20:11434", a trailing slash, or the
/// "/v1" OpenAI-compatible path — and reduces them to scheme://host[:port].
public enum OllamaAddress {
    public static func normalized(_ raw: String) -> URL? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if !s.contains("://") { s = "http://" + s }
        while s.hasSuffix("/") { s.removeLast() }
        if s.lowercased().hasSuffix("/v1") { s.removeLast(3) }
        while s.hasSuffix("/") { s.removeLast() }
        guard let url = URL(string: s),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host(percentEncoded: false), !host.isEmpty
        else { return nil }
        return url
    }

    /// Base for the OpenAI-compatible endpoints: <address>/v1.
    public static func chatBaseURL(_ raw: String) -> URL? {
        normalized(raw)?.appending(path: "v1")
    }

    /// Ollama's native model list: <address>/api/tags.
    public static func tagsURL(_ raw: String) -> URL? {
        normalized(raw)?.appending(path: "api/tags")
    }

    /// The host for display, without IPv6 brackets.
    public static func host(_ raw: String) -> String? {
        normalized(raw)?.host(percentEncoded: false)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "[]")) }
    }

    /// Whether the address points at this Mac, so nothing leaves the computer.
    public static func isThisMac(_ raw: String) -> Bool {
        guard let host = host(raw)?.lowercased() else { return false }
        return host == "localhost" || host == "::1" || host.hasPrefix("127.")
    }
}
