import Foundation
import Testing
@testable import ZMeetCore

private final class MemorySecrets: SecretStore, @unchecked Sendable {
    var values: [String: String]
    init(_ values: [String: String] = [:]) { self.values = values }
    func read(account: String) -> String? { values[account] }
    func write(_ value: String, account: String) throws { values[account] = value }
    func delete(account: String) throws { values[account] = nil }
}

@Test func onDeviceHasNoConnection() {
    let config = ZMeetConfig.default(outputPath: "/tmp/z")
    #expect(AIConnection.current(config: config, secrets: MemorySecrets()) == nil)
}

@Test func currentReadsProviderModelKeyAndAddress() {
    var config = ZMeetConfig.default(outputPath: "/tmp/z")
    config.aiProvider = .openAI
    config.setModel("gpt-5-mini", for: .openAI)
    let secrets = MemorySecrets(["openai-api-key": "sk-o", "anthropic-api-key": "sk-a"])
    let connection = AIConnection.current(config: config, secrets: secrets)
    #expect(connection == AIConnection(provider: .openAI, model: "gpt-5-mini", key: "sk-o",
                                       ollamaAddress: "http://localhost:11434"))
}

@Test func usabilityNeedsModelAndRequiredKey() {
    #expect(AIConnection(provider: .anthropic, model: "claude-sonnet-5", key: "k", ollamaAddress: "").isUsable)
    #expect(!AIConnection(provider: .anthropic, model: "claude-sonnet-5", key: nil, ollamaAddress: "").isUsable)
    #expect(!AIConnection(provider: .openAI, model: "gpt-5", key: "  ", ollamaAddress: "").isUsable)
    #expect(!AIConnection(provider: .openAI, model: " ", key: "k", ollamaAddress: "").isUsable)
    #expect(AIConnection(provider: .ollama, model: "llama3.1", key: nil, ollamaAddress: "localhost:11434").isUsable)
    #expect(!AIConnection(provider: .ollama, model: "llama3.1", key: nil, ollamaAddress: "").isUsable)
    #expect(!AIConnection(provider: .ollama, model: "", key: nil, ollamaAddress: "localhost:11434").isUsable)
}

@Test func summarizerShapeFollowsProvider() {
    let complete: MapReduceSummarizer.Complete = { _ in "" }
    #expect(AIConnection(provider: .ollama, model: "m", key: nil, ollamaAddress: "localhost").summarizer(complete: complete) is MapReduceSummarizer)
    #expect(AIConnection(provider: .openAI, model: "m", key: "k", ollamaAddress: "").summarizer(complete: complete) is SinglePassSummarizer)
    #expect(AIConnection(provider: .anthropic, model: "m", key: "k", ollamaAddress: "").summarizer(complete: complete) is SinglePassSummarizer)
}
