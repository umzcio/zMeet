import Foundation

/// Accumulates a streamed (SSE) Anthropic Messages response, one line at a
/// time. Streaming keeps bytes flowing while the model thinks, so long replies
/// don't hit the session's idle timeout. Only `text_delta`s are kept: thinking
/// and signature deltas are dropped, and pings and other events are ignored.
public struct AnthropicStream: Sendable {
    public private(set) var text = ""
    public private(set) var stopReason: String?
    public private(set) var outputTokens: Int?

    public init() {}

    /// Feeds one line of the event stream; throws on a mid-stream `error` event.
    public mutating func consume(line: String) throws {
        guard line.hasPrefix("data:") else { return }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard let event = (try? JSONSerialization.jsonObject(with: Data(payload.utf8))) as? [String: Any] else { return }
        switch event["type"] as? String {
        case "content_block_delta":
            if let delta = event["delta"] as? [String: Any], delta["type"] as? String == "text_delta",
               let piece = delta["text"] as? String {
                text += piece
            }
        case "message_delta":
            if let reason = (event["delta"] as? [String: Any])?["stop_reason"] as? String { stopReason = reason }
            if let tokens = (event["usage"] as? [String: Any])?["output_tokens"] as? Int { outputTokens = tokens }
        case "error":
            switch (event["error"] as? [String: Any])?["type"] as? String {
            case "overloaded_error": throw AIProviderError.http(status: 529)
            case "rate_limit_error": throw AIProviderError.http(status: 429)
            default: throw AIProviderError.http(status: 500)
            }
        default:
            break
        }
    }

    /// The reply's text. A stream that produced none (e.g. all thinking) is a
    /// decode error, like an empty non-streamed reply, and so is one cut off at
    /// max_tokens: a partial fact list would silently drop the meeting's end.
    public func result() throws -> String {
        guard !text.isEmpty, stopReason != "max_tokens" else { throw AIProviderError.decode }
        return text
    }
}
