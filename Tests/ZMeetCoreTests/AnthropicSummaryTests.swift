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
    #expect(json["model"] as? String == "claude-sonnet-4-6")
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
    #expect(throws: CloudSummaryError.http(status: 401)) {
        try AnthropicSummary.parseSummary(data: empty, status: 401)
    }
    #expect(throws: CloudSummaryError.http(status: 429)) {
        try AnthropicSummary.parseSummary(data: empty, status: 429)
    }
    #expect(throws: CloudSummaryError.http(status: 500)) {
        try AnthropicSummary.parseSummary(data: empty, status: 500)
    }
}

@Test func parseSummaryMapsMalformedBodyToDecode() {
    let garbage = "not json".data(using: .utf8)!
    #expect(throws: CloudSummaryError.decode) {
        try AnthropicSummary.parseSummary(data: garbage, status: 200)
    }
}
