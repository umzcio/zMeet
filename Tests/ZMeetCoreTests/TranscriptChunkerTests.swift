import Testing
@testable import ZMeetCore

@Test func chunkReturnsSingleForShortTextAndEmptyForBlank() {
    #expect(TranscriptChunker().chunk("hello world", maxCharacters: 100) == ["hello world"])
    #expect(TranscriptChunker().chunk("   ", maxCharacters: 100) == [])
}

@Test func chunkKeepsEveryChunkWithinLimit() {
    let text = (1...80).map { "word\($0)" }.joined(separator: " ")
    let chunks = TranscriptChunker().chunk(text, maxCharacters: 30)
    #expect(chunks.count >= 2)
    #expect(chunks.allSatisfy { $0.count <= 30 })
    #expect(chunks.allSatisfy { !$0.hasPrefix(" ") && !$0.hasSuffix(" ") })
}

@Test func chunkHardSplitsASingleOverlongWord() {
    let text = String(repeating: "a", count: 250)
    let chunks = TranscriptChunker().chunk(text, maxCharacters: 100)
    #expect(chunks.allSatisfy { $0.count <= 100 })
    #expect(chunks.joined().count == 250)
}

@Test func groupBatchesPartsWithinLimit() {
    let groups = TranscriptChunker().group(["aaaa", "bbbb", "cccc"], maxCharacters: 10, separator: "\n")
    #expect(groups == [["aaaa", "bbbb"], ["cccc"]])
}
