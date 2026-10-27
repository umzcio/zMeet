import Testing
@testable import ZMeetCore

struct SummaryOutputAnchorTests {
    private let newFormat = """
    ## Summary
    The deal closed.

    **On the call:** Pat (lead), Sam.

    ## Deal Terms
    - $12M over five years

    ## Timeline
    - Signing in June

    ## Decisions
    - Proceed

    ## Action Items
    - Sam: send the term sheet

    ## Open Questions & Checks
    - None
    """

    @Test func newFormatNotesPass() {
        #expect(SummaryOutput.hasRequiredSections(newFormat))
    }

    @Test func fourSectionNotesStillPass() {
        let old = "## Summary\nWe met.\n\n## Key Points\n- A\n\n## Action Items\n- None\n\n## Decisions\n- B"
        #expect(SummaryOutput.hasRequiredSections(old))
    }

    @Test func summaryMustComeFirst() {
        let md = "## Deal Terms\n- x\n\n" + newFormat
        #expect(!SummaryOutput.hasRequiredSections(md))
    }

    @Test func missingDecisionsFails() {
        #expect(!SummaryOutput.hasRequiredSections(newFormat.replacingOccurrences(of: "## Decisions", with: "## Outcomes")))
    }

    @Test func missingActionItemsFails() {
        #expect(!SummaryOutput.hasRequiredSections(newFormat.replacingOccurrences(of: "## Action Items", with: "## Next")))
    }

    @Test func onlyTheAnchorsFails() {
        let md = "## Summary\nWe met.\n\n## Decisions\n- None\n\n## Action Items\n- None"
        #expect(!SummaryOutput.hasRequiredSections(md))
    }

    @Test func headingMatchIsCaseInsensitive() {
        let md = newFormat
            .replacingOccurrences(of: "## Action Items", with: "## action items")
            .replacingOccurrences(of: "## Decisions", with: "## DECISIONS")
        #expect(SummaryOutput.hasRequiredSections(md))
    }

    @Test func cleanRenamesAModelWrittenTranscriptHeading() {
        let cleaned = SummaryOutput.clean("## Summary\nx\n## Transcript\ny\n  ## transcript  \nz")
        #expect(cleaned.contains("## Transcript Discussion"))
        let lines = cleaned.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        #expect(!lines.contains("## transcript"))
    }
}
