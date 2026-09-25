// Speech-to-text responses in, one TRANSCRIPT.md-shaped file out. Pure: no I/O, so every
// rule here is checked against canned responses with nothing running.
import Foundation

/// One word from a speech-to-text response. Only `type == "word"` entries are kept.
public struct ScribeWord: Equatable {
    public let text: String
    public let start: Double
    public let end: Double
    public let speakerID: String?
    public init(text: String, start: Double, end: Double, speakerID: String?) {
        self.text = text; self.start = start; self.end = end; self.speakerID = speakerID
    }
}

/// The parts of a speech-to-text response the renderer reads.
public struct ScribeResult: Equatable {
    public let words: [ScribeWord]
    public let languageCode: String?
    public let audioDurationSecs: Double?

    public init(words: [ScribeWord], languageCode: String?, audioDurationSecs: Double?) {
        self.words = words; self.languageCode = languageCode; self.audioDurationSecs = audioDurationSecs
    }

    /// nil when `data` is not a response object with a `words` array.
    public static func parse(_ data: Data) -> ScribeResult? {
        guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return parse(object: o)
    }

    public static func parse(object o: [String: Any]) -> ScribeResult? {
        guard let raw = o["words"] as? [[String: Any]] else { return nil }
        var words: [ScribeWord] = []
        for w in raw where (w["type"] as? String) == "word" {
            guard let t = w["text"] as? String,
                  let s = (w["start"] as? NSNumber)?.doubleValue,
                  let e = (w["end"] as? NSNumber)?.doubleValue else { continue }
            words.append(ScribeWord(text: t, start: s, end: e, speakerID: w["speaker_id"] as? String))
        }
        return ScribeResult(words: words, languageCode: o["language_code"] as? String,
                            audioDurationSecs: (o["audio_duration_secs"] as? NSNumber)?.doubleValue)
    }
}

public struct Utterance: Equatable {
    public let speaker: String
    public let start: Double
    public var end: Double
    public var text: String
}

public struct RenderInput {
    public let manifest: Manifest
    /// Per track ("mic", "system"), the response for every track that was transcribed.
    public let results: [String: ScribeResult]
    /// Per track, whether it was sent with diarization on.
    public let diarized: [String: Bool]
    /// Tracks that held only digital silence and were not uploaded.
    public let silentTracks: [String]
    /// The longest track, in seconds.
    public let durationSeconds: Double

    public init(manifest: Manifest, results: [String: ScribeResult], diarized: [String: Bool],
                silentTracks: [String], durationSeconds: Double) {
        self.manifest = manifest; self.results = results; self.diarized = diarized
        self.silentTracks = silentTracks; self.durationSeconds = durationSeconds
    }
}

public enum Renderer {
    public static let schema = 1
    public static let model = "scribe_v2"
    /// A pause longer than this starts a new utterance even when the speaker is unchanged.
    public static let turnGap = 1.2
    /// A diarized speaker holding less than this share of its track's words is reported.
    public static let phantomShare = 0.005

    /// Labels for a track's speaker ids: `Speaker 1..N` in sorted id order.
    public static func speakerLabels(_ r: ScribeResult) -> [String: String] {
        let ids = Set(r.words.map { $0.speakerID ?? "" }).sorted()
        var out: [String: String] = [:]
        for (i, id) in ids.enumerated() { out[id] = "Speaker \(i + 1)" }
        return out
    }

    public static func hostName(_ m: Manifest) -> String {
        let n = clean(m.tracks["mic"]?.speaker ?? "")
        return n.isEmpty ? "Host" : n
    }

    /// One line, no colon: a speaker label must not be able to fake the `Speaker: text` split.
    static func clean(_ s: String) -> String {
        s.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: ":", with: "").trimmingCharacters(in: .whitespaces)
    }

    static func oneLine(_ s: String) -> String {
        s.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
    }

    /// Every transcribed word, labelled, interleaved by start time and grouped into turns.
    public static func utterances(_ input: RenderInput) -> [Utterance] {
        var labelled: [(ScribeWord, String, Int)] = []
        var order = 0
        for track in ["mic", "system"] {
            guard let r = input.results[track] else { continue }
            let diarized = input.diarized[track] ?? false
            let labels = speakerLabels(r)
            for w in r.words {
                let who: String
                if diarized { who = labels[w.speakerID ?? ""] ?? "Speaker ?" }
                else if track == "mic" { who = hostName(input.manifest) }
                else { who = "Speaker 1" }
                labelled.append((w, who, order)); order += 1
            }
        }
        // Stable on ties: at an equal start time the mic word comes first.
        labelled.sort { $0.0.start != $1.0.start ? $0.0.start < $1.0.start : $0.2 < $1.2 }
        var turns: [Utterance] = []
        for (w, who, _) in labelled {
            let text = oneLine(w.text)
            if var last = turns.last, last.speaker == who, w.start - last.end <= turnGap {
                last.text += " " + text
                last.end = w.end
                turns[turns.count - 1] = last
            } else {
                turns.append(Utterance(speaker: who, start: w.start, end: w.end, text: text))
            }
        }
        return turns
    }

    public static func timestamp(_ seconds: Double) -> String {
        let s = max(0, Int(seconds))
        return String(format: "%02d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }

    /// The diarization value, one of three.
    public static func diarizationValue(_ input: RenderInput, speakers: Int) -> String {
        if input.diarized.values.contains(true) { return "elevenlabs, \(speakers) speakers" }
        if input.manifest.source == "mic" { return "none (in-person single track)" }
        return "none (single remote track)"
    }

    /// Speakers holding under 0.5% of a diarized track's words: likely artifacts.
    public static func phantomSpeakers(_ input: RenderInput) -> [(label: String, words: Int, share: Double)] {
        var out: [(String, Int, Double)] = []
        for (track, r) in input.results where input.diarized[track] == true {
            let labels = speakerLabels(r)
            var counts: [String: Int] = [:]
            for w in r.words { counts[w.speakerID ?? "", default: 0] += 1 }
            let total = max(1, r.words.count)
            for (id, c) in counts where Double(c) / Double(total) < phantomShare {
                out.append((labels[id] ?? id, c, Double(c) / Double(total)))
            }
        }
        return out.sorted { $0.0 < $1.0 }
    }

    static func q(_ s: String) -> String {
        var e = ""
        for u in s.unicodeScalars {
            switch u {
            case "\"": e += "\\\""
            case "\\": e += "\\\\"
            case "\n", "\r", "\t": e += " "
            default: e.unicodeScalars.append(u)
            }
        }
        return "\"" + e + "\""
    }

    static func dateParts(_ startedAt: String) -> (date: String, start: String) {
        // "2026-01-02T04:04:05+01:00" -> ("2026-01-02", "04:04 +01:00")
        let c = Array(startedAt)
        guard c.count >= 19, c[4] == "-", c[7] == "-", c[10] == "T", c[13] == ":" else { return ("", "") }
        let tz = c.count > 19 ? String(c[19...]) : ""
        return (String(c[0..<10]), String(c[11..<16]) + (tz.isEmpty ? "" : " " + tz))
    }

    public static func render(_ input: RenderInput) -> String {
        let m = input.manifest
        let turns = utterances(input)
        let speakers = Set(turns.map(\.speaker))
        // Dominant language: the response with the most words. The provider's code is kept
        // as returned, never translated or normalised.
        let lang = input.results.sorted { $0.key < $1.key }
            .max { $0.value.words.count < $1.value.words.count }?.value.languageCode
            ?? m.languageHint ?? "und"
        let (date, start) = dateParts(m.startedAt)
        let d = max(0, Int(input.durationSeconds.rounded()))

        var participants: [String] = []
        if m.source == "mic-multi" {
            for s in speakers.sorted(by: labelOrder) { participants.append("\(s) (in-person)") }
        } else {
            if m.tracks["mic"] != nil { participants.append("\(hostName(m)) (host, mic)") }
            for s in speakers.sorted(by: labelOrder) where s != hostName(m) { participants.append("\(s) (remote)") }
        }

        var fm = ["---", "schema: \(schema)", "title: \(q(m.label.isEmpty ? "meeting" : m.label))",
                  "date: \(q(date))", "start: \(q(start))",
                  "duration: \(q(String(format: "%dm%02ds", d / 60, d % 60)))",
                  "language: \(q(lang))", "participants:"]
        fm += participants.map { "  - \(q($0))" }
        fm += ["source: \(q(m.source))",
               "diarization: \(q(diarizationValue(input, speakers: speakers.count)))",
               "transcription:",
               "  provider: \"elevenlabs\"",
               "  model: \(q(model))",
               "  endpoint_region: \"us\"",
               "  retention: \"provider-side, no zero-retention below Enterprise\"",
               "meeting_id: \(q(m.meetingID))"]
        if !input.silentTracks.isEmpty {
            fm.append("silent_tracks:")
            fm += input.silentTracks.map { "  - \(q($0))" }
        }
        fm.append("---")
        var lines = fm
        for (i, t) in turns.enumerated() {
            lines.append("\(i + 1)  [\(timestamp(t.start))] \(t.speaker): \(t.text)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// "Speaker 2" before "Speaker 10".
    static func labelOrder(_ a: String, _ b: String) -> Bool {
        let na = Int(a.split(separator: " ").last ?? ""), nb = Int(b.split(separator: " ").last ?? "")
        if let na, let nb, a.hasPrefix("Speaker "), b.hasPrefix("Speaker ") { return na < nb }
        return a < b
    }
}
