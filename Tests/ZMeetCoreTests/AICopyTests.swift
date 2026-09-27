import Foundation
import Testing
@testable import ZMeetCore

@Test func privacyNoteNamesWhereTranscriptsGo() {
    #expect(AICopy.privacyNote(provider: .onDevice, ollamaAddress: "") == "Everything stays on this Mac.")
    #expect(AICopy.privacyNote(provider: .ollama, ollamaAddress: "http://localhost:11434")
            == "Transcripts go to Ollama on this Mac. Nothing leaves your computer.")
    #expect(AICopy.privacyNote(provider: .ollama, ollamaAddress: "http://127.0.0.1:11434")
            == "Transcripts go to Ollama on this Mac. Nothing leaves your computer.")
    #expect(AICopy.privacyNote(provider: .ollama, ollamaAddress: "192.168.1.20:11434")
            == "Transcripts go to your Ollama server at 192.168.1.20 on your network.")
    #expect(AICopy.privacyNote(provider: .ollama, ollamaAddress: "")
            == "Enter your Ollama server's address.")
    let openAI = AICopy.privacyNote(provider: .openAI, ollamaAddress: "")
    #expect(openAI.contains("sent to OpenAI"))
    #expect(openAI.contains("auto-titles"))
    #expect(openAI.contains("backfill"))
    #expect(openAI.contains("Your audio always stays on your Mac."))
    #expect(AICopy.privacyNote(provider: .anthropic, ollamaAddress: "").contains("sent to Anthropic"))
}

@Test func backfillWarningOnlyWhenTextLeavesTheMac() {
    #expect(AICopy.backfillWarning(provider: .onDevice, ollamaAddress: "") == nil)
    #expect(AICopy.backfillWarning(provider: .ollama, ollamaAddress: "http://localhost:11434") == nil)
    #expect(AICopy.backfillWarning(provider: .ollama, ollamaAddress: "http://192.168.1.20:11434")
            == " Entity extraction sends each published meeting's text to your Ollama server at 192.168.1.20.")
    #expect(AICopy.backfillWarning(provider: .anthropic, ollamaAddress: "")
            == " Entity extraction sends each published meeting's text to Anthropic.")
}

@Test func failureMessagesPerErrorAndProvider() {
    #expect(AICopy.failureMessage(AIProviderError.missingKey, provider: .openAI) == "No API key saved.")
    #expect(AICopy.failureMessage(AIProviderError.http(status: 401), provider: .anthropic) == "Key rejected (401).")
    #expect(AICopy.failureMessage(AIProviderError.http(status: 404), provider: .ollama)
            == "No Ollama server answered at that address (HTTP 404).")
    #expect(AICopy.failureMessage(AIProviderError.http(status: 500), provider: .openAI) == "Request failed (HTTP 500).")
    #expect(AICopy.failureMessage(AIProviderError.network, provider: .ollama)
            == "Couldn't reach Ollama at that address. Is it running?")
    #expect(AICopy.failureMessage(AIProviderError.network, provider: .openAI) == "Network error — check your connection.")
    #expect(AICopy.failureMessage(AIProviderError.decode, provider: .ollama) == "Unexpected response from Ollama.")
}

@Test func connectionCheckRequiresTheChosenModel() {
    #expect(AICopy.connectionCheck(models: ["llama3.1:latest"], model: "llama3.1", provider: .ollama)
            == (true, "Connected. llama3.1 is available."))
    let missing = AICopy.connectionCheck(models: ["gpt-5"], model: "gpt-9", provider: .openAI)
    #expect(missing.ok == false)
    #expect(missing.message == "Connected, but OpenAI has no model named “gpt-9”.")
    let none = AICopy.connectionCheck(models: ["gpt-5"], model: "  ", provider: .openAI)
    #expect(none == (false, "Connected, but no model is chosen yet."))
}

@Test func fallbackNoticeNamesProvider() {
    #expect(AICopy.fallbackNotice(provider: .ollama)
            == "Ollama summary failed — this meeting's notes were generated on-device. Check Settings → AI.")
}

@Test func notConfiguredNoticeNamesProvider() {
    #expect(AICopy.notConfiguredNotice(provider: .openAI)
            == "OpenAI isn't set up yet, so this meeting's notes were generated on-device. Finish setup in Settings → AI.")
}
