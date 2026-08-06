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
        for line in lines {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { continue }
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
}
