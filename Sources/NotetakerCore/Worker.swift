// The queue worker: `meeting-transcribe --drain <dir>`.
//
// Completed takes under `<dir>/.work/` are transcribed oldest first, one at a time. A take
// is complete when its `manifest.json` exists, because the capture CLI writes it last and
// atomically. One failing take never blocks the ones behind it.
//
// What each transcriber exit does here:
//   0        delete the take ONLY if the transcript is proven on disk, else `.no-transcript`
//   1        one attempt used, retry after a 300 s cooldown, `.upload-failed` after 3
//   3        terminal: `.refused` (unless the transcriber wrote a more specific marker)
//   4        terminal: `.silent-capture`
//   5        account-wide: write the pause file with the reason, stop, use no attempt
//   6        another runner holds the take: skip it this drain, use no attempt
//   anything else (2, a signal death, ...) counts as an attempt and keeps the audio
import Foundation

public final class Worker {
    public static let maxAttempts = 3
    public static let cooldownSeconds: Double = 300
    public static let logRotateBytes: UInt64 = 5 * 1024 * 1024

    let layout: OutputLayout
    let transcriber: String
    let keepAudio: Bool
    let cooldown: Double
    let staleSeconds: Double
    let heartbeatSeconds: Double
    let quietNotifications: Bool
    let log: (String) -> Void
    let fm = FileManager.default

    public init(outputDir: String, transcriber: String, keepAudio: Bool, knobs: TestKnobs,
                quietNotifications: Bool, log: @escaping (String) -> Void = stderrLine) {
        self.layout = OutputLayout(root: outputDir)
        self.transcriber = transcriber
        self.keepAudio = keepAudio
        self.cooldown = knobs.cooldownSeconds ?? Self.cooldownSeconds
        self.staleSeconds = knobs.staleSeconds ?? TakeClaim.staleSeconds
        self.heartbeatSeconds = knobs.heartbeatSeconds ?? TakeClaim.heartbeatSeconds
        self.quietNotifications = quietNotifications
        self.log = { line in
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"
            log("\(f.string(from: Date())) \(line)")
        }
    }

    // ------------------------------------------------------------------ helpers
    func read(_ path: String) -> String? { try? String(contentsOfFile: path, encoding: .utf8) }

    func attempts(_ dir: String) -> (count: Int, last: Double) {
        // Split on any whitespace: the file ends in a newline, and a timestamp that fails to
        // parse reads as 0, which silently turns every cooldown into "due now".
        let parts = (read(dir + "/" + Marker.attempts) ?? "").split(whereSeparator: { $0.isWhitespace })
        return (Int(parts.first ?? "") ?? 0, Double(parts.dropFirst().first ?? "") ?? 0)
    }

    func terminalMarker(_ dir: String) -> String? {
        Marker.terminal.first { fm.fileExists(atPath: dir + "/" + $0) }
    }

    func takeIDs() -> [String] {
        // meeting_id starts with the UTC start stamp, so name order is age order.
        ((try? fm.contentsOfDirectory(atPath: layout.workDir)) ?? [])
            .filter { !$0.hasPrefix(".") && fm.fileExists(atPath: layout.take($0) + "/manifest.json") }
            .sorted()
    }

    /// The take's own keep decision, written by the capture CLI from --keep-audio.
    func manifestKeepsAudio(_ dir: String) -> Bool {
        (try? Manifest.load(path: dir + "/manifest.json"))?.keepAudio ?? false
    }

    func label(_ dir: String) -> String {
        let l = (try? Manifest.load(path: dir + "/manifest.json"))?.label ?? ""
        return l.isEmpty ? "meeting" : l
    }

    /// A macOS notification. The label is stripped of quote and backslash characters so it
    /// cannot break out of the AppleScript string.
    func notify(_ text: String) {
        let safe = text.replacingOccurrences(of: "\\", with: "").replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "\n", with: " ")
        log("notify: \(safe)")
        guard !quietNotifications else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", "display notification \"\(safe)\" with title \"meeting-transcribe\""]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try? p.run(); p.waitUntilExit()
    }

    func write(_ path: String, _ text: String) -> Bool {
        fm.createFile(atPath: path, contents: Data((text + "\n").utf8))
    }

    /// Keeps the log bounded: over 5 MB, the last 256 KB go to `<log>.1` and the log restarts.
    public static func rotateLog(_ path: String = UserPaths.logFile) {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? UInt64,
              size > logRotateBytes, let fh = FileHandle(forReadingAtPath: path) else { return }
        try? fh.seek(toOffset: size - 262_144)
        let tail = (try? fh.readToEnd()) ?? Data()
        try? fh.close()
        try? tail.write(to: URL(fileURLWithPath: path + ".1"))
        if let w = FileHandle(forWritingAtPath: path) { try? w.truncate(atOffset: 0); try? w.close() }
    }

    /// Runs the transcriber on one manifest. Returns its exit status (signal deaths as
    /// 128 + signal) and its last `reason:` line. Its output is copied into this log.
    func runTranscriber(_ manifest: String, id: String) -> (Int32, String, Bool) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: transcriber)
        p.arguments = [manifest]
        let out = NSTemporaryDirectory() + "meeting-transcribe-\(getpid())-\(id).log"
        fm.createFile(atPath: out, contents: nil)
        defer { try? fm.removeItem(atPath: out) }
        guard let h = FileHandle(forWritingAtPath: out) else { return (1, "cannot open a log for the transcriber", false) }
        p.standardOutput = h; p.standardError = h
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch {
            try? h.close()
            return (1, "cannot run \(transcriber): \(error)", false)
        }
        p.waitUntilExit()
        try? h.close()
        let text = read(out) ?? ""
        for line in text.split(separator: "\n") { log("  | \(line)") }
        let reason = text.split(separator: "\n").last { $0.hasPrefix("reason: ") }
            .map { String($0.dropFirst("reason: ".count)) } ?? ""
        let signalled = p.terminationReason == .uncaughtSignal
        return (signalled ? 128 + p.terminationStatus : p.terminationStatus, reason, signalled)
    }

    // ------------------------------------------------------------------ drain
    public func drain() -> Int32 {
        guard fm.fileExists(atPath: layout.workDir) else { return ExitCode.ok }
        try? fm.createDirectory(atPath: layout.stateDir, withIntermediateDirectories: true)
        let lock: TakeClaim
        switch TakeClaim.acquire(path: layout.drainLock, stale: staleSeconds, log: log) {
        case .held(let c): lock = c
        case .heldElsewhere(let why):
            log("another drain is running on \(layout.root) (\(why)). Exiting.")
            return ExitCode.heldElsewhere
        case .failed(let why):
            log("cannot take the drain lock: \(why)")
            return ExitCode.transient
        }
        lock.startHeartbeat(every: heartbeatSeconds)
        defer { lock.release() }

        var skip: Set<String> = []
        while true {
            // Checked before EVERY item, so a pause stops a drain that is already running.
            if fm.fileExists(atPath: layout.pauseFile) {
                log("paused (\(read(layout.pauseFile)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")). Resume with: meeting-transcribe --resume")
                break
            }
            let now = Date().timeIntervalSince1970
            guard let id = takeIDs().first(where: { id in
                let d = layout.take(id)
                if skip.contains(id) || terminalMarker(d) != nil { return false }
                let a = attempts(d)
                return !(a.count > 0 && now - a.last < cooldown)
            }) else { break }
            let dir = layout.take(id)
            let n = attempts(dir).count
            log("processing \(id) (attempt \(n + 1))")
            let (rc, reason, _) = runTranscriber(dir + "/manifest.json", id: id)
            let why = reason.isEmpty ? "exit \(rc)" : reason

            switch rc {
            case ExitCode.ok:
                if let failure = proveTake(manifestPath: dir + "/manifest.json", outputDir: layout.root) {
                    guard write(dir + "/" + Marker.noTranscript, "exit 0 but \(failure)") else { if takeGone(dir) { skipGone(id); continue }; return stopOnMarker(id) }
                    log("NO TRANSCRIPT \(id): the transcriber exited 0 but \(failure). Audio kept.")
                    notify("No transcript for \(label(dir)). Audio kept. See: meeting-transcribe --status")
                } else if keepAudio || manifestKeepsAudio(dir) {
                    guard write(dir + "/" + Marker.transcribed, "done, audio kept by keep-audio") else { if takeGone(dir) { skipGone(id); continue }; return stopOnMarker(id) }
                    try? fm.removeItem(atPath: dir + "/" + Marker.attempts)
                    log("done \(id), audio kept")
                    notify("Transcript ready: \(label(dir))")
                } else {
                    let l = label(dir)
                    if case .heldElsewhere(let why) = removeTakeHoldingClaim(dir, log: log) {
                        skip.insert(id)
                        log("transcript written for \(id), but another runner holds it (\(why)). Left for that runner.")
                        continue
                    }
                    log("done \(id)")
                    notify("Transcript ready: \(l)")
                }
            case ExitCode.accountStop:
                guard write(layout.pauseFile, why) else { return stopOnMarker(id) }
                log("PAUSED on \(id): \(why). No attempt used. Fix it, then: meeting-transcribe --resume")
                notify("Transcription paused: \(why). Fix it, then run meeting-transcribe --resume")
                return ExitCode.ok
            case ExitCode.heldElsewhere:
                skip.insert(id)
                log("skipped \(id): held by another runner. No attempt used.")
            case ExitCode.neverSucceeds:
                if terminalMarker(dir) == nil {
                    guard write(dir + "/" + Marker.refused, why) else { if takeGone(dir) { skipGone(id); continue }; return stopOnMarker(id) }
                }
                try? fm.removeItem(atPath: dir + "/" + Marker.attempts)
                log("REFUSED \(id): \(why). Audio kept. Retry with: meeting-transcribe --requeue \(id)")
                notify("\(label(dir)) cannot be transcribed: \(why). See: meeting-transcribe --status")
            case ExitCode.allSilent:
                guard write(dir + "/" + Marker.silentCapture, why) else { if takeGone(dir) { skipGone(id); continue }; return stopOnMarker(id) }
                try? fm.removeItem(atPath: dir + "/" + Marker.attempts)
                log("SILENT \(id): every track was digital silence. Check the input device. Audio kept.")
                notify("\(label(dir)) captured only silence. Check the input device.")
            default:
                let count = n + 1
                guard write(dir + "/" + Marker.attempts, "\(count) \(Int(Date().timeIntervalSince1970))") else {
                    if takeGone(dir) { skipGone(id); continue }
                    return stopOnMarker(id)
                }
                if count >= Self.maxAttempts {
                    guard write(dir + "/" + Marker.uploadFailed, why) else { if takeGone(dir) { skipGone(id); continue }; return stopOnMarker(id) }
                    try? fm.removeItem(atPath: dir + "/" + Marker.attempts)
                    log("FAILED \(id) after \(count) attempts (\(why)). Audio kept. Retry with: meeting-transcribe --requeue \(id)")
                    notify("Transcription failed for \(label(dir)). Retry with meeting-transcribe --requeue \(id)")
                } else {
                    log("attempt \(count) failed for \(id) (\(why)). Cooling down \(Int(cooldown)) s, other takes continue.")
                }
            }
        }
        return ExitCode.ok
    }

    /// A marker that cannot be written means the next pass would pick the same take and
    /// upload it again. Stop instead.
    /// Another deleter removed the take while this drain ran. Nothing to mark, nothing to redo.
    func takeGone(_ dir: String) -> Bool { !fm.fileExists(atPath: dir) }
    func skipGone(_ id: String) { log("take \(id) is gone (removed by another runner). Skipping it.") }

    func stopOnMarker(_ id: String) -> Int32 {
        log("cannot write a marker for \(id). Stopping so it is not uploaded again in a loop.")
        return ExitCode.transient
    }

    // ------------------------------------------------------------------ status and recovery
    public func status() -> String {
        var lines: [String] = []
        if fm.fileExists(atPath: layout.pauseFile) {
            let r = read(layout.pauseFile)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            lines.append("PAUSED: \(r)")
            lines.append("  resume with: meeting-transcribe --resume \(layout.root)")
        }
        let now = Date().timeIntervalSince1970
        let ids = takeIDs()
        if ids.isEmpty { lines.append("no takes waiting in \(layout.workDir)") }
        for id in ids {
            let d = layout.take(id)
            let state: String
            if let m = terminalMarker(d) {
                let r = read(d + "/" + m)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                state = m == Marker.transcribed ? "done (audio kept)"
                    : "failed \(m): \(r)  -> meeting-transcribe --requeue \(id) \(layout.root)"
            } else if let c = (try? fm.attributesOfItem(atPath: d + "/" + TakeClaim.fileName))?[.modificationDate] as? Date,
                      Date().timeIntervalSince(c) <= staleSeconds {
                state = "claimed (in progress, heartbeat \(Int(Date().timeIntervalSince(c))) s ago)"
            } else if case let a = attempts(d), a.count > 0 {
                let wait = max(0, Int(cooldown - (now - a.last)))
                state = wait > 0 ? "cooling down (attempt \(a.count) of \(Self.maxAttempts) failed, retry in \(wait) s)"
                                 : "pending (attempt \(a.count) of \(Self.maxAttempts) failed, due now)"
            } else if fm.fileExists(atPath: layout.pauseFile) {
                state = "paused"
            } else {
                state = "pending"
            }
            lines.append("\(id)  \(state)")
        }
        return lines.joined(separator: "\n")
    }

    public func requeue(_ id: String) -> Int32 {
        guard Manifest.isPlainComponent(id), fm.fileExists(atPath: layout.take(id)) else {
            log("no take \(id) in \(layout.workDir)")
            return ExitCode.badArguments
        }
        for m in Marker.terminal + [Marker.attempts] { try? fm.removeItem(atPath: layout.take(id) + "/" + m) }
        log("requeued \(id). The next drain will pick it up.")
        return ExitCode.ok
    }

    public func resume() -> Int32 {
        if fm.fileExists(atPath: layout.pauseFile) { try? fm.removeItem(atPath: layout.pauseFile) }
        log("resumed. The next drain runs the queue.")
        return ExitCode.ok
    }
}
