// `meeting-transcribe --doctor`: one PASS, WARN or FAIL line per check, non-zero on any
// FAIL. An agent setting this up reports this output, never its own claim that it works.
import Foundation

public final class Doctor {
    public enum Level: String { case pass = "PASS", warn = "WARN", fail = "FAIL" }
    public private(set) var lines: [(Level, String)] = []
    public var failed: Bool { lines.contains { $0.0 == .fail } }

    let ownBinary: String
    let outputDir: String?
    let env: RuntimeEnv
    let knobs: TestKnobs
    let base: APIBase?
    let captureProbe: Bool
    let fm = FileManager.default

    public init(ownBinary: String, outputDir: String?, env: RuntimeEnv, captureProbe: Bool) {
        self.ownBinary = ownBinary; self.outputDir = outputDir; self.env = env
        self.base = APIBase.resolve(override: env.apiBaseOverride).0
        self.knobs = base?.isLoopback == true ? env.testKnobs : TestKnobs()
        self.captureProbe = captureProbe
    }

    func add(_ l: Level, _ s: String) {
        lines.append((l, s))
        print("\(l.rawValue)  \(s)")
    }

    // ------------------------------------------------------------------ the checks
    public func run(live: Bool) -> Int32 {
        binaries()
        let dirOK = outputDirWritable()
        let key = keyFound()
        launchdKeyRead()
        if let key { keyAccepted(key) }
        consent()
        capture()
        worker()
        if dirOK, let d = outputDir { disk(d); oldFailures(d) }
        if live {
            if let key, !failed { liveRoundTrip(key) } else { add(.fail, "live: not run, fix the FAIL lines above first") }
        }
        print(failed ? "\nDOCTOR: FAIL" : "\nDOCTOR: all checks passed")
        return failed ? 1 : 0
    }

    func binaries() {
        let dir = (ownBinary as NSString).deletingLastPathComponent
        let capture = dir + "/meeting-capture"
        if fm.isExecutableFile(atPath: capture) {
            add(.pass, "binaries: meeting-transcribe and meeting-capture in \(dir)")
        } else {
            add(.warn, "binaries: meeting-transcribe runs, but meeting-capture is not beside it in \(dir). Run doctor from the clone's build: swift build && .build/debug/meeting-transcribe --doctor")
        }
    }

    func outputDirWritable() -> Bool {
        guard let d = outputDir else {
            add(.fail, "output dir: none configured. Install the worker with --output-dir <dir>, or pass --output-dir to --doctor")
            return false
        }
        let probe = d + "/.doctor-write-probe-\(getpid())"
        if fm.createFile(atPath: probe, contents: Data("x".utf8)) {
            try? fm.removeItem(atPath: probe)
            add(.pass, "output dir: \(d) is writable")
            return true
        }
        add(.fail, "output dir: cannot write in \(d)")
        return false
    }

    func keyFound() -> String? {
        if base?.isLoopback == true {
            if let k = env.testKey { add(.pass, "key: test key (loopback API base, test mode)"); return k }
            add(.fail, "key: loopback API base but no MEETING_TRANSCRIBE_TEST_KEY"); return nil
        }
        switch KeySource.resolve() {
        case .found(let k, let from): add(.pass, "key: found in \(from)"); return k
        case .missing(let why): add(.fail, "key: \(why)"); return nil
        }
    }

    /// Reads the key the way the worker will: from a one-shot LaunchAgent, not this shell.
    func launchdKeyRead() {
        if knobs.noLaunchctl { add(.warn, "key from launchd: skipped (test mode)"); return }
        let label = "io.github.meeting-capture.key-probe"
        let tmp = NSTemporaryDirectory() + "meeting-transcribe-keyprobe-\(getpid())"
        try? fm.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: tmp) }
        let result = tmp + "/result", plist = tmp + "/\(label).plist"
        let p: [String: Any] = ["Label": label, "ProgramArguments": [ownBinary, "--key-probe", result], "RunAtLoad": true]
        guard let data = try? PropertyListSerialization.data(fromPropertyList: p, format: .xml, options: 0),
              (try? data.write(to: URL(fileURLWithPath: plist))) != nil else {
            add(.fail, "key from launchd: cannot write the probe plist"); return
        }
        let uid = String(getuid())
        LaunchAgent.launchctl(["bootout", "gui/\(uid)/\(label)"])
        let (rc, out) = LaunchAgent.launchctl(["bootstrap", "gui/\(uid)", plist])
        defer { LaunchAgent.launchctl(["bootout", "gui/\(uid)/\(label)"]) }
        guard rc == 0 else { add(.fail, "key from launchd: probe did not load (\(out.trimmingCharacters(in: .whitespacesAndNewlines)))"); return }
        let end = Date().addingTimeInterval(15)
        while Date() < end, !fm.fileExists(atPath: result) { Thread.sleep(forTimeInterval: 0.2) }
        let r = (try? String(contentsOfFile: result, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        switch r {
        case "found": add(.pass, "key from launchd: the worker's context can read the Keychain item")
        case "missing": add(.fail, "key from launchd: a LaunchAgent cannot read the Keychain item \(KeySource.service). Add it with: \(KeySource.addCommand)")
        default: add(.fail, "key from launchd: the probe gave no answer in 15 s")
        }
    }

    /// `GET /v1/user`. A key restricted to speech-to-text may be refused here, and that is
    /// reported as accepted-restricted, not as a failure.
    func keyAccepted(_ key: String) {
        guard let base else { add(.fail, "key accepted: the API base override is refused"); return }
        var req = URLRequest(url: base.url.appendingPathComponent("v1/user"))
        req.setValue(key, forHTTPHeaderField: "xi-api-key")
        req.timeoutInterval = 20
        let done = DispatchSemaphore(value: 0)
        var status: Int?; var body = Data()
        URLSession.shared.dataTask(with: req) { d, r, _ in
            status = (r as? HTTPURLResponse)?.statusCode; body = d ?? Data(); done.signal()
        }.resume()
        done.wait()
        let text = String(decoding: body.prefix(2000), as: UTF8.self)
        switch status {
        case 200: add(.pass, "key accepted: GET /v1/user 200")
        case .some(let s) where (s == 401 || s == 403) && text.lowercased().contains("permission"):
            add(.pass, "key accepted-restricted: the key works but may not read /v1/user (HTTP \(s)). Fine for a speech-to-text-only key.")
        case .some(let s): add(.fail, "key accepted: GET /v1/user HTTP \(s): \(text.prefix(200))")
        case nil: add(.fail, "key accepted: no response from \(base.url.host ?? "the API")")
        }
    }

    func consent() {
        switch Consent.state() {
        case .valid: add(.pass, "consent: recorded for the current disclosure")
        case .absent: add(.fail, "consent: none. HUMAN: run in a terminal: meeting-transcribe --consent-upload")
        case .stale: add(.fail, "consent: recorded for an older disclosure. HUMAN: read it and run: meeting-transcribe --consent-upload")
        }
    }

    /// 3 seconds through the real capture CLI, then the frame count of each track.
    func capture() {
        guard captureProbe else {
            add(.warn, "capture: probe skipped (--no-capture-probe). Microphone and Screen Recording are NOT verified by this run.")
            return
        }
        let bin = (ownBinary as NSString).deletingLastPathComponent + "/meeting-capture"
        guard fm.isExecutableFile(atPath: bin) else { add(.fail, "capture: meeting-capture not found beside this binary"); return }
        let tmp = NSTemporaryDirectory() + "meeting-transcribe-capture-probe-\(getpid())"
        defer { try? fm.removeItem(atPath: tmp) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = ["--label", "doctor-probe", "--seconds", "3", "--output-dir", tmp, "--source", "mic+system"]
        p.standardInput = FileHandle.nullDevice; p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { add(.fail, "capture: cannot run meeting-capture: \(error)"); return }
        p.waitUntilExit()
        let takes = (try? fm.contentsOfDirectory(atPath: tmp + "/.work")) ?? []
        guard p.terminationStatus == 0, let id = takes.first else {
            add(.fail, "capture: a 3 s recording failed (exit \(p.terminationStatus)). Grant Microphone and Screen Recording to the app you run this from, in System Settings > Privacy & Security.")
            return
        }
        for t in ["mic", "system"] {
            let frames = ((try? WavPeak.info(path: tmp + "/.work/\(id)/\(t).wav"))?.dataBytes ?? 0) / 2
            add(frames > 0 ? .pass : .fail, "capture: \(t) track recorded \(frames) frames in 3 s" + (frames > 0 ? "" : ". Check the \(t == "mic" ? "Microphone" : "Screen Recording") grant."))
        }
    }

    func worker() {
        if knobs.noLaunchctl { add(.warn, "worker: launchd checks skipped (test mode)"); return }
        let (rc, _) = LaunchAgent.launchctl(["print", "gui/\(getuid())/\(LaunchAgent.label)"])
        guard rc == 0 else {
            add(.fail, "worker: not loaded. Install it with: meeting-transcribe --install-worker --output-dir <dir>")
            return
        }
        let pl = (fm.contents(atPath: LaunchAgent.plistPath)).flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) } as? [String: Any]
        let prog = (pl?["ProgramArguments"] as? [String])?.first
        add(prog == LaunchAgent.installedBinary ? .pass : .fail,
            "worker: loaded, plist runs \(prog ?? "nothing")" + (prog == LaunchAgent.installedBinary ? "" : ", expected \(LaunchAgent.installedBinary)"))
        let installed = LaunchAgent.sha256(ofFile: LaunchAgent.installedBinary)
        let mine = LaunchAgent.sha256(ofFile: ownBinary)
        if installed == mine {
            add(.pass, "worker: the installed binary matches this build")
        } else {
            add(.warn, "worker: the installed binary differs from this build. Reinstall with: meeting-transcribe --install-worker --output-dir \(outputDir ?? "<dir>")")
        }
    }

    func disk(_ d: String) {
        let free = (try? URL(fileURLWithPath: d).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage ?? 0
        let gb = Double(free) / 1e9
        add(gb >= 2 ? .pass : .warn, String(format: "disk: %.1f GB free at the output dir", gb)
            + (gb >= 2 ? "" : ". Under 2 GB: a 4 h take is about 0.9 GB of audio."))
    }

    /// Failed takes keep their audio forever. Listed after 7 days, never deleted here.
    func oldFailures(_ d: String) {
        let work = d + "/.work"
        let week = Date().addingTimeInterval(-7 * 86_400)
        var old: [String] = []
        for id in (try? fm.contentsOfDirectory(atPath: work)) ?? [] where !id.hasPrefix(".") {
            for m in Marker.terminal where m != Marker.transcribed {
                if let t = (try? fm.attributesOfItem(atPath: "\(work)/\(id)/\(m)"))?[.modificationDate] as? Date, t < week {
                    old.append(id)
                }
            }
        }
        if old.isEmpty { add(.pass, "failed takes: none older than 7 days"); return }
        add(.warn, "failed takes: \(old.count) older than 7 days still hold audio. Retry with --requeue <id>, or delete with: rm -rf \(old.map { "'\(work)/\($0)'" }.joined(separator: " "))")
    }

    /// PAID. About 5 s of synthesised speech, uploaded and checked for a known word.
    func liveRoundTrip(_ key: String) {
        let word = "pineapple"
        let tmp = NSTemporaryDirectory() + "meeting-transcribe-live-\(getpid())"
        defer { try? fm.removeItem(atPath: tmp) }
        let id = "doctor-live-\(getpid())"
        let take = tmp + "/.work/" + id
        try? fm.createDirectory(atPath: take, withIntermediateDirectories: true)
        func sh(_ exe: String, _ a: [String]) -> Int32 {
            let p = Process(); p.executableURL = URL(fileURLWithPath: exe); p.arguments = a
            p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return 127 }
            p.waitUntilExit(); return p.terminationStatus
        }
        guard sh("/usr/bin/say", ["-o", tmp + "/speech.aiff", "Testing the transcription. The word is \(word). One two three."]) == 0,
              sh("/usr/bin/afconvert", ["-f", "WAVE", "-d", "LEI16@16000", "-c", "1", tmp + "/speech.aiff", take + "/mic.wav"]) == 0 else {
            add(.fail, "live: could not synthesise test speech with say and afconvert"); return
        }
        let manifest: [String: Any] = ["schema": 2, "meeting_id": id, "label": "doctor live", "source": "mic",
                                       "started_at": ISO8601DateFormatter().string(from: Date()),
                                       "tracks": ["mic": ["path": "mic.wav", "host": true, "speaker": "Doctor"]]]
        guard let md = try? JSONSerialization.data(withJSONObject: manifest),
              (try? md.write(to: URL(fileURLWithPath: take + "/manifest.json"))) != nil else {
            add(.fail, "live: could not write the test manifest"); return
        }
        let rc = TakeTranscriber(manifestPath: take + "/manifest.json", env: env).run()
        let text = (try? String(contentsOfFile: OutputNames.transcriptPath(outputDir: tmp, label: "doctor live", meetingID: id), encoding: .utf8)) ?? ""
        if rc == 0 && text.lowercased().contains(word) {
            add(.pass, "live: a 5 s round trip came back with the word \"\(word)\" (paid, about 5 s of audio)")
        } else {
            add(.fail, "live: exit \(rc), the word \"\(word)\" \(text.isEmpty ? "and no transcript" : "not in the transcript")")
        }
    }

    /// Runs inside the one-shot LaunchAgent. Writes found or missing, NEVER the key.
    public static func keyProbe(resultFile: String) -> Int32 {
        let r = KeySource.keychain() == nil ? "missing" : "found"
        FileManager.default.createFile(atPath: resultFile, contents: Data((r + "\n").utf8))
        return 0
    }
}
