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

        // Where to send it, and with what key.
        let (base, refusal) = APIBase.resolve(override: env.apiBaseOverride)
        guard let base else {
            reason(refusal ?? "bad API base")
            return ExitCode.badArguments
        }
        guard let key = env.key(loopback: base.isLoopback) else {
            reason("no key. Add it with: security add-generic-password -s meeting-capture-elevenlabs -a \"$USER\" -w")
            return ExitCode.accountStop
        }
        let knobs = base.isLoopback ? env.testKnobs : TestKnobs()

        // The claim, before anything is read for upload or written. Everything below
        // re-checks it before an upload or a write.
        let claim: TakeClaim
        switch TakeClaim.acquire(takeDir: takeDir, stale: knobs.staleSeconds ?? TakeClaim.staleSeconds, log: log) {
        case .held(let c): claim = c
        case .heldElsewhere(let why):
            reason("this take is held by another runner (\(why)). Nothing uploaded, audio kept.")
            return ExitCode.heldElsewhere
        case .failed(let why):
            reason(why)
            return ExitCode.transient
        }
        claim.startHeartbeat(every: knobs.heartbeatSeconds ?? TakeClaim.heartbeatSeconds)
        defer { claim.release() }
        if let hold = knobs.holdAfterClaim {
            // Test-only pause point, so a check can freeze a holder between claim and upload.
            FileManager.default.createFile(atPath: hold + ".claimed", contents: nil)
            while !FileManager.default.fileExists(atPath: hold + ".go") { Thread.sleep(forTimeInterval: 0.05) }
        }
        func lost() -> Int32 {
            reason("the claim on this take was taken over while this run was stopped. Nothing written.")
            return ExitCode.heldElsewhere
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
                guard claim.stillMine() else { return lost() }
                _ = mark(Marker.unreadable, "\(track): \(error)")
                reason("\(track) track unreadable: \(error). Audio kept.")
                return ExitCode.neverSucceeds
            }
        }
        if live.isEmpty {
            reason("every captured track was digital silence (\(silent.joined(separator: ", "))). This is a capture failure, not a quiet meeting.")
            return ExitCode.allSilent
        }

        let durations = Dictionary(uniqueKeysWithValues: (live + silent).map { t in
            (t, (try? WavPeak.info(path: takeDir + "/" + m.tracks[t]!.path).durationSeconds) ?? 0)
        })
        // The per-take ceiling, checked before any upload. A take longer than this is almost
        // always a recording nobody stopped, and it would bill every minute of it.
        let ceiling = WorkerConfig.load().max_take_seconds ?? WorkerConfig.defaultMaxTakeSeconds
        if let longest = durations.values.max(), longest > ceiling {
            guard claim.stillMine() else { return lost() }
            _ = mark(Marker.refused, "longer than the \(Int(ceiling)) s ceiling")
            reason(String(format: "the take is %.0f s long, over the %.0f s ceiling. Nothing uploaded. Raise max_take_seconds in %@ and --requeue it if it is real.",
                          longest, ceiling, UserPaths.configFile))
            return ExitCode.neverSucceeds
        }
        let client = ScribeClient(
            base: base.url, key: key,
            sleep: { s in Thread.sleep(forTimeInterval: s * knobs.backoffScale) },
            timeoutOverride: knobs.timeoutSeconds,
            onAttempt: { r, result in
                self.log(String(format: "[transcribe] upload take=%@ track=%@ audio_seconds=%.1f result=%@",
                                m.meetingID, r.track, r.audioSeconds, result))
            })

        // Per track: a cached 200 is reused, never uploaded again.
        var results: [String: ScribeResult] = [:]
        var rawObjects: [String: Any] = [:]
        var diarized: [String: Bool] = [:]
        for track in live {
            let (diarize, pin) = diarization(m, track: track)
            diarized[track] = diarize
            let cache = takeDir + "/scribe-\(track).json"
            var body = FileManager.default.contents(atPath: cache)
            if let b = body, ScribeResult.parse(b) != nil {
                log("[transcribe] \(track): reusing the cached response, no upload")
            } else {
                body = nil
                let req = ScribeRequest(file: takeDir + "/" + m.tracks[track]!.path, track: track,
                                        diarize: diarize, numSpeakers: pin, languageCode: m.languageHint,
                                        audioSeconds: durations[track] ?? 0)
                guard claim.stillMine() else { return lost() }
                let outcome = client.transcribe(req, scratchDir: takeDir)
                guard case .ok(let data) = outcome else {
                    switch outcome {
                    case .transient(let s), .neverSucceeds(let s), .accountStop(let s): reason("\(track): \(s)")
                    case .ok: break
                    }
                    return outcome.exitCode
                }
                guard ScribeResult.parse(data) != nil else {
                    reason("\(track): a 200 whose body is not a transcript")
                    return ExitCode.transient
                }
                // Cached the moment it arrives, temp then rename.
                guard claim.stillMine() else { return lost() }
                do { try writeAtomically(data, to: cache) } catch {
                    reason("cannot write the \(track) cache: \(error)")
                    return ExitCode.transient
                }
                body = data
            }
            results[track] = ScribeResult.parse(body!)!
            rawObjects[track] = try? JSONSerialization.jsonObject(with: body!)
        }

        // Outputs, only once every track is cached. Raw first, transcript last, both temp then
        // rename, so a transcript on disk always has its raw file beside it.
        let input = RenderInput(manifest: m, results: results, diarized: diarized, silentTracks: silent,
                                durationSeconds: durations.values.max() ?? 0)
        for p in Renderer.phantomSpeakers(input) {
            log(String(format: "[transcribe] phantom-speaker warning: %@ holds %d word(s) (%.2f%%). Likely an artifact. Set --speakers at capture to pin the count.",
                       p.label, p.words, p.share * 100))
        }
        rawObjects["_meta"] = ["silent_tracks": silent, "diarized": diarized, "schema": Renderer.schema]
        let rawPath = OutputNames.rawPath(outputDir: outputDir, label: m.label, meetingID: m.meetingID)
        let mdPath = OutputNames.transcriptPath(outputDir: outputDir, label: m.label, meetingID: m.meetingID)
        do {
            try FileManager.default.createDirectory(atPath: (rawPath as NSString).deletingLastPathComponent,
                                                    withIntermediateDirectories: true)
            guard claim.stillMine() else { return lost() }
            try writeAtomically(try JSONSerialization.data(withJSONObject: rawObjects, options: [.sortedKeys]), to: rawPath)
            guard claim.stillMine() else { return lost() }
            try writeAtomically(Data(Renderer.render(input).utf8), to: mdPath)
        } catch {
            reason("cannot write the transcript: \(error)")
            return ExitCode.transient
        }
        log("[transcribe] wrote \(mdPath)")
        return ExitCode.ok
    }

    /// (diarize, pinned speaker count) for one track, from the manifest.
    func diarization(_ m: Manifest, track: String) -> (Bool, Int?) {
        switch (m.source, track) {
        case ("mic-multi", "mic"): return (true, m.expectedSpeakers)
        case ("mic+system", "system"):
            // One remote voice: diarizing it can only invent speakers.
            if m.expectedSpeakers == 1 { return (false, nil) }
            return (true, m.expectedSpeakers)
        default: return (false, nil)
        }
    }
}

/// Temp file in the same directory, then rename. A reader sees the old file or the whole
/// new one, never half of it.
public func writeAtomically(_ data: Data, to path: String) throws {
    let tmp = (path as NSString).deletingLastPathComponent + "/.tmp-\(getpid())-" + (path as NSString).lastPathComponent
    try data.write(to: URL(fileURLWithPath: tmp))
    if rename(tmp, path) != 0 {
        let e = errno
        try? FileManager.default.removeItem(atPath: tmp)
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(e))
    }
}

/// Timing knobs the checks use. Honoured ONLY when the API base is loopback, so no real
/// run can be made to back off less, time out sooner or hold a claim.
public struct TestKnobs {
    public var backoffScale: Double = 1
    public var timeoutSeconds: Double?
    public var staleSeconds: Double?
    public var heartbeatSeconds: Double?
    public var cooldownSeconds: Double?
    public var holdAfterClaim: String?
    public init() {}
}

/// What the process was started with. Read once, in one place.
public struct RuntimeEnv {
    public static let defaultAPIBase = "https://api.elevenlabs.io"
    public let apiBaseOverride: String?
    public let testKey: String?
    public let testKnobs: TestKnobs

    public init(apiBaseOverride: String? = nil, testKey: String? = nil, testKnobs: TestKnobs = TestKnobs()) {
        self.apiBaseOverride = apiBaseOverride; self.testKey = testKey; self.testKnobs = testKnobs
    }

    /// The key. On a loopback base it is the test key and nothing else, so a check can
    /// never read a real one. Real key sources arrive with KeySource.
    public func key(loopback: Bool) -> String? {
        if loopback { return testKey }
        return nil
    }

    public static func fromProcess() -> RuntimeEnv {
        let e = ProcessInfo.processInfo.environment
        var k = TestKnobs()
        if let v = e["MEETING_TRANSCRIBE_TEST_BACKOFF_SCALE"].flatMap(Double.init) { k.backoffScale = v }
        k.timeoutSeconds = e["MEETING_TRANSCRIBE_TEST_TIMEOUT_SECONDS"].flatMap(Double.init)
        k.staleSeconds = e["MEETING_TRANSCRIBE_TEST_STALE_SECONDS"].flatMap(Double.init)
        k.heartbeatSeconds = e["MEETING_TRANSCRIBE_TEST_HEARTBEAT_SECONDS"].flatMap(Double.init)
        k.cooldownSeconds = e["MEETING_TRANSCRIBE_TEST_COOLDOWN_SECONDS"].flatMap(Double.init)
        k.holdAfterClaim = e["MEETING_TRANSCRIBE_TEST_HOLD_AFTER_CLAIM"]
        return RuntimeEnv(apiBaseOverride: e["MEETING_TRANSCRIBE_API_BASE"], testKey: e["MEETING_TRANSCRIBE_TEST_KEY"], testKnobs: k)
    }
}
