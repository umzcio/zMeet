import Foundation
import Testing
@testable import ZMeetCore

private func decodeConfig(_ json: String) throws -> ZMeetConfig {
    try JSONDecoder.zmeet.decode(ZMeetConfig.self, from: Data(json.utf8))
}

@Test func defaultConfigIsOnDeviceWithLocalOllamaAddress() {
    let config = ZMeetConfig.default(outputPath: "/tmp/zmeet-output")
    #expect(config.aiProvider == .onDevice)
    #expect(config.ollamaAddress == "http://localhost:11434")
    #expect(config.model(for: .anthropic) == "claude-sonnet-5")
    #expect(config.model(for: .ollama) == "")
    #expect(config.model(for: .openAI) == "")
}

@Test func legacyCloudOnMigratesToAnthropicSonnet() throws {
    let config = try decodeConfig(#"{"outputPath":"/tmp/x","appDataPath":"/tmp/x/d","useCloudSummaries":true}"#)
    #expect(config.aiProvider == .anthropic)
    #expect(config.aiModels["anthropic"] == "claude-sonnet-5")
}

@Test func legacyCloudOffMigratesToOnDevice() throws {
    let config = try decodeConfig(#"{"outputPath":"/tmp/x","appDataPath":"/tmp/x/d","useCloudSummaries":false}"#)
    #expect(config.aiProvider == .onDevice)
}

@Test func configWithNoAIKeysIsOnDevice() throws {
    let config = try decodeConfig(#"{"outputPath":"/tmp/x","appDataPath":"/tmp/x/d"}"#)
    #expect(config.aiProvider == .onDevice)
    #expect(config.ollamaAddress == "http://localhost:11434")
}

@Test func unknownProviderDecodesAsOnDevice() throws {
    let config = try decodeConfig(#"{"outputPath":"/tmp/x","appDataPath":"/tmp/x/d","aiProvider":"gemini"}"#)
    #expect(config.aiProvider == .onDevice)
}

@Test func explicitProviderWinsOverLegacyToggle() throws {
    let config = try decodeConfig(#"{"outputPath":"/tmp/x","appDataPath":"/tmp/x/d","aiProvider":"openAI","useCloudSummaries":true}"#)
    #expect(config.aiProvider == .openAI)
}

@Test func aiSettingsRoundTripAndLegacyKeyIsNotWritten() throws {
    var config = ZMeetConfig.default(outputPath: "/tmp/zmeet-output")
    config.aiProvider = .ollama
    config.setModel("llama3.1:8b", for: .ollama)
    config.ollamaAddress = "http://192.168.1.20:11434"
    let data = try JSONEncoder.zmeet.encode(config)
    let decoded = try JSONDecoder.zmeet.decode(ZMeetConfig.self, from: data)
    #expect(decoded == config)
    #expect(decoded.model(for: .ollama) == "llama3.1:8b")
    #expect(!String(decoding: data, as: UTF8.self).contains("useCloudSummaries"))
}

@Test func modelsAreRememberedPerProvider() {
    var config = ZMeetConfig.default(outputPath: "/tmp/zmeet-output")
    config.setModel("gpt-5-mini", for: .openAI)
    config.setModel("qwen3:14b", for: .ollama)
    #expect(config.model(for: .openAI) == "gpt-5-mini")
    #expect(config.model(for: .ollama) == "qwen3:14b")
    #expect(config.model(for: .anthropic) == "claude-sonnet-5")
}

@Test func blankModelFallsBackToProviderDefault() {
    var config = ZMeetConfig.default(outputPath: "/tmp/zmeet-output")
    config.setModel("   ", for: .anthropic)
    #expect(config.model(for: .anthropic) == "claude-sonnet-5")
    config.setModel("  gpt-5  ", for: .openAI)
    #expect(config.model(for: .openAI) == "gpt-5")
}

@Test func providerFacts() {
    #expect(AIProvider.allCases.map(\.displayName) == ["On-device", "Ollama", "OpenAI", "Anthropic"])
    #expect(AIProvider.onDevice.secretAccount == nil)
    #expect(AIProvider.anthropic.secretAccount == "anthropic-api-key")
    #expect(AIProvider.openAI.secretAccount == "openai-api-key")
    #expect(AIProvider.ollama.secretAccount == "ollama-api-key")
    #expect(AIProvider.openAI.requiresKey && AIProvider.anthropic.requiresKey)
    #expect(!AIProvider.ollama.requiresKey && !AIProvider.onDevice.requiresKey)
    #expect(AIProvider.onDevice.chunkBudget == 10_000)
    #expect(AIProvider.ollama.chunkBudget == 8_000)
    #expect(AIProvider.openAI.chunkBudget == nil)
    #expect(AIProvider.anthropic.chunkBudget == nil)
}
