// The capture manifest, as `meeting-capture` writes it.
//
// Schema 1: the original. `expected_speakers` only on mic-multi.
// Schema 2: `expected_speakers` may appear on every source. On `mic+system` it is the
//           REMOTE head count, on `mic-multi` the head count in the room. Absent means
//           "not known", and the reader diarizes.
// Any other schema is refused, because a reader that guesses at a field it does not know
// can misread the one that decides whether speakers get invented.
import Foundation

public struct Manifest: Equatable {
    public struct Track: Equatable {
        public let path: String
        public let host: Bool
        public let speaker: String?
    }

    public static let supportedSchemas: Set<Int> = [1, 2]
    public static let sources: Set<String> = ["mic+system", "mic", "mic-multi"]

    public let schema: Int
    public let meetingID: String
    public let label: String
    public let source: String
    public let startedAt: String
    public let tracks: [String: Track]
    public let languageHint: String?
    public let expectedSpeakers: Int?

    public enum LoadError: Error, Equatable, CustomStringConvertible {
        case unreadable(String)
        case malformed(String)
        case unsupportedSchema(Int)

        public var description: String {
            switch self {
            case .unreadable(let s): return "manifest unreadable: \(s)"
            case .malformed(let s): return "manifest malformed: \(s)"
            case .unsupportedSchema(let n): return "manifest schema \(n) is not supported (1 and 2 are)"
            }
        }
    }

    /// A name that is safe as ONE path component: no separator, no leading dot.
    public static func isPlainComponent(_ s: String) -> Bool {
        guard !s.isEmpty, !s.hasPrefix("."), s.count <= 128 else { return false }
        return s.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) && $0.isASCII || "._-".unicodeScalars.contains($0) }
    }

    public static func load(path: String) throws -> Manifest {
        guard let data = FileManager.default.contents(atPath: path) else {
            throw LoadError.unreadable(path)
        }
        return try decode(data)
    }

    public static func decode(_ data: Data) throws -> Manifest {
        guard let obj = try? JSONSerialization.jsonObject(with: data), let m = obj as? [String: Any] else {
            throw LoadError.malformed("not a JSON object")
        }
        guard let schema = m["schema"] as? Int else { throw LoadError.malformed("no integer schema") }
        guard supportedSchemas.contains(schema) else { throw LoadError.unsupportedSchema(schema) }
        guard let id = m["meeting_id"] as? String, isPlainComponent(id) else {
            throw LoadError.malformed("meeting_id missing or not a plain name")
        }
        guard let source = m["source"] as? String, sources.contains(source) else {
            throw LoadError.malformed("source missing or unknown")
        }
        guard let rawTracks = m["tracks"] as? [String: Any], !rawTracks.isEmpty else {
            throw LoadError.malformed("no tracks")
        }
        var tracks: [String: Track] = [:]
        for (name, v) in rawTracks {
            guard name == "mic" || name == "system" else { throw LoadError.malformed("unknown track \(name)") }
            guard let t = v as? [String: Any], let p = t["path"] as? String, isPlainComponent(p) else {
                throw LoadError.malformed("track \(name) has no plain file path")
            }
            tracks[name] = Track(path: p, host: (t["host"] as? Bool) ?? (name == "mic"),
                                 speaker: t["speaker"] as? String)
        }
        var speakers: Int?
        if let raw = m["expected_speakers"] {
            guard let n = raw as? Int, n > 0 else { throw LoadError.malformed("expected_speakers is not a positive integer") }
            speakers = n
        }
        return Manifest(schema: schema, meetingID: id, label: (m["label"] as? String) ?? "",
                        source: source, startedAt: (m["started_at"] as? String) ?? "",
                        tracks: tracks, languageHint: m["language_hint"] as? String,
                        expectedSpeakers: speakers)
    }
}
