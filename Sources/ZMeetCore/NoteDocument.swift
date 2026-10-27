import Foundation

/// A parsed notes.md document, as the Library reader renders it. One of three
/// consumers of the notes.md format (with MarkdownRenderer.summaryBody and
/// ZMeetText.noteSearchBody) — kept behavior-identical to the reader's parser
/// and characterized by NoteFormatCorpusTests until the planned unification.
public enum NoteElement: Equatable {
    case h2(String)
    case h3(String)
    case bullet(String)
    case paragraph(String)
    /// A GitHub-style pipe table: header cells plus rows of the same width.
    case table(header: [String], rows: [[String]])
}

public enum NoteDocument {
    /// Parses a notes.md document into renderable elements. Strips YAML frontmatter,
    /// the leading `# Title` (shown in the header), and the trailing transcript
    /// link section (the Transcript tab covers it).
    public static func parse(_ raw: String) -> [NoteElement] {
        var lines = raw.components(separatedBy: "\n")

        // Drop YAML frontmatter.
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---" {
            if let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) {
                lines = Array(lines[(end + 1)...])
            }
        }

        var blocks: [NoteElement] = []
        var i = 0
        while i < lines.count {
            let t = lines[i].trimmingCharacters(in: .whitespaces)
            i += 1
            if t.isEmpty { continue }
            if isPipeRow(t) {
                // Gather the run of consecutive pipe rows; it is a table only if
                // well-formed, otherwise each row stays a plain paragraph.
                var run = [t]
                while i < lines.count, case let next = lines[i].trimmingCharacters(in: .whitespaces), isPipeRow(next) {
                    run.append(next); i += 1
                }
                blocks += table(from: run).map { [$0] } ?? run.map { .paragraph($0) }
                continue
            }
            if t.hasPrefix("# ") { continue } // title shown in header
            if t.lowercased() == "## transcript" { break } // tab covers the transcript
            if t.hasPrefix("### ") {
                blocks.append(.h3(String(t.dropFirst(4))))
            } else if t.hasPrefix("## ") {
                blocks.append(.h2(String(t.dropFirst(3))))
            } else if t.hasPrefix("- ") || t.hasPrefix("* ") {
                let item = String(t.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                if !item.isEmpty { blocks.append(.bullet(item)) }
            } else {
                blocks.append(.paragraph(t))
            }
        }
        return blocks
    }

    private static func isPipeRow(_ t: String) -> Bool {
        t.count >= 2 && t.hasPrefix("|") && t.hasSuffix("|")
    }

    private static func cells(_ row: String) -> [String] {
        row.dropFirst().dropLast()
            .split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// A header row, a `|---|:--:|` separator of the same width, then data rows
    /// of that width. Anything ragged returns nil.
    private static func table(from run: [String]) -> NoteElement? {
        guard run.count >= 2 else { return nil }
        let header = cells(run[0])
        let separator = cells(run[1])
        let isSeparator = separator.allSatisfy { cell in
            cell.contains("-") && cell.allSatisfy { $0 == "-" || $0 == ":" || $0 == " " }
        }
        guard isSeparator, separator.count == header.count else { return nil }
        let rows = run.dropFirst(2).map(cells)
        guard rows.allSatisfy({ $0.count == header.count }) else { return nil }
        return .table(header: header, rows: rows)
    }
}
