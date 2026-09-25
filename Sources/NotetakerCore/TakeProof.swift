// The one rule that decides whether a take's audio may be deleted.
//
// An exit code is a claim by the transcriber about what it did. The proof re-reads what
// is actually on disk: the transcript exists, is non-empty, its frontmatter parses and
// names this meeting, and the raw response cache exists. Both the capture CLI and the
// queue worker call this, so no entry point deletes audio on an exit code alone, whatever
// transcriber is plugged in.
import Foundation

public enum ProofFailure: Equatable, CustomStringConvertible {
    case unreadableManifest(String)
    case missingTranscript
    case emptyTranscript
    case badFrontmatter
    case wrongMeetingID(String?)
    case missingRaw

    public var description: String {
        switch self {
        case .unreadableManifest(let s): return "the manifest could not be read (\(s))"
        case .missingTranscript: return "no transcript file"
        case .emptyTranscript: return "the transcript file is empty"
        case .badFrontmatter: return "the transcript frontmatter does not parse"
        case .wrongMeetingID(let s): return "the transcript names meeting_id \(s ?? "nothing")"
        case .missingRaw: return "no raw response file in .raw/"
        }
    }
}

/// Top-level `key: value` pairs of a `---` delimited frontmatter block, or nil when the
/// block is absent or a line in it is not YAML-shaped.
public func parseFrontmatter(_ text: String) -> [String: String]? {
    let lines = text.components(separatedBy: "\n")
    guard lines.first == "---" else { return nil }
    guard let close = lines.dropFirst().firstIndex(of: "---") else { return nil }
    var out: [String: String] = [:]
    for line in lines[1..<close] {
        if line.isEmpty { continue }
        if line.hasPrefix(" ") || line.hasPrefix("- ") { continue }   // list item or nested map
        guard let c = line.firstIndex(of: ":") else { return nil }
        let key = String(line[..<c])
        guard !key.isEmpty, key.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == "_" }) else {
            return nil
        }
        var value = line[line.index(after: c)...].trimmingCharacters(in: .whitespaces)
        if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
            value = String(value.dropFirst().dropLast())
        }
        out[key] = value
    }
    return out
}

/// nil when the transcript for (label, meetingID) under `outputDir` proves the take done.
public func proveTranscript(outputDir: String, label: String, meetingID: String) -> ProofFailure? {
    let fm = FileManager.default
    let md = OutputNames.transcriptPath(outputDir: outputDir, label: label, meetingID: meetingID)
    guard let data = fm.contents(atPath: md) else { return .missingTranscript }
    guard !data.isEmpty else { return .emptyTranscript }
    guard let fields = parseFrontmatter(String(decoding: data, as: UTF8.self)) else { return .badFrontmatter }
    guard fields["meeting_id"] == meetingID else { return .wrongMeetingID(fields["meeting_id"]) }
    let raw = OutputNames.rawPath(outputDir: outputDir, label: label, meetingID: meetingID)
    guard fm.fileExists(atPath: raw) else { return .missingRaw }
    return nil
}

/// The proof for the take whose manifest is at `manifestPath`.
public func proveTake(manifestPath: String, outputDir: String) -> ProofFailure? {
    let m: Manifest
    do { m = try Manifest.load(path: manifestPath) } catch {
        return .unreadableManifest("\(error)")
    }
    return proveTranscript(outputDir: outputDir, label: m.label, meetingID: m.meetingID)
}
