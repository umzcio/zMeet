import Testing
@testable import ZMeetCore

private func seg(_ text: String, _ start: Double, _ end: Double? = nil) -> TranscriptSegment {
    TranscriptSegment(text: text, start: start, end: end)
}

/// `count` sentences of exactly 100 characters each ("S07 xxx…x.").
private func sentences(_ count: Int) -> [String] {
    (0..<count).map { i in
        let head = "S" + String(format: "%02d", i) + " "
        return head + String(repeating: "x", count: 100 - head.count - 1) + "."
    }
}

@Test func timestampsUseMinutesUnderAnHourAndHoursAbove() {
    #expect(TranscriptFormatter.timestamp(0) == "0:00")
    #expect(TranscriptFormatter.timestamp(5.9) == "0:05")
    #expect(TranscriptFormatter.timestamp(754) == "12:34")
    #expect(TranscriptFormatter.timestamp(3599.9) == "59:59")
    #expect(TranscriptFormatter.timestamp(3735) == "1:02:15")
    #expect(TranscriptFormatter.timestamp(-3) == "0:00")
}

@Test func startsAParagraphAfterAPauseOfTwoSeconds() {
    let out = TranscriptFormatter().format([
        seg("Hello there.", 0, 1),
        seg("How are you?", 1.5, 3),     // 0.5 s pause: same paragraph
        seg("Next topic.", 5, 6),        // exactly 2.0 s pause: new paragraph
    ])
    #expect(out == "[0:00] Hello there. How are you?\n\n[0:05] Next topic.")
}

@Test func breaksBeforeAParagraphWouldPassTheMaxLength() {
    // Twelve contiguous 100-character segments: five fit (5×100 + 4 spaces = 504),
    // a sixth would make 605 > 600, so paragraphs hold 5, 5 and 2 segments.
    let parts = sentences(12)
    let segments = parts.enumerated().map { seg($1, Double($0) * 6, Double($0) * 6 + 5.9) }
    let paragraphs = TranscriptFormatter().format(segments).components(separatedBy: "\n\n")
    #expect(paragraphs.count == 3)
    #expect(paragraphs[0] == "[0:00] " + parts[0..<5].joined(separator: " "))
    #expect(paragraphs[1] == "[0:30] " + parts[5..<10].joined(separator: " "))
    #expect(paragraphs[2] == "[1:00] " + parts[10..<12].joined(separator: " "))
}

@Test func splitsAnOverlongSegmentAtSentenceEnds() {
    // One 1 514-character segment (fifteen 100-character sentences) spanning 10–160 s.
    let parts = sentences(15)
    let out = TranscriptFormatter().format([seg(parts.joined(separator: " "), 10, 160)])
    let paragraphs = out.components(separatedBy: "\n\n")
    #expect(paragraphs.count == 3)
    #expect(paragraphs[0] == "[0:10] " + parts[0..<5].joined(separator: " "))
    #expect(paragraphs[1].hasSuffix(parts[5..<10].joined(separator: " ")))
    #expect(paragraphs[2].hasSuffix(parts[10..<15].joined(separator: " ")))
    // Each chunk's timestamp sits where its first sentence falls in the segment,
    // by character position: 505/1514 of 150 s ≈ 60 s, 1010/1514 ≈ 110 s.
    #expect(paragraphs[1].hasPrefix("[1:00] "))
    #expect(paragraphs[2].hasPrefix("[1:50] "))
}

@Test func keepsAnOverlongSentenceWhole() {
    let long = String(repeating: "word ", count: 160) + "end"   // 803 characters, no sentence end inside
    let out = TranscriptFormatter().format([seg(long, 0, 40)])
    #expect(out == "[0:00] " + long)
}

@Test func labelsEachParagraphWithItsSpeakerAndBreaksOnSpeakerChange() {
    let out = TranscriptFormatter().format(labelled: [
        ("You", [seg("I think so.", 0, 1), seg("Yes.", 6, 7)]),
        ("Others", [seg("Do you agree?", 1.2, 2)]),
    ])
    #expect(out == "**You:** [0:00] I think so.\n\n**Others:** [0:01] Do you agree?\n\n**You:** [0:06] Yes.")
}

@Test func trimsWhitespaceAndSkipsBlankSegments() {
    #expect(TranscriptFormatter().format([seg("  \n", 0), seg("  hello\n", 1, 2), seg("world ", 2.5, 3)])
            == "[0:01] hello world")
    #expect(TranscriptFormatter().format([]) == "")
    #expect(TranscriptFormatter().format([seg("   ", 0, 1)]) == "")
}

@Test func ordersSegmentsByStartTime() {
    let out = TranscriptFormatter().format([seg("Second.", 10, 11), seg("First.", 0, 1)])
    #expect(out == "[0:00] First.\n\n[0:10] Second.")
}
