// meeting-transcribe: the reference transcriber and queue worker for meeting-capture.
//
// `meeting-transcribe --help` carries the authoritative command list.
import Foundation
import NotetakerCore

let args = Array(CommandLine.arguments.dropFirst())
func say(_ s: String) { print(s) }
func err(_ s: String) { stderrLine(s) }

let usage = """
meeting-transcribe: transcribe meeting-capture recordings with ElevenLabs, on your own key.

USAGE
  meeting-transcribe <manifest.json>        Transcribe one take. Exit codes below.
  meeting-transcribe --drain [<dir>]        Transcribe every completed take in <dir>/.work,
                                            oldest first. This is what the worker runs.
  meeting-transcribe --status [<dir>]       List takes: pending, claimed, cooling down,
                                            failed (with the reason) or paused.
  meeting-transcribe --requeue <id> [<dir>] Clear a take's failure marker and attempt count.
  meeting-transcribe --resume [<dir>]       Remove the pause file after an account-wide stop.
  meeting-transcribe --consent-upload       HUMAN ONLY. Read the disclosure and record consent.
                                            Refuses when stdin is not a terminal.
  meeting-transcribe --revoke-consent       Delete the consent file. Nothing uploads after this.
  meeting-transcribe --install-worker --output-dir <dir>
                                            Install the background worker (needs consent).
  meeting-transcribe --uninstall-worker [--revoke-consent]
  meeting-transcribe --doctor [--live] [--output-dir <dir>] [--no-capture-probe]
                                            Check the setup. --live spends credits.
                                            --no-capture-probe skips the 3 s test recording.

<dir> is --output-dir <dir> or the positional <dir>, else the output_dir in
~/.config/meeting-capture/config.json. With none of those the command refuses.

OPTIONS FOR --drain
  --transcriber <path>   Run this executable per take instead of meeting-transcribe itself.
  --keep-audio           Keep the audio after a proven transcript (also MEETING_CAPTURE_KEEP_AUDIO).

EXIT CODES (one take)
  0 transcript written   1 transient, retry later   2 bad arguments
  3 this take can never succeed   4 every track digitally silent
  5 account-wide stop: key, quota, balance, plan or consent   6 another runner holds the take
"""

if args.isEmpty || args.contains("--help") || args.contains("-h") {
    say(usage)
    exit(args.isEmpty ? ExitCode.badArguments : ExitCode.ok)
}

let env = RuntimeEnv.fromProcess()
let loopback = APIBase.resolve(override: env.apiBaseOverride).0?.isLoopback == true
let knobs = loopback ? env.testKnobs : TestKnobs()
let config = WorkerConfig.load()

func value(after flag: String) -> String? {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count, !args[i + 1].hasPrefix("-") else { return nil }
    return args[i + 1]
}

/// Flags that take a value. The token after one of these is its value, never a positional.
let valuedFlags: Set<String> = ["--transcriber", "--output-dir", "--key-probe"]

/// Positional arguments after `flag`: every token that is not a flag and not the value of a
/// valued flag.
func positionals(after flag: String) -> [String] {
    let i = args.firstIndex(of: flag)!
    var out: [String] = []
    var j = i + 1
    while j < args.count {
        let a = args[j]
        if valuedFlags.contains(a) { j += 2; continue }
        if !a.hasPrefix("-") { out.append(a) }
        j += 1
    }
    return out
}

/// THE one output-dir resolver, used by every command: --output-dir, then a positional
/// argument after `flag`, then the configured output_dir. Nothing else: with none of those, a
/// command must refuse rather than run against a folder the person never chose.
func resolveOutputDir(after flag: String, skip: Int = 0) -> String? {
    let rest = Array(positionals(after: flag).dropFirst(skip))
    guard let d = value(after: "--output-dir") ?? rest.first ?? config.output_dir else { return nil }
    return URL(fileURLWithPath: (d as NSString).expandingTildeInPath).standardizedFileURL.path
}

/// The resolved dir, or a refusal (exit 2) for a command that cannot run without one.
func outputDir(after flag: String, skip: Int = 0) -> String {
    if let d = resolveOutputDir(after: flag, skip: skip) { return d }
    err("no output dir given and none in \(UserPaths.configFile). Pass it: meeting-transcribe \(flag) --output-dir <dir>")
    exit(ExitCode.badArguments)
}

// A valued flag must carry its value. Dropping a trailing --output-dir silently would run the
// command against a different folder than the one the person typed.
for f in valuedFlags where args.contains(f) && value(after: f) == nil {
    err("\(f) needs a value. Run meeting-transcribe --help")
    exit(ExitCode.badArguments)
}

func ownPath() -> String {
    URL(fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0]).resolvingSymlinksInPath().path
}

func worker(_ dir: String) -> Worker {
    let keep = args.contains("--keep-audio") || ProcessInfo.processInfo.environment["MEETING_CAPTURE_KEEP_AUDIO"] != nil
        || (config.keep_audio ?? false)
    let transcriber = value(after: "--transcriber") ?? config.transcriber ?? ownPath()
    return Worker(outputDir: dir, transcriber: (transcriber as NSString).expandingTildeInPath,
                  keepAudio: keep, knobs: knobs, quietNotifications: loopback)
}

if args.contains("--drain") {
    Worker.rotateLog()
    exit(worker(outputDir(after: "--drain")).drain())
}
if args.contains("--status") {
    say(worker(outputDir(after: "--status")).status())
    exit(ExitCode.ok)
}
if args.contains("--requeue") {
    guard let id = value(after: "--requeue") else { err("usage: meeting-transcribe --requeue <id> [<dir>]"); exit(ExitCode.badArguments) }
    exit(worker(outputDir(after: "--requeue", skip: 1)).requeue(id))
}
if args.contains("--resume") {
    exit(worker(outputDir(after: "--resume")).resume())
}

if args.contains("--revoke-consent") && !args.contains("--uninstall-worker") {
    if FileManager.default.fileExists(atPath: UserPaths.consentFile) {
        try? FileManager.default.removeItem(atPath: UserPaths.consentFile)
        say("consent revoked: removed \(UserPaths.consentFile). Nothing will upload until a person consents again.")
    } else {
        say("no consent file at \(UserPaths.consentFile). Nothing to revoke.")
    }
    exit(ExitCode.ok)
}

/// Prints the disclosure and records consent. Refuses when stdin is not a terminal, so
/// an agent's non-interactive shell cannot consent on a person's behalf. A refusal, not a
/// prompt: a missing terminal can only mean less happens.
func recordConsent() -> Int32 {
    say(Consent.disclosureText)
    say("")
    guard KeySource.stdinIsTerminal else {
        err("--consent-upload refused: stdin is not a terminal. A person must run this command themselves, in a terminal, after reading the text above. No consent was recorded.")
        return ExitCode.badArguments
    }
    do { try Consent.write(Consent.currentRecord()) } catch {
        err("could not write \(UserPaths.consentFile): \(error)")
        return ExitCode.transient
    }
    say("consent recorded in \(UserPaths.consentFile) (disclosure \(Consent.disclosureHash.prefix(12)), version \(Consent.version)).")
    return ExitCode.ok
}

if args.contains("--consent-upload") && !args.contains("--install-worker") {
    exit(recordConsent())
}

if args.contains("--key-probe") {
    guard let f = value(after: "--key-probe") else { exit(ExitCode.badArguments) }
    exit(Doctor.keyProbe(resultFile: f))
}
if args.contains("--doctor") {
    let dir = resolveOutputDir(after: "--doctor")
    let d = Doctor(ownBinary: ownPath(), outputDir: dir, env: env, captureProbe: !args.contains("--no-capture-probe"))
    exit(d.run(live: args.contains("--live")))
}

if args.contains("--install-worker") {
    let dir = outputDir(after: "--install-worker")
    if args.contains("--consent-upload") {
        let rc = recordConsent()
        if rc != ExitCode.ok { exit(rc) }
    }
    guard Consent.state() == .valid else {
        LaunchAgent.dryRun(outputDir: dir).forEach(say)
        exit(ExitCode.accountStop)
    }
    let r = LaunchAgent.install(binary: ownPath(), outputDir: dir, loadAgent: !knobs.noLaunchctl)
    r.lines.forEach(say)
    exit(r.code)
}
if args.contains("--uninstall-worker") {
    let r = LaunchAgent.uninstall(revokeConsent: args.contains("--revoke-consent"), unloadAgent: !knobs.noLaunchctl)
    r.lines.forEach(say)
    exit(r.code)
}

guard args.count == 1, !args[0].hasPrefix("-") else {
    err("unknown arguments: \(args.joined(separator: " ")). Run meeting-transcribe --help")
    exit(ExitCode.badArguments)
}
exit(TakeTranscriber(manifestPath: args[0], env: env).run())
