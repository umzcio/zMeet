import Foundation

/// Turns timed transcript segments (one per SpeechTranscriber result) into readable
/// Markdown paragraphs, each prefixed with its start time ("[12:34] …").
///
/// A new paragraph starts after a pause of `pauseSeconds` or more, on a speaker
/// change, or before a paragraph would pass `maxParagraphCharacters`. Breaks fall
/// only between segments, or at sentence ends inside a single overlong segment,
/// never mid-sentence. Paragraphs are joined with blank lines, which is what the
/// Library reader and the summary chunker already split on. Pure and Sendable.
public struct TranscriptFormatter: Sendable {
    public var pauseSeconds: TimeInterval
    public var maxParagraphCharacters: Int

    public init(pauseSeconds: TimeInterval = 2, maxParagraphCharacters: Int = 600) {
        self.pauseSeconds = pauseSeconds
        self.maxParagraphCharacters = maxParagraphCharacters
    }

    /// One source, no speaker labels: paragraphs read "[m:ss] text".
    public func format(_ segments: [TranscriptSegment]) -> String {
        render(paragraphs(from: [(nil, segments)]))
    }

    /// Several sources merged by start time; paragraphs read "**Speaker:** [m:ss] text".
    /// Equal start times keep the sources' order (earlier source first).
    public func format(labelled sources: [(speaker: String, segments: [TranscriptSegment])]) -> String {
        render(paragraphs(from: sources.map { (Optional($0.speaker), $0.segments) }))
    }

    /// "m:ss" under an hour, "h:mm:ss" from an hour on. Negative or non-finite → "0:00".
    public static func timestamp(_ seconds: TimeInterval) -> String {
        let total = seconds.isFinite ? max(0, Int(seconds.rounded(.down))) : 0
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    private struct Piece {
        let speaker: String?
        let text: String
        let start: TimeInterval
        let end: TimeInterval
        let source: Int
        let sequence: Int
    }

    private struct Paragraph {
        let speaker: String?
        let start: TimeInterval
        var texts: [String]
        var length: Int
        var end: TimeInterval
    }

    private func paragraphs(from sources: [(String?, [TranscriptSegment])]) -> [Paragraph] {
        var pieces: [Piece] = []
        for (source, (speaker, segments)) in sources.enumerated() {
            for segment in segments {
                let text = segment.text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
                guard !text.isEmpty else { continue }
                let start = segment.start.isFinite ? segment.start : 0
                let end = segment.end.isFinite ? max(segment.end, start) : start
                for chunk in chunks(of: text, start: start, end: end) {
                    pieces.append(Piece(speaker: speaker, text: chunk.text, start: chunk.start, end: chunk.end,
                                        source: source, sequence: pieces.count))
                }
            }
        }
        pieces.sort { ($0.start, $0.source, $0.sequence) < ($1.start, $1.source, $1.sequence) }

        var out: [Paragraph] = []
        for piece in pieces {
            if var last = out.last,
               last.speaker == piece.speaker,
               piece.start - last.end < pauseSeconds,
               last.length + 1 + piece.text.count <= maxParagraphCharacters {
                last.texts.append(piece.text)
                last.length += 1 + piece.text.count
                last.end = max(last.end, piece.end)
                out[out.count - 1] = last
            } else {
                out.append(Paragraph(speaker: piece.speaker, start: piece.start, texts: [piece.text],
                                     length: piece.text.count, end: piece.end))
            }
        }
        return out
    }

    /// Splits a segment longer than the paragraph limit at sentence ends, packing
    /// whole sentences into chunks that fit. A sentence longer than the limit stays
    /// whole. Each chunk's start is placed by its character position in the segment.
    private func chunks(of text: String, start: TimeInterval, end: TimeInterval) -> [(text: String, start: TimeInterval, end: TimeInterval)] {
        guard text.count > maxParagraphCharacters else { return [(text, start, end)] }
        var sentences: [String] = []
        var current = ""
        var previous: Character?
        for character in text {
            if character == " ", let p = previous, ".?!".contains(p) {
                sentences.append(current)
                current = ""
            } else {
                current.append(character)
            }
            previous = character
        }
        if !current.isEmpty { sentences.append(current) }

        var packed: [(text: String, offset: Int)] = []
        var offset = 0
        for sentence in sentences {
            if let last = packed.last, last.text.count + 1 + sentence.count <= maxParagraphCharacters {
                packed[packed.count - 1].text += " " + sentence
            } else {
                packed.append((sentence, offset))
            }
            offset += sentence.count + 1
        }
        let total = Double(text.count)
        let starts = packed.map { start + (end - start) * Double($0.offset) / total }
        return packed.indices.map { i in
            (packed[i].text, starts[i], i + 1 < starts.count ? starts[i + 1] : end)
        }
    }

    private func render(_ paragraphs: [Paragraph]) -> String {
        paragraphs.map { paragraph in
            let body = "[" + Self.timestamp(paragraph.start) + "] " + paragraph.texts.joined(separator: " ")
            return paragraph.speaker.map { "**\($0):** " + body } ?? body
        }.joined(separator: "\n\n")
    }
}
