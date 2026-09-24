// Consent to upload audio, typed by a human.
//
// The consent file records WHICH disclosure was agreed to, by its SHA-256. When the
// disclosure text changes, the hash changes, and every existing consent stops counting
// until a human reads the new text and consents again. The transcriber refuses to upload
// while the file is absent or its hash does not match.
import Foundation
import CryptoKit

public enum Consent {
    public static let version = 1

    /// The measured cost, with its basis. Shown in the disclosure and recorded in the file.
    public static let costFigure = "20.19 credits per channel-minute of audio, measured on one Creator-tier account in 2026. A two-track call bills both tracks. Check your own rate with GET /v1/user/subscription before relying on it."

    /// What a person agrees to. Changing ANY byte of this invalidates every existing consent.
    public static let disclosureText = """
    meeting-transcribe uploads the audio of every recording it transcribes to ElevenLabs (speech-to-text, model scribe_v2).

    - Where it goes: the ElevenLabs US endpoint (api.elevenlabs.io). Below the Enterprise plan there is no EU data residency.
    - Retention: ElevenLabs retains and logs the uploaded audio and the transcript on its side. Below the Enterprise plan there is no zero-retention mode.
    - Your role: you are the controller of these recordings and ElevenLabs is your processor. Read the ElevenLabs Data Processing Addendum (https://elevenlabs.io/dpa) and decide whether it covers your use.
    - Cost: \(costFigure)
    - Your duty: tell every participant that the meeting is being recorded and transcribed by a third party, before you record.

    With consent in place and the worker installed, every completed recording in the watched folder is uploaded without asking again. Revoke with: meeting-transcribe --revoke-consent
    """

    public static var disclosureHash: String {
        SHA256.hash(data: Data(disclosureText.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public struct Record: Codable, Equatable {
        public var version: Int
        public var disclosure_sha256: String
        public var date: String
        public var cost_shown: String
    }

    public static func currentRecord(date: Date = Date()) -> Record {
        let f = ISO8601DateFormatter()
        return Record(version: version, disclosure_sha256: disclosureHash,
                      date: f.string(from: date), cost_shown: costFigure)
    }

    /// Writes `record` to `path` (temp then rename), creating the directory.
    public static func write(_ record: Record, to path: String = UserPaths.consentFile) throws {
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(record).write(to: URL(fileURLWithPath: path), options: [.atomic])
    }

    public static func read(_ path: String = UserPaths.consentFile) -> Record? {
        guard let d = FileManager.default.contents(atPath: path) else { return nil }
        return try? JSONDecoder().decode(Record.self, from: d)
    }

    public enum State: Equatable {
        case valid
        case absent
        case stale   // present, but agreed to a different disclosure
    }

    public static func state(_ path: String = UserPaths.consentFile) -> State {
        guard FileManager.default.fileExists(atPath: path) else { return .absent }
        guard let r = read(path), r.disclosure_sha256 == disclosureHash, r.version == version else { return .stale }
        return .valid
    }
}
