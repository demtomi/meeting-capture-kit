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
  meeting-transcribe --doctor [--live]      Check the setup. --live spends credits.

<dir> defaults to the output_dir in ~/.config/meeting-capture/config.json.

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

/// The first positional argument after `flag`, else the configured output dir.
func outputDir(after flag: String, skip: Int = 0) -> String {
    let i = args.firstIndex(of: flag)!
    let positional = args[(i + 1)...].filter { !$0.hasPrefix("-") }
    let rest = Array(positional.dropFirst(skip))
    if let d = rest.first ?? config.output_dir {
        return (d as NSString).expandingTildeInPath
    }
    err("no output dir given and none in \(UserPaths.configFile). Pass it: meeting-transcribe \(flag) <dir>")
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

if args.contains("--consent-upload") {
    // NAIVE until step 11.
    try? Consent.write(Consent.currentRecord())
    exit(0)
}

guard args.count == 1, !args[0].hasPrefix("-") else {
    err("unknown arguments: \(args.joined(separator: " ")). Run meeting-transcribe --help")
    exit(ExitCode.badArguments)
}
exit(TakeTranscriber(manifestPath: args[0], env: env).run())
