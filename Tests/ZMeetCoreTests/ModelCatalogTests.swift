import Foundation
import Testing
@testable import ZMeetCore

@Test func parsesOllamaTagsInServerOrder() throws {
    let data = Data(#"{"models":[{"name":"llama3.1:8b","size":1},{"name":"qwen3:14b"}]}"#.utf8)
    #expect(try ModelCatalog.parseOllamaTags(data) == ["llama3.1:8b", "qwen3:14b"])
}

@Test func parsesEmptyOllamaServer() throws {
    #expect(try ModelCatalog.parseOllamaTags(Data(#"{"models":[]}"#.utf8)) == [])
}

@Test func filtersAndSortsOpenAIModelsNewestFirst() throws {
    let data = Data("""
    {"data":[
      {"id":"gpt-4o","created":100},
      {"id":"whisper-1","created":500},
      {"id":"gpt-5-mini","created":300},
      {"id":"gpt-4o-audio-preview","created":400},
      {"id":"text-embedding-3-large","created":450},
      {"id":"o3","created":200},
      {"id":"dall-e-3","created":600},
      {"id":"gpt-4o-realtime-preview","created":350},
      {"id":"omni-moderation-latest","created":360}
    ]}
    """.utf8)
    #expect(try ModelCatalog.parseOpenAIModels(data) == ["gpt-5-mini", "o3", "gpt-4o"])
}

@Test func openAIChatModelFilter() {
    #expect(ModelCatalog.isOpenAIChatModel("gpt-5"))
    #expect(ModelCatalog.isOpenAIChatModel("o4-mini"))
    #expect(ModelCatalog.isOpenAIChatModel("chatgpt-4o-latest"))
    #expect(!ModelCatalog.isOpenAIChatModel("gpt-image-1"))
    #expect(!ModelCatalog.isOpenAIChatModel("gpt-4o-mini-tts"))
    #expect(!ModelCatalog.isOpenAIChatModel("gpt-4o-transcribe"))
    #expect(!ModelCatalog.isOpenAIChatModel("gpt-4o-search-preview"))
    #expect(!ModelCatalog.isOpenAIChatModel("davinci-002"))
}

@Test func parsesAnthropicModelsInOrder() throws {
    let data = Data(#"{"data":[{"id":"claude-sonnet-5","type":"model"},{"id":"claude-haiku-4-5-20251001"}],"has_more":false}"#.utf8)
    #expect(try ModelCatalog.parseAnthropicModels(data) == ["claude-sonnet-5", "claude-haiku-4-5-20251001"])
}

@Test func malformedModelListsThrowDecode() {
    #expect(throws: AIProviderError.decode) { try ModelCatalog.parseOllamaTags(Data("nope".utf8)) }
    #expect(throws: AIProviderError.decode) { try ModelCatalog.parseOpenAIModels(Data(#"{"models":[]}"#.utf8)) }
    #expect(throws: AIProviderError.decode) { try ModelCatalog.parseAnthropicModels(Data("[]".utf8)) }
}

@Test func containsMatchesExactNames() {
    #expect(ModelCatalog.contains(["gpt-5", "o3"], model: "o3"))
    #expect(!ModelCatalog.contains(["gpt-5"], model: "gpt-5-mini"))
}

@Test func containsTreatsMissingTagAsLatest() {
    #expect(ModelCatalog.contains(["llama3.1:latest"], model: "llama3.1"))
    #expect(!ModelCatalog.contains(["llama3.1:8b"], model: "llama3.1"))
}

@Test func ollamaTagsRequestCarriesOptionalKey() throws {
    let plain = try #require(ModelCatalog.makeOllamaTagsRequest(address: "localhost:11434", key: nil))
    #expect(plain.url?.absoluteString == "http://localhost:11434/api/tags")
    #expect(plain.httpMethod == "GET")
    #expect(plain.value(forHTTPHeaderField: "Authorization") == nil)
    let keyed = try #require(ModelCatalog.makeOllamaTagsRequest(address: "localhost:11434", key: "secret"))
    #expect(keyed.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
    #expect(ModelCatalog.makeOllamaTagsRequest(address: "", key: nil) == nil)
}
