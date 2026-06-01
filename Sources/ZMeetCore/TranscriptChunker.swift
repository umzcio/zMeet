import Foundation

/// Splits a transcript into size-bounded chunks for map-reduce summarization, and
/// batches already-summarized parts for hierarchical reduction. Pure / Sendable.
public struct TranscriptChunker: Sendable {
    public init() {}

    /// Chunks no longer than `maxCharacters`, preferring paragraph → word
    /// boundaries; only a single word longer than the limit is hard-split. Returns
    /// `[]` for blank input and `[text]` when the whole thing fits.
    public func chunk(_ text: String, maxCharacters: Int) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        guard trimmed.count > maxCharacters else { return [trimmed] }

        var chunks: [String] = []
        var current = ""
        func append(_ unit: String, sep: String) {
            if current.isEmpty {
                current = unit
            } else if current.count + sep.count + unit.count <= maxCharacters {
                current += sep + unit
            } else {
                chunks.append(current)
                current = unit
            }
        }
        for paragraph in trimmed.components(separatedBy: "\n\n") {
            let para = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
            if para.isEmpty { continue }
            if para.count <= maxCharacters {
                append(para, sep: "\n\n")
            } else {
                for unit in Self.splitToFit(para, maxCharacters: maxCharacters) {
                    append(unit, sep: " ")
                }
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    private static func splitToFit(_ text: String, maxCharacters: Int) -> [String] {
        var pieces: [String] = []
        var current = ""
        for word in text.split(separator: " ", omittingEmptySubsequences: true) {
            let w = String(word)
            if w.count > maxCharacters {
                if !current.isEmpty { pieces.append(current); current = "" }
                var rest = Substring(w)
                while rest.count > maxCharacters {
                    pieces.append(String(rest.prefix(maxCharacters)))
                    rest = rest.dropFirst(maxCharacters)
                }
                if !rest.isEmpty { current = String(rest) }
            } else if current.isEmpty {
                current = w
            } else if current.count + 1 + w.count <= maxCharacters {
                current += " " + w
            } else {
                pieces.append(current)
                current = w
            }
        }
        if !current.isEmpty { pieces.append(current) }
        return pieces
    }

    /// Greedily batches `parts` so each batch's joined length (with `separator`)
    /// is <= maxCharacters; an oversized single part gets its own batch.
    public func group(_ parts: [String], maxCharacters: Int, separator: String = "\n\n") -> [[String]] {
        func joinedLen(_ arr: [String]) -> Int {
            arr.isEmpty ? 0 : arr.reduce(0) { $0 + $1.count } + separator.count * (arr.count - 1)
        }
        var groups: [[String]] = []
        var current: [String] = []
        for part in parts {
            if !current.isEmpty, joinedLen(current + [part]) > maxCharacters {
                groups.append(current)
                current = []
            }
            current.append(part)
        }
        if !current.isEmpty { groups.append(current) }
        return groups
    }
}
