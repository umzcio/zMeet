import Foundation

/// Normalizes and validates notes returned by a non-Apple model before they are
/// saved. Catches broken structure, not weak content.
public enum SummaryOutput {
    /// The four sections `MeetingSummaryPrompt` asks for, in order.
    public static let requiredHeaders = ["## Summary", "## Key Points", "## Action Items", "## Decisions"]

    /// Strips a leading `<think>…</think>` block (reasoning models such as qwen3
    /// or deepseek-r1 emit one) and a single outer code fence (small models
    /// often wrap the whole answer), then trims whitespace.
    public static func clean(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("<think>"), let end = text.range(of: "</think>") {
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
        return text
    }

    /// Whether all four headers appear, each on its own line, in order.
    /// Case-insensitive, since some models write "## Key points".
    public static func hasRequiredSections(_ markdown: String) -> Bool {
        let wanted = requiredHeaders.map { $0.lowercased() }
        var next = 0
        for line in markdown.components(separatedBy: "\n") where next < wanted.count {
            if line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == wanted[next] {
                next += 1
            }
        }
        return next == wanted.count
    }
}
