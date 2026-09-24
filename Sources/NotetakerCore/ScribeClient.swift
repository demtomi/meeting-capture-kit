// The speech-to-text client: one multipart WAV upload per track, and ONE table from HTTP
// status to exit code.
//
//   200                                   -> ok
//   401, 402, 403, or a quota/balance body -> exit 5, account-wide: stop everything
//   400, 413, 422                         -> exit 3, this take can never succeed
//   429                                   -> back off 30, 60, 120 s inside the run, then exit 1
//   5xx, network error, timeout, other    -> exit 1, retry later
//
// Timeouts come from the audio duration, never the 60 s default, so a slow response to a
// long take is waited for rather than uploaded (and billed) again. Both the idle and the
// total timeout are 900 s plus half the audio duration.
import Foundation

public enum ScribeOutcome: Equatable {
    case ok(Data)
    case transient(String)
    case neverSucceeds(String)
    case accountStop(String)

    public var exitCode: Int32 {
        switch self {
        case .ok: return ExitCode.ok
        case .transient: return ExitCode.transient
        case .neverSucceeds: return ExitCode.neverSucceeds
        case .accountStop: return ExitCode.accountStop
        }
    }
}

/// Where requests go. The default is the provider. An override is accepted ONLY for a
/// loopback host, because it is how the checks point the transcriber at a local stub, and
/// an override that accepted any host would send the key wherever it pointed.
public struct APIBase: Equatable {
    public static let loopbackHosts: Set<String> = ["127.0.0.1", "::1", "localhost"]
    public let url: URL
    public let isLoopback: Bool

    /// nil with a reason when the override is refused.
    public static func resolve(override: String?) -> (APIBase?, String?) {
        guard let o = override, !o.isEmpty else {
            return (APIBase(url: URL(string: RuntimeEnv.defaultAPIBase)!, isLoopback: false), nil)
        }
        guard let u = URL(string: o), let host = u.host, u.scheme == "http" || u.scheme == "https" else {
            return (nil, "MEETING_TRANSCRIBE_API_BASE is not a URL: \(o)")
        }
        let h = host.hasPrefix("[") ? String(host.dropFirst().dropLast()) : host
        guard loopbackHosts.contains(h.lowercased()) else {
            return (nil, "MEETING_TRANSCRIBE_API_BASE is only honoured for 127.0.0.1, ::1 or localhost, not \(host)")
        }
        return (APIBase(url: u, isLoopback: true), nil)
    }
}

public struct ScribeRequest {
    public let file: String
    public let track: String
    public let diarize: Bool
    public let numSpeakers: Int?
    public let languageCode: String?
    public let audioSeconds: Double
    public init(file: String, track: String, diarize: Bool, numSpeakers: Int?, languageCode: String?, audioSeconds: Double) {
        self.file = file; self.track = track; self.diarize = diarize; self.numSpeakers = numSpeakers
        self.languageCode = languageCode; self.audioSeconds = audioSeconds
    }
}

public final class ScribeClient {
    public static let model = "scribe_v2"
    public static func resourceTimeout(audioSeconds: Double) -> Double { 900 + 0.5 * audioSeconds }
    /// URLSession's idle timeout: the longest gap with no bytes moving. After the upload no
    /// bytes move at all while the provider transcribes, so this equals the total timeout,
    /// 900 s plus half the audio (a 1 h track: 2,700 s). A fixed 300 s fired on long takes
    /// mid-processing and the take was uploaded and billed again.
    public static func requestTimeout(audioSeconds: Double) -> Double { resourceTimeout(audioSeconds: audioSeconds) }
    public static let backoff: [Double] = [30, 60, 120]
    /// While the body is being sent, no progress for this long abandons the attempt.
    public static let sendStallSeconds: Double = 300
    static let accountBodies = ["quota_exceeded", "max_character_limit_exceeded", "payment_required",
                                "insufficient_credits", "invalid_api_key", "missing_api_key"]

    let base: URL
    let key: String
    let sleep: (Double) -> Void
    let timeoutOverride: Double?
    let sendStallOverride: Double?
    /// Called once per upload attempt, with the HTTP status or the error. This is the
    /// spend log: every attempt is billable audio whether or not it came back.
    let onAttempt: (ScribeRequest, String) -> Void

    public init(base: URL, key: String, sleep: @escaping (Double) -> Void = { Thread.sleep(forTimeInterval: $0) },
                timeoutOverride: Double? = nil, sendStallOverride: Double? = nil,
                onAttempt: @escaping (ScribeRequest, String) -> Void = { _, _ in }) {
        self.base = base; self.key = key; self.sleep = sleep
        self.timeoutOverride = timeoutOverride; self.sendStallOverride = sendStallOverride; self.onAttempt = onAttempt
    }

    /// The one table.
    public static func classify(status: Int, body: Data) -> ScribeOutcome {
        if status == 200 { return .ok(body) }
        let text = String(decoding: body.prefix(4096), as: UTF8.self)
        let brief = "HTTP \(status): \(text.prefix(300))"
        if accountBodies.contains(where: { text.contains($0) }) || [401, 402, 403].contains(status) {
            return .accountStop(brief)
        }
        if [400, 413, 422].contains(status) { return .neverSucceeds(brief) }
        return .transient(brief)
    }

    /// Streams the WAV into a multipart body file beside it, so a long take is never held
    /// in memory. The caller deletes it.
    func writeMultipart(_ r: ScribeRequest, boundary: String, to path: String) throws {
        FileManager.default.createFile(atPath: path, contents: nil)
        guard let out = FileHandle(forWritingAtPath: path), let inp = FileHandle(forReadingAtPath: r.file) else {
            throw WavError.unreadable("cannot open \(r.file) for upload")
        }
        defer { try? out.close(); try? inp.close() }
        func field(_ name: String, _ value: String) {
            out.write(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        field("model_id", Self.model)
        field("diarize", r.diarize ? "true" : "false")
        field("timestamps_granularity", "word")
        field("tag_audio_events", "false")
        if let l = r.languageCode, !l.isEmpty { field("language_code", l) }
        if r.diarize, let n = r.numSpeakers { field("num_speakers", String(n)) }
        out.write(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(r.track).wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
        while let chunk = try inp.read(upToCount: 1 << 20), !chunk.isEmpty { out.write(chunk) }
        out.write(Data("\r\n--\(boundary)--\r\n".utf8))
    }

    /// One attempt. Returns status and body, or an error string.
    func once(_ r: ScribeRequest, bodyFile: String, boundary: String) -> (Int?, Data, String?) {
        var req = URLRequest(url: base.appendingPathComponent("v1/speech-to-text"))
        req.httpMethod = "POST"
        req.setValue(key, forHTTPHeaderField: "xi-api-key")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeoutOverride ?? Self.requestTimeout(audioSeconds: r.audioSeconds)
        cfg.timeoutIntervalForResource = timeoutOverride ?? Self.resourceTimeout(audioSeconds: r.audioSeconds)
        cfg.waitsForConnectivity = false
        let watch = SendWatch()
        let session = URLSession(configuration: cfg, delegate: watch, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let done = DispatchSemaphore(value: 0)
        var status: Int?; var body = Data(); var error: String?
        let task = session.uploadTask(with: req, fromFile: URL(fileURLWithPath: bodyFile)) { d, resp, e in
            status = (resp as? HTTPURLResponse)?.statusCode
            body = d ?? Data()
            error = e.map { ($0 as NSError).localizedDescription }
            done.signal()
        }
        // Stalled-send watchdog. URLSession cannot change a task's idle timeout mid-flight, and
        // that timeout must be long enough for the provider to process after the upload. So
        // while the BODY is still going out, this timer cancels the task if no bytes have moved
        // for sendStallSeconds (300 s). Once the whole body is sent, only the long idle and
        // total timeouts apply.
        let stallLimit = sendStallOverride ?? Self.sendStallSeconds
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + min(1, stallLimit / 2), repeating: min(1, stallLimit / 2))
        timer.setEventHandler { if watch.stalled(for: stallLimit) { task.cancel() } }
        timer.resume()
        task.resume()
        done.wait()
        timer.cancel()
        if watch.didStall {
            return (nil, Data(), "upload stalled: no bytes sent for \(Int(stallLimit)) s")
        }
        return (error == nil ? status : nil, body, error)
    }

    public func transcribe(_ r: ScribeRequest, scratchDir: String) -> ScribeOutcome {
        let boundary = "meeting-transcribe-\(UUID().uuidString)"
        let bodyFile = scratchDir + "/.upload-\(r.track).multipart"
        defer { try? FileManager.default.removeItem(atPath: bodyFile) }
        do { try writeMultipart(r, boundary: boundary, to: bodyFile) } catch {
            return .neverSucceeds("could not read \(r.track) for upload: \(error)")
        }
        var retries = 0
        while true {
            let (status, body, error) = once(r, bodyFile: bodyFile, boundary: boundary)
            onAttempt(r, status.map { "HTTP \($0)" } ?? "error \(error ?? "unknown")")
            guard let status else { return .transient("network: \(error ?? "unknown")") }
            if status == 429, retries < Self.backoff.count {
                sleep(Self.backoff[retries]); retries += 1
                continue
            }
            return Self.classify(status: status, body: body)
        }
    }
}

/// Tracks upload progress for the stalled-send watchdog.
final class SendWatch: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var lastProgress = Date()
    private var sent: Int64 = 0
    private var expected: Int64 = -1
    private(set) var didStall = false

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        lock.lock(); lastProgress = Date(); sent = totalBytesSent; expected = totalBytesExpectedToSend; lock.unlock()
    }

    /// True once, when the body is not fully sent and nothing moved for `limit` seconds.
    func stalled(for limit: Double) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let bodyDone = expected > 0 && sent >= expected
        guard !didStall, !bodyDone, Date().timeIntervalSince(lastProgress) > limit else { return false }
        didStall = true
        return true
    }
}
