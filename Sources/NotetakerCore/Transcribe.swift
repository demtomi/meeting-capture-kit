// One take in, one transcript out: `meeting-transcribe <manifest.json>`.
//
// Exit codes are a contract. The capture CLI and the queue worker both act on them, and
// a custom transcriber plugged into either must return the same ones.
import Foundation

public enum ExitCode {
    public static let ok: Int32 = 0
    public static let transient: Int32 = 1      // retry later
    public static let badArguments: Int32 = 2
    public static let neverSucceeds: Int32 = 3  // this take, no retry
    public static let allSilent: Int32 = 4      // every track digital silence, no retry
    public static let accountStop: Int32 = 5    // key, quota, balance, plan, consent: stop everything
    public static let heldElsewhere: Int32 = 6  // another runner holds this take
}

/// Terminal markers written into `.work/<id>/`. A take carrying one is never picked again
/// until `--requeue` clears it.
public enum Marker {
    public static let unreadable = ".unreadable"
    public static let refused = ".refused"
    public static let silentCapture = ".silent-capture"
    public static let uploadFailed = ".upload-failed"
    public static let noTranscript = ".no-transcript"
    public static let transcribed = ".transcribed"
    public static let terminal = [unreadable, refused, silentCapture, uploadFailed, noTranscript, transcribed]
    public static let attempts = ".upload-attempts"
}

public func stderrLine(_ s: String) {
    FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
}

public final class TakeTranscriber {
    public let manifestPath: String
    public let takeDir: String
    /// The transcripts folder: the parent of `.work`.
    public let outputDir: String
    let env: RuntimeEnv
    let log: (String) -> Void

    public init(manifestPath: String, env: RuntimeEnv, log: @escaping (String) -> Void = stderrLine) {
        let abs = URL(fileURLWithPath: manifestPath).standardizedFileURL.path
        self.manifestPath = abs
        self.takeDir = (abs as NSString).deletingLastPathComponent
        self.outputDir = ((takeDir as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent
        self.env = env
        self.log = log
    }

    /// The last line on stderr before a non-zero exit. The worker copies it into its log
    /// and, on exit 5, into the pause file.
    func reason(_ s: String) { log("reason: \(s)") }

    func mark(_ marker: String, _ text: String) -> Bool {
        FileManager.default.createFile(atPath: takeDir + "/" + marker, contents: Data((text + "\n").utf8))
    }

    public func run() -> Int32 {
        guard FileManager.default.fileExists(atPath: manifestPath) else {
            reason("no manifest at \(manifestPath)")
            return ExitCode.badArguments
        }
        let m: Manifest
        do { m = try Manifest.load(path: manifestPath) } catch {
            reason("\(error)")
            return ExitCode.neverSucceeds
        }

        // Peak scan. An unreadable track is never guessed at in either direction.
        var silent: [String] = []
        var live: [String] = []
        for track in ["mic", "system"] {
            guard let t = m.tracks[track] else { continue }
            let path = takeDir + "/" + t.path
            do {
                let p = try WavPeak.peak(path: path)
                if WavPeak.isSilent(p) {
                    log(String(format: "[transcribe] %@ track is digital silence (peak %.6f), not uploaded", track, p))
                    silent.append(track)
                } else {
                    live.append(track)
                }
            } catch {
                _ = mark(Marker.unreadable, "\(track): \(error)")
                reason("\(track) track unreadable: \(error). Audio kept.")
                return ExitCode.neverSucceeds
            }
        }
        if live.isEmpty {
            reason("every captured track was digital silence (\(silent.joined(separator: ", "))). This is a capture failure, not a quiet meeting.")
            return ExitCode.allSilent
        }

        // NAIVE UPLOAD, replaced in step 8.
        for track in live {
            let s = naiveUpload(takeDir + "/" + m.tracks[track]!.path, diarize: track == "system")
            if s != 200 { return 1 }
        }
        return ExitCode.ok
    }

    func naiveUpload(_ file: String, diarize: Bool) -> Int {
        var req = URLRequest(url: URL(string: env.apiBase + "/v1/speech-to-text")!)
        req.httpMethod = "POST"
        req.setValue(env.testKey ?? "", forHTTPHeaderField: "xi-api-key")
        let b = "naive"
        req.setValue("multipart/form-data; boundary=\(b)", forHTTPHeaderField: "Content-Type")
        var body = Data("--\(b)\r\nContent-Disposition: form-data; name=\"model_id\"\r\n\r\nscribe_v2\r\n".utf8)
        body += Data("--\(b)\r\nContent-Disposition: form-data; name=\"diarize\"\r\n\r\n\(diarize)\r\n".utf8)
        body += Data("--\(b)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\((file as NSString).lastPathComponent)\"\r\n\r\n".utf8)
        body += (FileManager.default.contents(atPath: file) ?? Data())
        body += Data("\r\n--\(b)--\r\n".utf8)
        req.httpBody = body
        let done = DispatchSemaphore(value: 0)
        var status = -1
        URLSession.shared.dataTask(with: req) { _, r, _ in
            status = (r as? HTTPURLResponse)?.statusCode ?? -1; done.signal()
        }.resume()
        done.wait()
        return status
    }
}

/// What the process was started with. Read once, in one place.
public struct RuntimeEnv {
    public static let defaultAPIBase = "https://api.elevenlabs.io"
    public let apiBase: String
    public let testKey: String?

    public init(apiBase: String = RuntimeEnv.defaultAPIBase, testKey: String? = nil) {
        self.apiBase = apiBase; self.testKey = testKey
    }

    public static func fromProcess() -> RuntimeEnv {
        let e = ProcessInfo.processInfo.environment
        return RuntimeEnv(apiBase: e["MEETING_TRANSCRIBE_API_BASE"] ?? defaultAPIBase,
                          testKey: e["MEETING_TRANSCRIBE_TEST_KEY"])
    }
}
