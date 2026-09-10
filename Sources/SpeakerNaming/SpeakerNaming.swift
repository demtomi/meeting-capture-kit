import Foundation

/// Pure transcript speaker-relabeling.
///
/// THE TRANSCRIPT GRAMMAR IS PART OF THE CONTRACT, so it is written out here rather
/// than left to a document. Two line shapes carry a speaker, and only these two are
/// ever rewritten:
///
///     frontmatter participant   "  - Speaker 1 (remote)"
///                               "  - Speaker 1 (in-person)"
///     body utterance            "5   [00:00:15] Speaker 2: some text"
///
/// A body utterance is an index, whitespace, a bracketed `HH:MM:SS`, whitespace, the
/// speaker slot, a colon, a space, then the text. Anything else is left alone. If you
/// generate transcripts with your own tool and want this library to relabel them, match
/// those two shapes exactly.
///
/// Renames `Speaker N` tokens in the two positions they legitimately appear —
/// the frontmatter `participants` list and each body utterance's speaker slot —
/// and nowhere else. `Speaker N` that happens to occur inside utterance text is
/// left untouched (anchored replacement, not a global string swap). The host
/// label (mic track, e.g. "Host") is never a `Speaker N`, so it is never renamed.
///
/// String-in / string-out so it is unit-testable without touching the filesystem;
/// the app reads and writes the file around these calls.
public enum SpeakerNaming {

    // Frontmatter participant line:  "  - Speaker 1 (remote)" (virtual call)
    // or "  - Speaker 1 (in-person)" (mic-multi in-person diarization).
    private static let participant = try! NSRegularExpression(
        pattern: #"^(\s*-\s+)(Speaker \d+)( \((?:remote|in-person)\)\s*)$"#)

    // Body utterance line:  "5   [00:00:15] Speaker 2: text..."
    private static let utterance = try! NSRegularExpression(
        pattern: #"^(\d+\s+\[\d{2}:\d{2}:\d{2}\]\s+)(Speaker \d+)(:\s.*)$"#)

    private static let matchers = [participant, utterance]

    /// Distinct `Speaker N` tokens, in first-appearance order (frontmatter first,
    /// so they come out `Speaker 1, Speaker 2, …`).
    public static func detect(in text: String) -> [String] {
        var seen = Set<String>()
        var order = [String]()
        for line in text.components(separatedBy: "\n") {
            guard let tok = speaker(in: line) else { continue }
            if seen.insert(tok).inserted { order.append(tok) }
        }
        return order
    }

    /// Rewrite `text`, replacing each `Speaker N` with its mapped, sanitized name.
    /// Blank or unmapped speakers are left as-is. Indices, timestamps and spacing
    /// are preserved exactly — only the speaker token in the slot changes.
    public static func apply(_ names: [String: String], to text: String) -> String {
        let clean = names.reduce(into: [String: String]()) { acc, kv in
            if let v = sanitize(kv.value) { acc[kv.key] = v }
        }
        guard !clean.isEmpty else { return text }

        let rewritten = text.components(separatedBy: "\n").map { line -> String in
            guard let (tok, range) = slot(in: line) else { return line }
            guard let name = clean[tok] else { return line }
            return line.replacingCharacters(in: range, with: name)
        }
        return rewritten.joined(separator: "\n")
    }

    /// The `Speaker N` token in a line's speaker slot, or nil.
    static func speaker(in line: String) -> String? { slot(in: line)?.0 }

    /// The speaker token plus the range it occupies, or nil if this line has no slot.
    private static func slot(in line: String) -> (String, Range<String.Index>)? {
        let full = NSRange(line.startIndex..., in: line)
        for re in matchers {
            guard let m = re.firstMatch(in: line, range: full), m.numberOfRanges == 4,
                  let r = Range(m.range(at: 2), in: line) else { continue }
            return (String(line[r]), r)
        }
        return nil
    }

    /// A name is usable if, after trimming, it is non-empty and contains no `:`
    /// or newline (either would corrupt the downstream `Name: text` parse).
    /// Returns nil to mean "skip this speaker, leave the token as-is".
    static func sanitize(_ raw: String) -> String? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !t.contains(":"), !t.contains("\n") else { return nil }
        return t
    }
}
