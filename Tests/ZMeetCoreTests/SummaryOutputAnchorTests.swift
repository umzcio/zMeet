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

@Test func cleanDropsALeadingModelWrittenTitle() {
    // The note template writes its own `# Title`; a model-added one would fail
    // the "starts with ## Summary" anchor and cost a retry and a fallback.
    let cleaned = SummaryOutput.clean("# Weekly Sync Notes\n\n## Summary\nWe met.\n\n## Plan\n- a\n\n## Decisions\n- None\n\n## Action Items\n- None")
    #expect(cleaned.hasPrefix("## Summary"))
    #expect(SummaryOutput.hasRequiredSections(cleaned))
}

@Test func cleanKeepsALaterHashTitleLine() {
    #expect(SummaryOutput.clean("## Summary\nx\n# Not a lead").contains("# Not a lead"))
}
