import Foundation
import ZMeetCore

/// Summarizes a transcript via the Anthropic Messages API. A thin shell over the
/// pure `AnthropicSummary` helpers in Core: build request → URLSession → parse.
struct CloudSummarizer: Summarizer {
    let apiKey: String
    /// Sonnet's context easily holds a full meeting; cap only to guard against
    /// pathological inputs.
    private let maxTranscriptCharacters = 150_000

    func summarize(transcript: String, title: String) async throws -> String {
        guard !apiKey.isEmpty else { throw CloudSummaryError.missingKey }
        let clipped = String(transcript.prefix(maxTranscriptCharacters))
        let prompt = MeetingSummaryPrompt.build(transcript: clipped, title: title)
        let request = try AnthropicSummary.makeRequest(key: apiKey, prompt: prompt)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw CloudSummaryError.network
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return try AnthropicSummary.parseSummary(data: data, status: status)
    }

    /// Validates the key against `GET /v1/models` — zero token cost, just an auth
    /// check. Throws `CloudSummaryError` on a non-200 / network failure.
    func validateKey() async throws {
        guard !apiKey.isEmpty else { throw CloudSummaryError.missingKey }
        let request = AnthropicSummary.makeValidationRequest(key: apiKey)
        let response: URLResponse
        do {
            (_, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw CloudSummaryError.network
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw CloudSummaryError.http(status: status) }
    }
}
