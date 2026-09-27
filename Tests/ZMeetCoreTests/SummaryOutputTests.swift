import Testing
@testable import ZMeetCore

private let valid = """
## Summary
We met.

## Key Points
- A

## Action Items
- None

## Decisions
- B
"""

@Test func validNoteHasRequiredSections() {
    #expect(SummaryOutput.hasRequiredSections(valid))
}

@Test func missingSectionFailsCheck() {
    let noDecisions = valid.replacingOccurrences(of: "## Decisions", with: "## Outcomes")
    #expect(!SummaryOutput.hasRequiredSections(noDecisions))
}

@Test func outOfOrderSectionsFailCheck() {
    let swapped = "## Key Points\n- A\n\n## Summary\nWe met.\n\n## Action Items\n- None\n\n## Decisions\n- B"
    #expect(!SummaryOutput.hasRequiredSections(swapped))
}

@Test func headerMustBeItsOwnLine() {
    let inline = "See ## Summary here\n## Key Points\n## Action Items\n## Decisions"
    #expect(!SummaryOutput.hasRequiredSections(inline))
}

@Test func headerCaseIsTolerated() {
    let lower = valid.replacingOccurrences(of: "## Key Points", with: "## Key points")
    #expect(SummaryOutput.hasRequiredSections(lower))
}

@Test func cleanStripsLeadingThinkBlock() {
    let raw = "<think>\nThe user wants notes. Let me plan...\n</think>\n\n" + valid
    let cleaned = SummaryOutput.clean(raw)
    #expect(cleaned == valid)
    #expect(!cleaned.contains("Let me plan"))
}

@Test func cleanUnwrapsOuterMarkdownFence() {
    #expect(SummaryOutput.clean("```markdown\n" + valid + "\n```") == valid)
    #expect(SummaryOutput.clean("```\n" + valid + "\n```\n") == valid)
}

@Test func cleanLeavesInnerFencesAlone() {
    let withCode = valid + "\n\n```\nlet x = 1\n```"
    #expect(SummaryOutput.clean(withCode) == withCode)
}

@Test func cleanTrimsWhitespace() {
    #expect(SummaryOutput.clean("\n\n  " + valid + "  \n") == valid)
}
