import Foundation

/// Normalizes and validates notes returned by a non-Apple model before they are
/// saved. Catches broken structure, not weak content.
public enum SummaryOutput {
    /// Headings every note must carry wherever its topic sections fall; the
    /// note must also open with `## Summary` and have one other section.
    public static let anchorHeaders = ["## Decisions", "## Action Items"]

    /// Strips a leading `<think>…</think>` block (reasoning models such as qwen3
    /// or deepseek-r1 emit one) and a single outer code fence (small models
    /// often wrap the whole answer), then trims whitespace.
    public static func clean(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("<think>") {
            // An unclosed block means the reply was cut off mid-reasoning: there
            // is no answer, and the reasoning must never become a title.
            guard let end = text.range(of: "</think>") else { return "" }
            text = String(text[end.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var lines = text.components(separatedBy: "\n")
        if lines.count >= 2,
           lines[0].trimmingCharacters(in: .whitespaces).hasPrefix("```"),
           lines[lines.count - 1].trimmingCharacters(in: .whitespaces) == "```" {
            lines.removeFirst()
            lines.removeLast()
            text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return renamingTranscriptHeadings(droppingLeadingTitle(text))
    }

    /// The note template writes its own `# Title`; models (OpenAI and Ollama
    /// especially) often prefix one, which would fail the `## Summary` anchor.
    private static func droppingLeadingTitle(_ text: String) -> String {
        guard text.hasPrefix("# ") else { return text }
        return text.drop { $0 != "\n" }.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// notes.md readers stop at a `## Transcript` line (the link section), so a
    /// model-written one would cut the notes off there.
    private static func renamingTranscriptHeadings(_ text: String) -> String {
        text.components(separatedBy: "\n").map { line in
            line.trimmingCharacters(in: .whitespaces).lowercased() == "## transcript"
                ? "## Transcript Discussion" : line
        }.joined(separator: "\n")
    }

    /// Whether the note opens with `## Summary`, has `## Decisions` and
    /// `## Action Items` on their own lines, and at least one other `## `
    /// section. Case-insensitive, since some models write "## Action items".
    /// Older four-section notes (Key Points) pass too.
    public static func hasRequiredSections(_ markdown: String) -> Bool {
        let lines = markdown.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard lines.first?.lowercased() == "## summary" else { return false }
        let h2 = Set(lines.filter { $0.hasPrefix("## ") }.map { $0.lowercased() })
        let anchors = Set((["## Summary"] + anchorHeaders).map { $0.lowercased() })
        return anchors.isSubset(of: h2) && !h2.subtracting(anchors).isEmpty
    }
}
