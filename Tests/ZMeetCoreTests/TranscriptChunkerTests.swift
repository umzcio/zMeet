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

@Test func groupOfSmallPartsConvergesToOneBatch() {
    // Parts small relative to the budget pack into a single batch immediately.
    let chunker = TranscriptChunker()
    let parts = (1...40).map { "p\($0)" }
    let groups = chunker.group(parts, maxCharacters: 200)
    #expect(groups.count == 1)
    #expect(groups.count < parts.count)
}

@Test func groupRegroupingItsOwnOutputCanPlateauWithoutShrinking() {
    // `group` packs each batch as full as the budget allows, so batches from
    // one round are typically too large to combine further in the next —
    // re-grouping already-packed output can return the SAME batch count
    // indefinitely. This is exactly the non-shrinking case
    // MeetingSummarizer.reduce must guard against with a round cap rather
    // than a `while true` loop (Fix 2): `group` alone gives no convergence
    // guarantee across repeated application.
    let chunker = TranscriptChunker()
    let maxCharacters = 20
    let parts = (1...40).map { "part\($0)" }
    #expect(parts.allSatisfy { $0.count <= maxCharacters })

    let firstRound = chunker.group(parts, maxCharacters: maxCharacters)
    #expect(firstRound.count > 1 && firstRound.count < parts.count)

    let repacked = firstRound.map { $0.joined(separator: "\n\n") }
    let secondRound = chunker.group(repacked, maxCharacters: maxCharacters)
    #expect(secondRound.count == firstRound.count)
}
