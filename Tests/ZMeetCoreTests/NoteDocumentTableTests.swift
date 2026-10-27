import Testing
@testable import ZMeetCore

struct NoteDocumentTableTests {
    @Test func parsesAPipeTable() {
        let md = "## Escrow\n| Component | Amount |\n|---|---|\n| Athletics | $50M |\n| Construction | $12M |"
        #expect(NoteDocument.parse(md) == [
            .h2("Escrow"),
            .table(header: ["Component", "Amount"], rows: [["Athletics", "$50M"], ["Construction", "$12M"]]),
        ])
    }

    @Test func alignedSeparatorIsAccepted() {
        let md = "| a | b |\n| :--- | ---: |\n| 1 | 2 |"
        #expect(NoteDocument.parse(md) == [.table(header: ["a", "b"], rows: [["1", "2"]])])
    }

    @Test func tableFollowedByProseEndsTheTable() {
        let md = "| a | b |\n|---|---|\n| 1 | 2 |\nAfter."
        #expect(NoteDocument.parse(md) == [.table(header: ["a", "b"], rows: [["1", "2"]]), .paragraph("After.")])
    }

    @Test func raggedTableFallsBackToParagraphs() {
        let md = "| a | b |\n|---|---|\n| 1 | 2 | 3 |"
        #expect(NoteDocument.parse(md) == [
            .paragraph("| a | b |"), .paragraph("|---|---|"), .paragraph("| 1 | 2 | 3 |"),
        ])
    }

    @Test func lonePipeLineIsAParagraph() {
        #expect(NoteDocument.parse("| just one |") == [.paragraph("| just one |")])
    }

    @Test func tableWithoutSeparatorIsParagraphs() {
        #expect(NoteDocument.parse("| a | b |\n| 1 | 2 |") == [.paragraph("| a | b |"), .paragraph("| 1 | 2 |")])
    }
}
