import Foundation
import ZMeetCore

/// Network I/O for the selected provider. Request-building and parsing live in
/// Core (AnthropicSummary, OpenAIChat, ModelCatalog); this only sends.
extension AIConnection {
    /// One prompt → text.
    func complete(prompt: String) async throws -> String {
        let request: URLRequest
        switch provider {
        case .onDevice:
            // `AIConnection.current` never returns on-device; callers use FoundationModels.
            throw AIProviderError.decode
        case .anthropic:
            guard let key, !key.isEmpty else { throw AIProviderError.missingKey }
            request = try AnthropicSummary.makeRequest(key: key, model: model, prompt: prompt)
        case .openAI:
            guard let key, !key.isEmpty else { throw AIProviderError.missingKey }
            request = try OpenAIChat.makeRequest(baseURL: OpenAIChat.openAIBaseURL, key: key, model: model, prompt: prompt)
        case .ollama:
            guard let base = OllamaAddress.chatBaseURL(ollamaAddress) else { throw AIProviderError.network }
            request = try OpenAIChat.makeRequest(baseURL: base, key: key, model: model, prompt: prompt)
        }
        let (data, status) = try await Self.send(request)
        return provider == .anthropic
            ? try AnthropicSummary.parseSummary(data: data, status: status)
            : try OpenAIChat.parseCompletion(data: data, status: status)
    }

    /// The provider's models, for the Settings picker and Test connection.
    /// Zero-token: a list request, never a generation.
    func listModels() async throws -> [String] {
        switch provider {
        case .onDevice:
            return []
        case .anthropic:
            guard let key, !key.isEmpty else { throw AIProviderError.missingKey }
            let (data, status) = try await Self.send(AnthropicSummary.makeValidationRequest(key: key))
            guard status == 200 else { throw AIProviderError.http(status: status) }
            return try ModelCatalog.parseAnthropicModels(data)
        case .openAI:
            guard let key, !key.isEmpty else { throw AIProviderError.missingKey }
            let (data, status) = try await Self.send(OpenAIChat.makeModelsRequest(baseURL: OpenAIChat.openAIBaseURL, key: key))
            guard status == 200 else { throw AIProviderError.http(status: status) }
            return try ModelCatalog.parseOpenAIModels(data)
        case .ollama:
            guard let request = ModelCatalog.makeOllamaTagsRequest(address: ollamaAddress, key: key) else {
                throw AIProviderError.network
            }
            let (data, status) = try await Self.send(request)
            guard status == 200 else { throw AIProviderError.http(status: status) }
            return try ModelCatalog.parseOllamaTags(data)
        }
    }

    private static func send(_ request: URLRequest) async throws -> (Data, Int) {
        do {
            let (data, response) = try await AIHTTP.session.data(for: request)
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        } catch let error as URLError where error.code == .appTransportSecurityRequiresSecureConnection {
            throw AIProviderError.insecureConnectionBlocked
        } catch {
            throw AIProviderError.network
        }
    }
}
