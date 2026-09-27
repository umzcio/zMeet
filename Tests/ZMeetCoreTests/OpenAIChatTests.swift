import Foundation
import Testing
@testable import ZMeetCore

private func jsonBody(_ req: URLRequest) throws -> [String: Any] {
    let body = try #require(req.httpBody)
    return try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
}

@Test func openAIRequestShape() throws {
    let req = try OpenAIChat.makeRequest(baseURL: OpenAIChat.openAIBaseURL, key: "sk-test", model: "gpt-5-mini", prompt: "hello")
    #expect(req.httpMethod == "POST")
    #expect(req.url?.absoluteString == "https://api.openai.com/v1/chat/completions")
    #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")
    #expect(req.value(forHTTPHeaderField: "Content-Type") == "application/json")
    let json = try jsonBody(req)
    #expect(json["model"] as? String == "gpt-5-mini")
    let messages = try #require(json["messages"] as? [[String: Any]])
    #expect(messages.count == 1)
    #expect(messages[0]["role"] as? String == "user")
    #expect(messages[0]["content"] as? String == "hello")
    #expect(json["temperature"] == nil)
    #expect(json["max_tokens"] == nil)
}

@Test func requestWithoutKeySendsNoAuthorization() throws {
    let base = try #require(OllamaAddress.chatBaseURL("localhost:11434"))
    let noKey = try OpenAIChat.makeRequest(baseURL: base, key: nil, model: "llama3.1:8b", prompt: "p")
    #expect(noKey.url?.absoluteString == "http://localhost:11434/v1/chat/completions")
    #expect(noKey.value(forHTTPHeaderField: "Authorization") == nil)
    let blank = try OpenAIChat.makeRequest(baseURL: base, key: "   ", model: "llama3.1:8b", prompt: "p")
    #expect(blank.value(forHTTPHeaderField: "Authorization") == nil)
}

@Test func modelsRequestIsAuthenticatedGet() {
    let req = OpenAIChat.makeModelsRequest(baseURL: OpenAIChat.openAIBaseURL, key: "sk-test")
    #expect(req.httpMethod == "GET")
    #expect(req.url?.absoluteString == "https://api.openai.com/v1/models")
    #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")
    #expect(req.httpBody == nil)
}

@Test func parseCompletionReadsFirstChoice() throws {
    let data = Data(###"{"choices":[{"message":{"role":"assistant","content":"## Summary\n- ok"}}]}"###.utf8)
    #expect(try OpenAIChat.parseCompletion(data: data, status: 200) == "## Summary\n- ok")
}

@Test func parseCompletionMapsFailures() {
    #expect(throws: AIProviderError.http(status: 401)) {
        try OpenAIChat.parseCompletion(data: Data(), status: 401)
    }
    #expect(throws: AIProviderError.decode) {
        try OpenAIChat.parseCompletion(data: Data("not json".utf8), status: 200)
    }
    #expect(throws: AIProviderError.decode) {
        try OpenAIChat.parseCompletion(data: Data(#"{"choices":[]}"#.utf8), status: 200)
    }
    #expect(throws: AIProviderError.decode) {
        try OpenAIChat.parseCompletion(data: Data(#"{"choices":[{"message":{"content":"  \n"}}]}"#.utf8), status: 200)
    }
}

@Test func ollamaAddressNormalization() {
    #expect(OllamaAddress.normalized("http://localhost:11434")?.absoluteString == "http://localhost:11434")
    #expect(OllamaAddress.normalized("  192.168.1.20:11434  ")?.absoluteString == "http://192.168.1.20:11434")
    #expect(OllamaAddress.normalized("http://studio.local:11434/")?.absoluteString == "http://studio.local:11434")
    #expect(OllamaAddress.normalized("http://studio.local:11434/v1/")?.absoluteString == "http://studio.local:11434")
    #expect(OllamaAddress.normalized("https://ollama.example.com")?.absoluteString == "https://ollama.example.com")
    #expect(OllamaAddress.normalized("") == nil)
    #expect(OllamaAddress.normalized("ftp://host") == nil)
    #expect(OllamaAddress.tagsURL("localhost:11434")?.absoluteString == "http://localhost:11434/api/tags")
}

@Test func ollamaThisMacDetection() {
    #expect(OllamaAddress.isThisMac("http://localhost:11434"))
    #expect(OllamaAddress.isThisMac("http://127.0.0.1:11434"))
    #expect(OllamaAddress.isThisMac("http://[::1]:11434"))
    #expect(!OllamaAddress.isThisMac("http://192.168.1.20:11434"))
    #expect(!OllamaAddress.isThisMac("http://studio.local:11434"))
    #expect(!OllamaAddress.isThisMac(""))
    #expect(OllamaAddress.host("http://[::1]:11434") == "::1")
    #expect(OllamaAddress.host("192.168.1.20:11434") == "192.168.1.20")
}
