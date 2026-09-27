import Foundation
import Testing
@testable import ZMeetCore

@Test func makeRequestSetsHeadersAndBody() throws {
    let req = try AnthropicSummary.makeRequest(key: "sk-test", prompt: "hello prompt")
    #expect(req.httpMethod == "POST")
    #expect(req.url?.absoluteString == "https://api.anthropic.com/v1/messages")
    #expect(req.value(forHTTPHeaderField: "x-api-key") == "sk-test")
    #expect(req.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
    #expect(req.value(forHTTPHeaderField: "content-type") == "application/json")

    let body = try #require(req.httpBody)
    let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
    #expect(json["model"] as? String == "claude-sonnet-5")
    let messages = try #require(json["messages"] as? [[String: Any]])
    #expect(messages.first?["content"] as? String == "hello prompt")
}

@Test func makeValidationRequestIsGetWithAuthHeadersAndNoBody() {
    let req = AnthropicSummary.makeValidationRequest(key: "sk-test")
    #expect(req.httpMethod == "GET")
    #expect(req.url?.absoluteString == "https://api.anthropic.com/v1/models")
    #expect(req.value(forHTTPHeaderField: "x-api-key") == "sk-test")
    #expect(req.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
    #expect(req.httpBody == nil)
}

@Test func parseSummaryExtractsTextOn200() throws {
    let body = "{\"content\":[{\"type\":\"text\",\"text\":\"## Summary\\n- Did things\"}]}".data(using: .utf8)!
    let text = try AnthropicSummary.parseSummary(data: body, status: 200)
    #expect(text.contains("## Summary"))
}

@Test func parseSummaryMapsHTTPErrors() {
    let empty = Data()
    #expect(throws: AIProviderError.http(status: 401)) {
        try AnthropicSummary.parseSummary(data: empty, status: 401)
    }
    #expect(throws: AIProviderError.http(status: 429)) {
        try AnthropicSummary.parseSummary(data: empty, status: 429)
    }
    #expect(throws: AIProviderError.http(status: 500)) {
        try AnthropicSummary.parseSummary(data: empty, status: 500)
    }
}

@Test func parseSummaryMapsMalformedBodyToDecode() {
    let garbage = "not json".data(using: .utf8)!
    #expect(throws: AIProviderError.decode) {
        try AnthropicSummary.parseSummary(data: garbage, status: 200)
    }
}

/// Settings shows which model cloud summaries use — derived from the same
/// constant the request sends, so the label can't drift from reality.
@Test func modelDisplayNameMatchesTheModelInUse() {
    #expect(AnthropicSummary.modelDisplayName == "Claude Sonnet 5")
}

@Test func displayNameJoinsTrailingVersionNumbersWithADot() {
    #expect(AnthropicSummary.displayName(forModel: "claude-sonnet-4-6") == "Claude Sonnet 4.6")
    #expect(AnthropicSummary.displayName(forModel: "claude-fable-5-1") == "Claude Fable 5.1")
    #expect(AnthropicSummary.displayName(forModel: "claude-opus-5") == "Claude Opus 5")
}

@Test func makeRequestUsesTheGivenModel() throws {
    let req = try AnthropicSummary.makeRequest(key: "sk-test", model: "claude-opus-5-5", prompt: "p")
    let body = try #require(req.httpBody)
    let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
    #expect(json["model"] as? String == "claude-opus-5-5")
}

@Test func providerErrorNamesTheSharedCases() {
    let errors: [AIProviderError] = [.missingKey, .http(status: 401), .network, .decode]
    #expect(errors.count == 4)
}

@Test func displayNameDropsDateSuffix() {
    #expect(AnthropicSummary.displayName(forModel: "claude-sonnet-4-5-20250929") == "Claude Sonnet 4.5")
    #expect(AnthropicSummary.displayName(forModel: "claude-sonnet-5") == "Claude Sonnet 5")
}
