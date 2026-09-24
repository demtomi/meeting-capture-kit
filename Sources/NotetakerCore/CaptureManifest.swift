// What `meeting-capture` writes as a take's manifest.json. Lives here, not in the CLI, so a
// check can assert its contents without a microphone.
import Foundation

public enum CaptureManifest {
    public static func make(meetingID: String, label: String, source: String, startedAt: String,
                            sharedStartNs: UInt64, host: String, hasSystemTrack: Bool, outputDir: String,
                            languageHint: String?, expectedSpeakers: Int?) -> [String: Any] {
        var tracks: [String: Any] = ["mic": ["path": "mic.wav", "host": true, "speaker": host]]
        if hasSystemTrack { tracks["system"] = ["path": "system.wav", "host": false] }
        // Schema 2 only when the manifest carries a field schema 1 does not define. Stamping it
        // on every take would make every schema-1 reader refuse takes it could read.
        let needsSchema2 = expectedSpeakers != nil && source != "mic-multi"
        var m: [String: Any] = [
            "schema": needsSchema2 ? 2 : 1,
            "meeting_id": meetingID,
            "label": label,
            "source": source,
            "started_at": startedAt,
            "shared_start_monotonic_ns": sharedStartNs,
            "tracks": tracks,
            "output_dir": outputDir,
        ]
        if let languageHint { m["language_hint"] = languageHint }
        // On mic+system it is the remote head count, on mic-multi the head count in the
        // room. A transcriber pins diarization to it, and on a one-remote-voice call skips
        // diarization, which on one voice can only invent speakers. Absent means not known,
        // and the reader diarizes.
        if let expectedSpeakers { m["expected_speakers"] = expectedSpeakers }
        return m
    }
}
