import Foundation
import Testing
@testable import ZMeetCore

/// Records every prompt and answers map prompts and reduce prompts separately.
private final class FakeModel: @unchecked Sendable {
    private let lock = NSLock()
    private var log: [String] = []
    let mapAnswer: String
    let reduceAnswer: String
    init(mapAnswer: String = "## Summary\n- part", reduceAnswer: String = "FINAL") {
        self.mapAnswer = mapAnswer
        self.reduceAnswer = reduceAnswer
    }
    var prompts: [String] { lock.withLock { log } }
    var reducePrompts: [String] { prompts.filter { $0.contains("combining notes") } }
    var mapPrompts: [String] { prompts.filter { !$0.contains("combining notes") } }
    var complete: MapReduceSummarizer.Complete {
        { [self] prompt in
            lock.withLock { log.append(prompt) }
            return prompt.contains("combining notes") ? reduceAnswer : mapAnswer
        }
    }
}

private func paragraphs(_ count: Int, length: Int) -> String {
    (0..<count).map { i in String(repeating: Character(String(i)), count: length) }.joined(separator: "\n\n")
}

@Test func shortTranscriptIsOneCall() async throws {
    let model = FakeModel(mapAnswer: "ONLY")
    let out = try await MapReduceSummarizer(maxChunkCharacters: 1_000, complete: model.complete)
        .summarize(transcript: "We shipped it.", title: "Sync")
    #expect(out == "ONLY")
    #expect(model.prompts.count == 1)
    #expect(model.prompts[0].contains("We shipped it."))
}

@Test func longTranscriptMapsEachChunkThenReduces() async throws {
    // Short map answers so all three parts fit one reduce pass under the budget.
    let model = FakeModel(mapAnswer: "- p")
    let out = try await MapReduceSummarizer(maxChunkCharacters: 50, complete: model.complete)
        .summarize(transcript: paragraphs(3, length: 40), title: "Sync")
    #expect(out == "FINAL")
    #expect(model.mapPrompts.count == 3)
    #expect(model.reducePrompts.count == 1)
    #expect(model.reducePrompts[0].contains("### Part 3"))
}

@Test func largeReduceRunsInRounds() async throws {
    // Four 30-char map answers under a 70-char budget → two groups of two, then a
    // final pass over the two short reduced parts.
    let model = FakeModel(mapAnswer: String(repeating: "m", count: 30), reduceAnswer: "R")
    let out = try await MapReduceSummarizer(maxChunkCharacters: 70, complete: model.complete)
        .summarize(transcript: paragraphs(4, length: 60), title: "Sync")
    #expect(out == "R")
    #expect(model.mapPrompts.count == 4)
    #expect(model.reducePrompts.count == 3)
}

@Test func mapAnswersAreCleanedBeforeReduce() async throws {
    let model = FakeModel(mapAnswer: "<think>secret reasoning</think>\n## Summary\n- a")
    _ = try await MapReduceSummarizer(maxChunkCharacters: 50, complete: model.complete)
        .summarize(transcript: paragraphs(2, length: 40), title: "Sync")
    #expect(model.reducePrompts.count == 1)
    #expect(!model.reducePrompts[0].contains("secret reasoning"))
}

@Test func completionErrorsPropagate() async {
    struct Boom: Error {}
    let summarizer = MapReduceSummarizer(maxChunkCharacters: 50) { _ in throw Boom() }
    await #expect(throws: Boom.self) {
        _ = try await summarizer.summarize(transcript: "hi", title: "Sync")
    }
}

@Test func singlePassClipsTheTranscript() async throws {
    let model = FakeModel(mapAnswer: "ONE")
    let transcript = String(repeating: "a", count: 10) + String(repeating: "b", count: 10)
    let out = try await SinglePassSummarizer(maxTranscriptCharacters: 10, complete: model.complete)
        .summarize(transcript: transcript, title: "Sync")
    #expect(out == "ONE")
    #expect(model.prompts.count == 1)
    #expect(model.prompts[0].contains("aaaaaaaaaa"))
    #expect(!model.prompts[0].contains("bbbbb"))   // the prompt template itself contains the letter b
}
