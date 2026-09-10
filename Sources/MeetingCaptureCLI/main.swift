// meeting-capture: dual-track capture CLI.
// Records mic (host) + system (remote) on separate tracks, writes 16 kHz mono
// PCM WAVs plus a manifest describing them, then optionally hands that manifest to
// an executable you name. No bot joins the call and nothing leaves the machine.
//
//   meeting-capture --label weekly-sync                 # record until Enter or Ctrl-C
//   meeting-capture --label smoke --seconds 6           # fixed length
//   meeting-capture --label standup --source mic        # in person, one speaker
//   meeting-capture --label board --source mic-multi    # in person, several speakers
//
// `--help` carries the authoritative flag list. Keep it and this block in step.
import Foundation
import CaptureIO
import SilenceGate

extension String {
    var expandingTildeInPath: String { (self as NSString).expandingTildeInPath }
}

// Stop flag: written by the SIGINT handler (async-signal-safe: only a sig_atomic_t
// store) and by the Enter-reader thread; polled by the main thread. No DispatchSource
// signal source — that trips a Swift-concurrency executor assertion on macOS 26.
nonisolated(unsafe) var stopRequested: sig_atomic_t = 0

// ---- args ----------------------------------------------------------------
/// The value that follows `name`, or nil.
///
/// REFUSES a value that is itself a flag. `--label --keep-audio` used to produce a
/// recording cheerfully labelled `"--keep-audio"`, with `--keep-audio` then also
/// read as set, so one typo silently changed two things at once.
func argVal(_ name: String) -> String? {
    let a = CommandLine.arguments
    guard let i = a.firstIndex(of: name), i + 1 < a.count else { return nil }
    let v = a[i + 1]
    if v.hasPrefix("-") && v.count > 1 {
        FileHandle.standardError.write("\(name) expects a value but was followed by \(v).\n".data(using: .utf8)!)
        exit(2)
    }
    return v
}
func hasFlag(_ name: String) -> Bool { CommandLine.arguments.contains(name) }

let usage = """
meeting-capture — dual-track meeting recorder for macOS.

Records the microphone (you) and system audio (everyone else) as two separate
16 kHz mono WAV files plus a manifest describing them. Nothing joins the call
and no audio leaves the machine.

USAGE
  meeting-capture --label <name> [options]

OPTIONS
  --label <name>          Name for this recording. Used in the output path.
  --source <mode>         mic+system (default) | mic | mic-multi
                          mic+system  both sides, for a virtual call
                          mic         one microphone, one speaker
                          mic-multi   one microphone, several people in the room
  --capture <mode>        sck (default) | tap
                          sck  ScreenCaptureKit. Works with Bluetooth output.
                          tap  Core Audio process tap. Wired or built-in output.
  --seconds <n>           Stop after n seconds. Default: run until you stop it.
  --host <name>           Speaker label for the mic track. Default: your account name.
  --lang <code>           Advisory language hint, written to the manifest.
  --speakers <n>          Advisory head count for mic-multi, written to the manifest.
  --mic-device <name>     Substring of the microphone to use. Default: the built-in one.
  --output-dir <path>     Where recordings go. Default: ~/Documents/MeetingCaptures
  --transcriber <path>    Executable to run when recording stops. It receives the
                          manifest path as its only argument. Default: none, in which
                          case the run ends with the audio and manifest on disk.
  --foreground            Do not run the transcriber under background QoS.
  --keep-audio            Keep the raw WAVs after a successful transcriber run.
  --auto-stop             Stop on your behalf when the meeting is clearly over.
                          On a call that means the far side has been silent long
                          enough that they have hung up. It never stops while you
                          are still talking, and it warns before it acts.
  --help, -h              This text.

PERMISSIONS
  Microphone is always required. Screen Recording is required for --source
  mic+system in the default sck mode. Granted to the app you launch this from,
  which when run from a terminal is the terminal itself.

EXAMPLES
  meeting-capture --label weekly-sync
  meeting-capture --label standup --source mic --seconds 300
  meeting-capture --label board --source mic-multi --speakers 4
  meeting-capture --label client-call --transcriber ~/bin/transcribe.sh
"""

if hasFlag("--help") || hasFlag("-h") {
    print(usage)
    exit(0)
}

// Every flag this CLI understands. An unrecognised argument is a REFUSAL and not a
// silently ignored one: a typo in `--seconds` used to produce an unbounded recording,
// and a typo in `--capture` used to select a capture backend the user did not ask for.
let valuedFlags: Set<String> = [
    "--label", "--source", "--capture", "--seconds", "--host", "--lang",
    "--speakers", "--mic-device", "--output-dir", "--transcriber",
]
let booleanFlags: Set<String> = ["--foreground", "--keep-audio", "--auto-stop", "--help", "-h"]

do {
    var i = 1
    let a = CommandLine.arguments
    while i < a.count {
        let arg = a[i]
        if booleanFlags.contains(arg) { i += 1; continue }
        if valuedFlags.contains(arg) {
            guard i + 1 < a.count else {
                FileHandle.standardError.write("\(arg) needs a value. Run --help.\n".data(using: .utf8)!)
                exit(2)
            }
            i += 2; continue
        }
        FileHandle.standardError.write("unknown argument: \(arg)\nRun meeting-capture --help for the accepted options.\n".data(using: .utf8)!)
        exit(2)
    }
}

// Efficiency-core count (Apple Silicon perflevel1). Used to cap the engine's
// intra-op threads when it runs under background QoS. Falls back to half the
// logical cores on hardware without perf levels.
func efficiencyCoreCount() -> Int {
    var n: Int32 = 0
    var size = MemoryLayout<Int32>.size
    if sysctlbyname("hw.perflevel1.logicalcpu", &n, &size, nil, 0) == 0, n > 0 {
        return Int(n)
    }
    return max(2, ProcessInfo.processInfo.activeProcessorCount / 2)
}

let label = argVal("--label") ?? ""
// The mic track's speaker label. Defaults to this account's full name so a first
// run produces a correctly-labelled transcript with no configuration.
let host = argVal("--host") ?? {
    let n = NSFullUserName()
    return n.isEmpty ? "Host" : n
}()
let langHint = argVal("--lang")                       // optional; engine auto-detects if absent
let source = argVal("--source") ?? "mic+system"       // "mic+system" | "mic" | "mic-multi"
let captureMode = argVal("--capture") ?? "sck"        // "sck" (Bluetooth-safe) | "tap" (speakers/wired)
guard captureMode == "sck" || captureMode == "tap" else {
    FileHandle.standardError.write("--capture must be 'sck' or 'tap', got: \(captureMode)\n".data(using: .utf8)!)
    exit(2)
}
let seconds: Double? = {
    guard let raw = argVal("--seconds") else { return nil }
    guard let v = Double(raw), v > 0 else {
        FileHandle.standardError.write("--seconds must be a positive number, got: \(raw)\n".data(using: .utf8)!)
        exit(2)
    }
    return v
}()
let expectedSpeakers: Int? = {
    guard let raw = argVal("--speakers") else { return nil }
    guard let v = Int(raw), v > 0 else {
        FileHandle.standardError.write("--speakers must be a positive whole number, got: \(raw)\n".data(using: .utf8)!)
        exit(2)
    }
    return v
}()   // in-person head count (mic-multi)
let autoStop = hasFlag("--auto-stop")
let keepAudio = hasFlag("--keep-audio")
    || ProcessInfo.processInfo.environment["MEETING_CAPTURE_KEEP_AUDIO"] != nil
// An optional post-capture step. `meeting-capture` itself never transcribes: it hands
// the manifest path to whatever executable you name here, as that executable's last
// argument. Absent, the run stops once the audio and manifest are on disk.
let micDeviceHint = argVal("--mic-device")
let transcriber = argVal("--transcriber").map { $0.expandingTildeInPath }
let outputDir = (argVal("--output-dir") ?? "~/Documents/MeetingCaptures").expandingTildeInPath

guard source == "mic+system" || source == "mic" || source == "mic-multi" else {
    FileHandle.standardError.write("--source must be 'mic+system', 'mic', or 'mic-multi'\n".data(using: .utf8)!)
    exit(2)
}
// mic-multi captures the same single mic track as mic; only the manifest source
// differs, telling the engine to diarize the mic track (in-person multi-party).
let wantSystem = (source == "mic+system")

// ---- ids / paths ---------------------------------------------------------
let now = Date()
let utc = DateFormatter()
utc.locale = Locale(identifier: "en_US_POSIX")
utc.timeZone = TimeZone(identifier: "UTC")
utc.dateFormat = "yyyy-MM-dd'T'HH-mm-ss'Z'"
let suffix = String(format: "%04x", UInt16.random(in: 0...0xffff))
let meetingID = "\(utc.string(from: now))-\(suffix)"

let iso = ISO8601DateFormatter()
iso.timeZone = TimeZone.current
iso.formatOptions = [.withInternetDateTime]
let startedAt = iso.string(from: now)

let workDir = "\(outputDir)/.work/\(meetingID)"
// Not `try?`. A bad --output-dir used to produce a full recording, a reported
// duration, and no file anywhere on disk.
do {
    try FileManager.default.createDirectory(atPath: workDir, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)
} catch {
    FileHandle.standardError.write("cannot create output directory \(outputDir): \(error.localizedDescription)\n".data(using: .utf8)!)
    exit(1)
}
let micPath = "\(workDir)/mic.wav"
let systemPath = "\(workDir)/system.wav"

// ---- capture -------------------------------------------------------------
FileHandle.standardError.write("[meeting-capture] meeting \(meetingID) — source=\(source)\n".data(using: .utf8)!)

let sharedStartNs = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)
// Runs on every exit(), including the argument and write-failure refusals above,
// so a Core Audio aggregate device is never left behind on the user's machine.
atexit { SystemTap.cleanupAll() }

let mic = MicCapture()
mic.deviceHint = micDeviceHint

// Samples are written to these as they arrive, so resident memory stays flat no
// matter how long the meeting runs. They live in the work directory beside the WAVs
// they become, and they are removed once the WAV is written.
let micSink: SampleSink?
let sysSink: SampleSink?
do {
    micSink = try SampleSink(directory: workDir, name: "mic-raw")
    sysSink = wantSystem ? try SampleSink(directory: workDir, name: "system-raw") : nil
} catch {
    FileHandle.standardError.write("could not open the capture scratch files: \(error)\n".data(using: .utf8)!)
    exit(1)
}
mic.sink = micSink
micSink?.start()
sysSink?.start()
let tap: SystemCapturer? = wantSystem ? (captureMode == "tap" ? SystemTap() as SystemCapturer : SystemCaptureSCK() as SystemCapturer) : nil
tap?.sink = sysSink
if wantSystem {
    FileHandle.standardError.write("[meeting-capture] system capture mode: \(captureMode == "tap" ? "process tap" : "ScreenCaptureKit")\n".data(using: .utf8)!)
}

do {
    try mic.start()
    try tap?.start()
} catch {
    FileHandle.standardError.write("capture start failed: \(error)\n".data(using: .utf8)!)
    mic.stop(); tap?.stop()
    exit(1)
}

// INSTALLED THE INSTANT A DEVICE EXISTS, and not one statement later.
//
// `tap.start()` creates a private Core Audio aggregate device. Until a handler is
// installed, SIGINT keeps its default disposition and kills the process outright,
// which skips `atexit` and leaves that aggregate device behind in the user's audio
// configuration for them to find and delete by hand. Every statement between the
// device being created and this line is a window where that happens.
//
// Deliberately NOT installed earlier. Before this point the only thing that can
// block is the microphone permission dialog, no device exists yet, and turning
// Ctrl-C into a flag nobody is polling would leave the user unable to abort at all.
//
// The handler does the least it can: one `sig_atomic_t` store, which is all that is
// async-signal-safe. Core Audio teardown happens on the normal path or in `atexit`.
signal(SIGINT) { _ in stopRequested = 1 }
signal(SIGTERM) { _ in stopRequested = 1 }

// A Ctrl-C that landed during startup still counts.
if stopRequested != 0 {
    mic.stop(); tap?.stop()
    FileHandle.standardError.write("[meeting-capture] interrupted during startup, nothing recorded.\n".data(using: .utf8)!)
    exit(130)
}

// Emitted from BOTH arms. It used to be written only in the interactive loop, so a
// `--seconds` run produced no level trace at all, which is the one input SilenceGate
// consumes. A fixed-length run is exactly the case you would replay.
//
// Both peaks are destructive reads (peak since the last take), so always take both and
// never short-circuit, or the untaken track's peak leaks into the next tick.
//
// `sys=` is OMITTED when there is no system capturer at all, so a MISSING track can be
// told from a SILENT one. Those must never look alike: a missing track is an in-person
// recording, a silent one is a call that has ended.
// `--auto-stop` wires the SilenceGate library to the readings below.
//
// Without it this CLI only PRINTS the levels and leaves the decision to whoever is
// reading stderr. The gate is the piece that knows a recording running past the end
// of a call costs money at whatever you pay per transcribed minute, and it knows the
// two mistakes to avoid: never stop while the host is still speaking, and never treat
// an ABSENT system track as a silent one, which would stop every in-person recording
// immediately.
//
// `isVirtual` follows the capture mode, because in person there is no far side whose
// silence could mean the meeting ended.
var gate: SilenceGate? = {
    guard autoStop else { return nil }
    var cfg = SilenceGate.Config()
    cfg.isVirtual = wantSystem
    return SilenceGate(config: cfg)
}()
var warned = false
let captureStart = Date()

func emitLevelLine() {
    let micLvl = mic.takeLevelPeak()
    let sysLvl = tap?.takeLevelPeak()
    var line = String(format: "[level] mic=%.4f", micLvl)
    if let sysLvl { line += String(format: " sys=%.4f", sysLvl) }
    FileHandle.standardError.write((line + "\n").data(using: .utf8)!)

    guard gate != nil else { return }
    let t = Date().timeIntervalSince(captureStart)
    gate!.note(LevelSample(mic: micLvl, sys: sysLvl), at: t)
    switch gate!.decide(at: t) {
    case .keepGoing:
        break
    case .warn:
        if !warned {
            warned = true
            FileHandle.standardError.write("[meeting-capture] nobody has made a sound for a while. --auto-stop will end this recording shortly.\n".data(using: .utf8)!)
        }
    case .stop:
        FileHandle.standardError.write("[meeting-capture] --auto-stop: the meeting looks over. Stopping and keeping everything recorded so far.\n".data(using: .utf8)!)
        stopRequested = 1
    }
}

if let s = seconds {
    FileHandle.standardError.write("[meeting-capture] recording \(s)s (Ctrl-C stops early and keeps the take) ...\n".data(using: .utf8)!)
    let deadline = Date().addingTimeInterval(s)
    var ticks = 0
    while Date() < deadline && stopRequested == 0 {
        Thread.sleep(forTimeInterval: 0.1)
        ticks += 1
        if ticks % 50 == 0 { emitLevelLine() }
    }
} else {
    FileHandle.standardError.write("[meeting-capture] recording — press Enter or Ctrl-C to stop.\n".data(using: .utf8)!)
    Thread.detachNewThread { _ = readLine(); stopRequested = 1 }
    // Emit peak-audio-level lines every ~5 s so the app can detect dead air and
    // offer to auto-stop a forgotten recording. PER TRACK, not a max.
    //
    // This used to emit max(mic, system) as one number, to keep "you listening on a
    // call" (system active, mic quiet) counting as activity. That case still works —
    // but the max collapsed away the signal that actually ends a meeting. On a
    // virtual call the SYSTEM track going flat IS the end: the remote hung up.
    // Measured 2026-07-27 on a 50-min take whose call ended at 21:12 — the system
    // track read a hard 0.0000 for the next 343 consecutive blocks while room noise
    // on the mic held the combined level alive, so the recording ran 28.6 min past
    // the end and uploaded ~19,000 credits of silence.
    //
    // The `sys=` field is OMITTED when there is no system capturer at all, so the
    // app can tell a MISSING track from a SILENT one. Those must never look alike:
    // a missing track is an in-person recording, a silent one is a finished call.
    var ticks = 0
    while stopRequested == 0 {
        Thread.sleep(forTimeInterval: 0.1)
        ticks += 1
        if ticks % 50 == 0 { emitLevelLine() }
    }
}

mic.stop(); tap?.stop()
FileHandle.standardError.write("[meeting-capture] stopped — finalizing audio ...\n".data(using: .utf8)!)

// ---- finalize tracks -----------------------------------------------------
// Lead padding exists so two tracks share one zero. With only one track there is
// nothing to align to, and padding from process start to the first buffer just
// prepends the audio device's warm-up as silence, which shifts every timestamp in
// the resulting transcript. Measured at 2.7 s on a built-in microphone, so a 3 s
// recording came out 5.7 s long.
let micZeroNs = wantSystem ? sharedStartNs : mic.firstBufferNs

/// Flush a track's scratch file, resample it to 16 kHz and write the WAV, holding one
/// chunk at a time rather than the whole meeting.
func finalize(_ sink: SampleSink?, firstBufferNs: UInt64, zeroNs: UInt64,
              nativeRate: Double, to path: String, what: String) -> Double {
    guard let sink else { return 0 }
    do {
        try sink.finish()
    } catch {
        FileHandle.standardError.write("could not save the \(what) capture: \(error)\n".data(using: .utf8)!)
        exit(1)
    }
    if sink.totalFrames == 0 {
        FileHandle.standardError.write("WARNING: \(what) captured 0 frames.\n".data(using: .utf8)!)
    }
    let leadNs = firstBufferNs > zeroNs ? firstBufferNs - zeroNs : 0
    let leadFrames = Int((Double(leadNs) / 1_000_000_000.0) * nativeRate)
    do {
        let d = try Audio.streamResampleToWav(rawURL: sink.url, nativeRate: nativeRate,
                                              leadFrames: leadFrames, to: path)
        // The scratch file has served its purpose. Keeping it would double the disk
        // cost of every recording, at the native rate rather than the written one.
        try? FileManager.default.removeItem(at: sink.url)
        return d
    } catch {
        // Deliberately NOT deleted on failure. The raw samples are the only copy of
        // the meeting, and a resample that failed can be retried against them.
        FileHandle.standardError.write("could not write \(path): \(error)\n  The raw capture is kept at \(sink.url.path)\n".data(using: .utf8)!)
        exit(1)
    }
}

let micDur = finalize(micSink, firstBufferNs: mic.firstBufferNs, zeroNs: micZeroNs,
                      nativeRate: mic.nativeRate, to: micPath, what: "microphone")
var sysDur = 0.0
if let tap {
    sysDur = finalize(sysSink, firstBufferNs: tap.firstBufferNs, zeroNs: sharedStartNs,
                      nativeRate: tap.nativeRate, to: systemPath, what: "system audio")
}
FileHandle.standardError.write(String(format: "[meeting-capture] mic %.1fs, system %.1fs\n", micDur, sysDur).data(using: .utf8)!)

// ---- manifest ------------------------------------------------------------
var tracks: [String: Any] = [
    "mic": ["path": "mic.wav", "host": true, "speaker": host]
]
if wantSystem { tracks["system"] = ["path": "system.wav", "host": false] }

var manifest: [String: Any] = [
    "schema": 1,
    "meeting_id": meetingID,
    "label": label,
    "source": source,
    "started_at": startedAt,
    "shared_start_monotonic_ns": sharedStartNs,
    "tracks": tracks,
    "output_dir": outputDir,
]
if let langHint { manifest["language_hint"] = langHint }
// In-person head count → pins pyannote to exactly N speakers (a single room mic
// over-splits otherwise). Only meaningful for mic-multi; harmless elsewhere.
if let expectedSpeakers, source == "mic-multi" { manifest["expected_speakers"] = expectedSpeakers }

let manifestPath = "\(workDir)/manifest.json"
let manifestData = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
// .atomic (temp file + rename): the manifest is the "capture complete" sentinel
// the transcribe-watch worker keys on, and WatchPaths can fire mid-write — a
// truncated manifest would be picked up as a completed take and fail parsing.
try manifestData.write(to: URL(fileURLWithPath: manifestPath), options: [.atomic])
FileHandle.standardError.write("[meeting-capture] wrote \(manifestPath)\n".data(using: .utf8)!)

// ---- post-capture handoff ------------------------------------------------
// Nothing here knows what a transcript is. It runs the executable you named with
// `--transcriber`, passing the manifest path, and reports its exit status as its
// own. No transcriber named means the run is complete: the audio and the manifest
// are on disk and any tool can consume them from there.
guard let transcriber else {
    FileHandle.standardError.write("[meeting-capture] done. Audio and manifest are in \(workDir)\n  Pass --transcriber <executable> to run a transcription step automatically.\n".data(using: .utf8)!)
    exit(0)
}
guard FileManager.default.isExecutableFile(atPath: transcriber) else {
    FileHandle.standardError.write("--transcriber is not an executable file: \(transcriber)\n".data(using: .utf8)!)
    exit(1)
}
let proc = Process()
proc.currentDirectoryURL = URL(fileURLWithPath: outputDir)
// A transcription tool commonly shells out to `ffmpeg`. When this CLI is launched
// from a GUI app the inherited PATH is minimal and Homebrew is not on it, so the
// child fails to find its own dependencies. Prepend the common prefixes so the
// handoff behaves the same from a terminal and from an app bundle.
var childEnv = ProcessInfo.processInfo.environment
let basePath = childEnv["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
childEnv["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + basePath

// Transcription is CPU-heavy and, unthrottled, pins one worker per performance
// core, so it fights whatever is in the foreground. Two throttles, both opt-out:
//   1. Background QoS via `taskpolicy -b` (PRIO_DARWIN_BG, inherited by every
//      child thread), so the OS schedules it on efficiency cores and lets
//      foreground work preempt it.
//   2. OMP_NUM_THREADS capped to the efficiency-core count, so it does not
//      oversubscribe the cores it has been confined to.
// `--foreground` opts out of both, for an unattended machine.
let taskpolicy = "/usr/sbin/taskpolicy"
let throttle = !hasFlag("--foreground")
    && FileManager.default.isExecutableFile(atPath: taskpolicy)
if throttle {
    let threads = efficiencyCoreCount()
    childEnv["OMP_NUM_THREADS"] = String(threads)
    proc.executableURL = URL(fileURLWithPath: taskpolicy)
    proc.arguments = ["-b", transcriber, manifestPath]
    FileHandle.standardError.write("[meeting-capture] running \(transcriber) under background QoS (taskpolicy -b, \(threads) threads) ...\n".data(using: .utf8)!)
} else {
    proc.executableURL = URL(fileURLWithPath: transcriber)
    proc.arguments = [manifestPath]
    FileHandle.standardError.write("[meeting-capture] running \(transcriber) ...\n".data(using: .utf8)!)
}
proc.environment = childEnv
do {
    try proc.run()
    proc.waitUntilExit()
    let status = proc.terminationStatus
    // Data minimisation: once the transcriber has succeeded, the raw capture audio
    // is no longer needed, so the workdir (both WAVs plus the manifest) is deleted.
    // On failure it is kept so the step can be retried against the same audio.
    // `--keep-audio`, or MEETING_CAPTURE_KEEP_AUDIO in the environment, opts out.
    if status == 0 && !keepAudio {
        try? FileManager.default.removeItem(atPath: workDir)
    }
    exit(status)
} catch {
    FileHandle.standardError.write("transcriber launch failed: \(error)\n".data(using: .utf8)!)
    exit(1)
}
