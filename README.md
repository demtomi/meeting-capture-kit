# MeetingCaptureKit

Dual-track meeting audio capture on macOS, an optional transcriber that runs on your own ElevenLabs key, and seven small libraries carved out of a private meeting-recorder app. To have a coding agent set the whole thing up, point it at [AGENTS.md](AGENTS.md).

The part worth your attention is `SystemTap`. It captures system audio with a Core Audio **process tap**: `AudioHardwareCreateProcessTap` wrapped in a private aggregate device with an `AudioDeviceIOProcID`. Apple ships no sample code for this path and the header documentation is thin. The public reference implementation most people find is [insidegui/AudioCap](https://github.com/insidegui/AudioCap), which is where to look for the same API in sample-code form. What this adds beside it is the aggregate being pinned to the current default output device, dual-track capture with a shared start, and a set of checks that run without any of the grants the capture itself needs. A ScreenCaptureKit path sits beside it as the default; see [Which backend](#where-the-tap-loses) for what that choice actually rests on.

**Every verification executable here runs with no microphone grant, no screen-recording grant, no display and no network**, which is what lets the whole suite run on a CI runner. `transcribe-check` opens one socket, a stub server on 127.0.0.1, and nothing else. See [Checks](#checks).

---

## What it does

`meeting-capture` records two audio tracks at once:

- **mic** through `AVCaptureSession`, the person at the keyboard
- **system** through the process tap or ScreenCaptureKit, everyone else on the call

It writes them as two separate 16 kHz mono PCM16 WAV files plus a `manifest.json` describing them. Nothing joins the call as a bot. `meeting-capture` itself sends no audio anywhere.

`meeting-capture` does **not** transcribe. When you pass `--transcriber <path>`, it runs that executable once with the manifest path as its only argument, and exits with that executable's status. With no `--transcriber`, the run ends with the audio and the manifest on disk. The separate `meeting-transcribe` in this package is one such executable, and it also runs as a background worker. See [Transcription](#transcription).

### Why two tracks and not one

A single mixed track forces a diarizer to separate two people who never overlap in the file. Two tracks make the host track free, and they keep one signal a mixed track destroys: on a virtual call, the **system track going flat means the other side hung up**. A mixed level reading keeps counting room noise as activity, and a recording left running past the end costs money at whatever you pay per transcribed minute. `SilenceGate` exists for that.

### Why a process tap is hard

Three things have to line up, and each fails quietly rather than loudly:

1. `AudioHardwareCreateProcessTap` gives you a tap object, not an audio stream. It has to be wrapped in an aggregate device before a single sample arrives.
2. The aggregate device has to be **pinned to the current default output device**, as both `kAudioAggregateDeviceMainSubDeviceKey` and a one-entry `kAudioAggregateDeviceSubDeviceListKey`. Skip the pin and a global tap records perfect silence whenever audio plays to a non-default route.
3. The aggregate device UID has to be unique per run. A fixed literal is a system-wide identifier, so two copies of the tool contend for one device.

`Sources/MeetingCaptureCLI/SystemTap.swift` carries all three, with the reasoning in comments.

### Where the tap loses

**This section used to say the tap returns silence on a Bluetooth route such as AirPods, and that this was why `sck` is the default. That claim did not survive being measured.** On macOS 26.6.2 with AirPods Pro as the default output device (`Transport: Bluetooth`, confirmed through `kAudioDevicePropertyTransportType`), `--capture tap` recorded speech at peak 0.7487 and rms 2486, with audio present in every one-second window from t=5 s to t=10 s of an 11.5 s take. The tap bound to the Bluetooth device and captured it.

What is still true is narrower, and it is the honest reason to keep both backends:

- **The tap's aggregate is pinned to the default output device at start.** `SystemTap.defaultOutputDevice()` reads it once. Change the output route mid-meeting and the tap keeps listening to the device you left. ScreenCaptureKit taps app audio before it reaches any output device, so a route change does not affect it.
- **The tap's first buffer can be late, and whatever played before it is gone.** The window between the shared start and the first delivered buffer is written as leading silence, and no track holds the audio from it. In the run measured above, speech that began about 2 s into the take first appears in `system.wav` at 5 s. That is one observation on one device and the startup cost of the Bluetooth route is not separated from the tap's own, so treat it as "this can be seconds", not as a figure.
- **They need different grants.** `sck` requires Screen Recording. Whether the tap demands its own grant is **untested** here (see [Permissions](#permissions)).

So `--capture sck` stays the default for the route-change case and the startup window, not for Bluetooth. If you have a Bluetooth route and the tap records silence for you, that is worth an issue with your macOS version and device — it is not the documented behaviour any more.

---

## Requirements

- **macOS 14.2 or later.** That is the `platforms:` floor in `Package.swift`. 14.2 is where `AudioHardwareCreateProcessTap` arrives, so the system-audio path sets the floor for everything. **What enforces it is the compiler, not SwiftPM.** `platforms:` is a deployment target, and a root package with no dependencies has no resolution-time host check to fail — setting the floor to a version *above* this host still builds at exit 0. Lower it to 13.0 and the build fails properly, with `'init(stereoGlobalTapButExcludeProcesses:)' is only available in macOS 14.0 or newer` from `SystemTap.swift:64` and `'microphone' is only available in macOS 14.0 or newer` from `MicCapture.swift:68`. Both measured on this package. The earlier claim here, that SwiftPM refuses to resolve on an older host, was wrong. Verified: the package builds clean and every check exits 0 at this deployment target, compiled and run on macOS 26. Not verified: whether the process tap behaves correctly at runtime on 14.x. If you are on 14 or 15 and the tap records silence, use `--capture sck` and file an issue with your version. Only `CaptureIO` and the CLI touch system audio. The other libraries carry no such doubt.
- **Swift 6 toolchain.** `swift-tools-version: 6.0`. The `MeetingCaptureCLI` target builds in Swift 5 language mode on purpose, because it bridges async ScreenCaptureKit and AVFoundation calls to a synchronous `main` through semaphores, and Swift 6 strict concurrency flags those patterns.
- **Command Line Tools are enough.** The checks are plain executables, not XCTest targets, so no full Xcode install is needed to run them.
- **Apple Silicon.** Built and run on Apple Silicon only. `efficiencyCoreCount()` reads `hw.perflevel1.logicalcpu` and falls back to half the logical cores when that sysctl is absent, so the Intel path should degrade rather than break, but **nothing here has been run on Intel** and no claim is made about it.

### Permissions (TCC)

| What | When | Notes |
|---|---|---|
| **Microphone** | Always | `MicCapture` checks `AVCaptureDevice.authorizationStatus(for: .audio)` and refuses to start when it is denied. On `notDetermined` it prompts and blocks on the answer. |
| **Screen Recording** | `--source mic+system` in the default `--capture sck` mode | ScreenCaptureKit needs it. Without it, `start()` throws with the System Settings path in the message. |

**The grant attaches to the app you launch from, not to the binary.** Run `meeting-capture` from Terminal and macOS records the grant against Terminal. Run it from iTerm2 and the grant belongs to iTerm2. Switch terminals and you grant again. After granting Screen Recording you have to restart the terminal app for the grant to take effect in a new process.

`--capture tap` with `--source mic+system` uses the Core Audio process tap, which this code never asks a TCC status for. What macOS 26 requires for `AudioHardwareCreateProcessTap` is **not verified here.** If the tap path prompts on your machine, or records silence without prompting, that is the thing to check first.

---

## Quick start

```bash
git clone <this-repo> meeting-capture-kit
cd meeting-capture-kit
swift build
```

Record six seconds off the microphone alone. This needs the Microphone grant and nothing else:

```bash
.build/debug/meeting-capture --label smoke-test --source mic --seconds 6
ls  ~/Documents/MeetingCaptures/.work/*/          # manifest.json  mic.wav
cat ~/Documents/MeetingCaptures/.work/*/manifest.json
```

Then record a real call, both sides. This one needs Screen Recording as well:

```bash
.build/debug/meeting-capture --label weekly-sync   # Enter or Ctrl-C to stop
```

Both WAVs and the manifest stay in `~/Documents/MeetingCaptures/.work/<meeting-id>/`. The work directory is only deleted when a `--transcriber` you named exited 0 **and** a transcript for that take is proven on disk (the [proof rule](#the-transcriber-contract)). `--keep-audio` opts out of even that. An exit 0 with no proven transcript keeps the audio and says why on stderr.

### Output layout

```
<output-dir>/
  .work/
    2026-09-10T08-14-02Z-4f1a/
      manifest.json
      mic.wav          16 kHz mono PCM16
      system.wav       16 kHz mono PCM16, only when --source mic+system
```

`manifest.json` carries `schema`, `meeting_id`, `label`, `source`, `started_at`, `shared_start_monotonic_ns`, `tracks`, and `output_dir`. It adds `language_hint` when you pass `--lang`, and `expected_speakers` when you pass `--speakers`, on any source. On `mic+system` that number is the **remote** head count, on `mic-multi` the head count in the room, and absent means not known. `schema` is `1` unless the manifest carries a field schema 1 does not define, which today is `expected_speakers` on a source other than `mic-multi`. Then it is `2`. Each entry in `tracks` names a file relative to the work directory and says whether it is the host track.

It is written with `.atomic`, temp file plus rename, because it is the "capture is complete" sentinel a watcher keys on and a half-written manifest would be picked up as a finished take.

### Track alignment

Both capturers stamp `CLOCK_MONOTONIC_RAW` on their first delivered buffer. A shared start is taken before either one begins, and on a two-track run each track is padded with that much leading silence before it is resampled to 16 kHz, so the two files share a zero. A single-track run is not padded, because there is nothing to align to and the padding would prepend the audio device's warm-up as silence. There is no drift correction beyond that, and no per-buffer timestamping.

---

## Transcription

`meeting-transcribe` turns a take into a transcript on ElevenLabs Scribe v2, with **your** key and **your** credits. It is the reference transcriber for the `--transcriber` contract below, and it runs as a background worker that picks up every finished take in the output folder.

**Set it up with [AGENTS.md](AGENTS.md).** It is a numbered runbook a coding agent follows, with the steps only a person can take marked `HUMAN:`. The documented path is the queued one: record with no `--transcriber`, and the worker transcribes each take after it stops, so you can record back to back. `meeting-capture --transcriber "$(which meeting-transcribe)"` also works and follows the same contract, but it blocks the terminal until the transcript is back.

### What leaves your machine

Read this before you consent. `meeting-transcribe --consent-upload` prints the same text and refuses to run unless a person runs it in a terminal.

- **Audio goes to ElevenLabs.** Every non-silent track of every take is uploaded to the US endpoint `api.elevenlabs.io`. Below the Enterprise plan there is no EU data residency.
- **ElevenLabs retains it.** The provider keeps and logs the uploaded audio and the transcript. Below the Enterprise plan there is no zero-retention mode.
- **You are the controller.** ElevenLabs is your processor. Read its [Data Processing Addendum](https://elevenlabs.io/dpa) and decide whether it covers your use.
- **Cost.** Measured at 20.19 credits per channel-minute of audio on one Creator-tier account in 2026. A two-track call bills both tracks, so an hour of call is about 2,400 credits at that rate. Check your own rate with `GET /v1/user/subscription` before relying on this figure.
- **Tell people.** You must tell every participant that the meeting is recorded and transcribed by a third party, before you record.
- **Use headphones.** On speakers, the microphone also picks up the other side, and their speech is transcribed twice: once as them and once as you. Nothing suppresses this.
- **In-person rooms are unmeasured.** `--source mic-multi` sends the single room microphone with speaker separation on. How well that separates a room of people has not been measured.

Consent is recorded in `~/.config/meeting-capture/consent` with the SHA-256 of the disclosure text. If the text changes in a later version, the old consent stops counting until you consent again. `meeting-transcribe --revoke-consent` deletes it, and nothing uploads after that.

### The key

The key lives in the macOS Keychain, added by you:

```bash
security add-generic-password -s meeting-capture-elevenlabs -a "$USER" -w
```

`security` asks for the key, so it never appears on a command line or in shell history. `meeting-transcribe` reads it by running `/usr/bin/security`, not through the Keychain API, because every rebuild of an unsigned binary changes its identity and the background worker would then hit an access prompt nobody is there to answer. `ELEVENLABS_API_KEY` in the environment is used only when stdin is a terminal. The worker's LaunchAgent carries no environment variables and no key. A key allowed only Speech to Text is enough.

### The transcriber contract

Anything you pass as `--transcriber`, and anything the worker runs, follows this contract, because deleting audio now depends on it.

- **Input.** One argument: the path to `<output-dir>/.work/<meeting-id>/manifest.json`. Manifest schemas 1 and 2 are accepted. Any other schema is exit 3.
- **Output.** `<output-dir>/<slug>_<meeting-id>.md` in the [TRANSCRIPT.md](TRANSCRIPT.md) format, and `<output-dir>/.raw/<slug>_<meeting-id>.json`. `<slug>` is the label with everything outside `A-Z a-z 0-9 . _ -` turned into `-`, leading dots and dashes removed, at most 80 characters, or `meeting` when empty.
- **The proof rule.** The capture CLI and the worker delete a take's audio only after re-reading, from disk: the `.md` exists, is not empty, its frontmatter parses and its `meeting_id` is this take's, and the `.raw` JSON exists. An exit 0 without that proof keeps the audio.
- **The claim.** `meeting-transcribe` creates `.work/<meeting-id>/.claim` with `O_EXCL` before any upload, refreshes it every 30 s, and treats it as stale after 30 minutes. Before every upload and every write it re-reads the claim, and if another runner has taken it over it writes nothing and exits 6.
- **Exit codes.**

| Code | Meaning | Capture CLI | Worker |
|---|---|---|---|
| 0 | transcript written | deletes the audio if the proof passes | same, else marks `.no-transcript` |
| 1 | transient: network, timeout, 5xx, repeated 429 | keeps the audio | one attempt, retried after 300 s, `.upload-failed` after 3 |
| 2 | bad arguments | keeps the audio | counts as an attempt |
| 3 | this take can never succeed: unreadable WAV, 400, 413, 422, over the length ceiling, unknown schema | keeps the audio | `.refused` or `.unreadable`, not retried |
| 4 | every track was digital silence | keeps the audio | `.silent-capture`, not retried |
| 5 | account-wide stop: 401, 402, 403, a quota or balance error, no key, no consent | keeps the audio | pauses the whole queue with the reason, uses no attempt |
| 6 | another runner holds this take | keeps the audio | skips it, uses no attempt |

Any other exit, a crash or a signal included, counts as an attempt and keeps the audio.

**Bounds.** A track whose peak sample is below 5e-4 of full scale is silent and is not uploaded, and it is named in `silent_tracks`. An unreadable WAV is never guessed at. A request may go 900 s plus half the track's length without data, and take that long in total, because no bytes move while the provider transcribes. So a slow answer about a long take is not uploaded and billed again. A 429 is retried in the same run after 30, 60 and 120 s. A take over 4 hours is refused before upload, which `max_take_seconds` in `~/.config/meeting-capture/config.json` changes. Each track's answer is cached in the take folder the moment it arrives, so a retry never pays for a track that already came back. Every upload attempt is logged with the take, the track, the audio seconds and the result.

### The worker

`meeting-transcribe --install-worker --output-dir <dir>` copies the binary to `~/Library/Application Support/meeting-capture/bin/<hash>/`, points a `current` link at it (and `previous` at the one before, which is the rollback), and loads the LaunchAgent `io.github.meeting-capture.transcribe-worker`. It watches `<dir>/.work`, also runs every 10 minutes, and logs to `~/Library/Logs/meeting-capture-transcribe.log`, which rotates at 5 MB. It installs only when consent is recorded. Without it, it prints what it would do and writes nothing.

| Command | What it does |
|---|---|
| `meeting-transcribe --status [<dir>]` | Each waiting take: pending, claimed, cooling down, or failed with its reason and the command to retry. A paused queue shows its reason first. |
| `meeting-transcribe --requeue <id> [<dir>]` | Clears a take's failure marker and attempt count. |
| `meeting-transcribe --resume [<dir>]` | Removes the pause written by an exit 5. |
| `meeting-transcribe --doctor [--live]` | One PASS, WARN or FAIL line per check, including a key read from a LaunchAgent and a 3 s test recording. `--live` sends about 5 s of synthesised speech and **spends credits**. |
| `meeting-transcribe --uninstall-worker [--revoke-consent]` | Unloads and removes the agent. Consent stays unless you pass `--revoke-consent`. |

A take that failed for good keeps its audio. `--doctor` lists any older than 7 days with the command to delete them, and never deletes them itself.

---

## CLI flags

Every flag `meeting-capture` accepts. An unrecognised argument is a refusal with exit code 2, not a warning, because a typo in `--seconds` used to produce an unbounded recording.

| Flag | Value | Meaning |
|---|---|---|
| `--label` | `<name>` | Name for this recording, written to the manifest as `label`. It does **not** appear in the output path: the per-meeting directory is `<utc-start-time>-<4 hex digits>`, so two takes a second apart never collide and a label never has to be filesystem-safe. |
| `--source` | `mic+system` (default), `mic`, `mic-multi` | `mic+system` records both sides of a virtual call. `mic` is one microphone and one speaker. `mic-multi` is one microphone and several people in the room. Any other value exits 2. |
| `--capture` | `sck` (default), `tap` | `sck` is ScreenCaptureKit and is unaffected by a mid-meeting output route change. `tap` is the Core Audio process tap, pinned at start to the default output device. Both capture Bluetooth output. Any other value exits 2. |
| `--seconds` | `<n>` | Stop after n seconds. Default is to run until you stop it. Must be a positive number. |
| `--host` | `<name>` | Speaker label for the mic track in the manifest. Defaults to your account's full name. |
| `--lang` | `<code>` | Advisory language hint. Written to the manifest and used by nothing in this package. |
| `--speakers` | `<n>` | Head count, written to the manifest. On `mic+system` it is the number of remote people, and `1` tells a transcriber not to split that track into speakers. On `mic-multi` it is the number of people in the room. Must be a positive whole number. |
| `--mic-device` | `<name>` | Case-insensitive substring of the microphone to use. Default is the built-in one, picked by the name heuristic below. |
| `--output-dir` | `<path>` | Where recordings go. Default `~/Documents/MeetingCaptures`. A directory that cannot be created is a fatal error, not a silent one. |
| `--transcriber` | `<path>` | Executable to run when recording stops. It receives the manifest path as its only argument. Default is none, in which case the run ends with the audio and manifest on disk. |
| `--foreground` | flag | Do not run the transcriber under background QoS. |
| `--keep-audio` | flag | Keep the raw WAVs even after a transcriber run with a proven transcript. |
| `--auto-stop` | flag | Stop on your behalf once the meeting is clearly over. On a call that means the far side has been silent long enough to have hung up. It never stops while you are still talking, it warns before it acts, and it treats an absent system track as absent rather than silent, so it does not end an in-person recording. This is the `SilenceGate` library, wired in. |
| `--help`, `-h` | flag | Print the usage text and exit 0. |

`--help` and `-h` are two spellings of one flag. The tokens in that table are exactly the `valuedFlags` and `booleanFlags` sets the argument parser checks against.

**One environment variable is not in `--help`:** `MEETING_CAPTURE_KEEP_AUDIO`, set to anything, does what `--keep-audio` does.

### How the default microphone is chosen

`pickMic()` tries three things in order: an explicit `--mic-device` substring, then the built-in microphone, then `AVCaptureDevice.default(for: .audio)`.

The built-in step is **a name heuristic, and it can miss.** AVFoundation exposes no "is this the built-in microphone" flag on macOS, so it lowercases each device's localized name and looks for Mac product-name needles in it. That is English-biased and it fails on a localized system or an unlisted model, in which case selection falls through to `AVCaptureDevice.default(for: .audio)`, and only to the first device the discovery session returned if there is no system default. `--mic-device` is the escape hatch, and it is why the flag exists. If nothing matches your substring the run refuses and lists the device names it did see on stderr.

### The transcriber handoff

Two throttles apply to the child process, and `--foreground` turns both off:

- It runs under `/usr/sbin/taskpolicy -b` when that binary is present, so the OS schedules it on efficiency cores and foreground work preempts it.
- `OMP_NUM_THREADS` is set to the efficiency-core count, so it does not oversubscribe the cores it was confined to.

The child's `PATH` gets `/opt/homebrew/bin` and `/usr/local/bin` prepended, because a transcription tool commonly shells out to `ffmpeg` and a process launched from a GUI app inherits a minimal `PATH`.

### Live level lines

While recording, `meeting-capture` writes a line to stderr about every five seconds, carrying the peak absolute sample per track since the previous line:

```
[level] mic=0.0421 sys=0.0033
```

Two things to know before you build on these lines. They are emitted from **both** arms, so a `--seconds` run prints them too, which matters because a fixed-length run is exactly the case you would replay through `SilenceGate`. And both capturers implement `takeLevelPeak()`, so `sys=` carries a real reading in `--capture tap` mode as well as in `--capture sck` mode.

The `sys=` field is **omitted entirely** when there is no system capturer, so a consumer can tell a missing track from a silent one. Those must never look alike: a missing track is an in-person recording, a silent one is a finished call.

---

## Libraries

Seven library products, split out for one reason: each is wrong in ways a compiler cannot see, and each has to be replayable without launching anything or granting a permission.

**Three of the seven are used by the CLIs. Four are not.** `CaptureIO` and `SilenceGate` are on the path every recording takes. `NotetakerCore` holds the capture CLI's transcriber handoff and proof rule, and everything `meeting-transcribe` does. `ScreenPreset`, `SpeakerNaming`, `MeetingPresence` and `LiveAudio` came out of the same private app and ship here as components with their own checks and no caller in this package — `ScreenPreset` is imported only by `MeetingPresence` and by two checks. Nothing here records a screen, renames a speaker, watches for a meeting window, or streams audio over a wire. If you want one of those four, you are taking a library and writing the caller yourself. That is a fair trade for code this heavily falsified, but it should not be a discovery you make after cloning.

`CaptureIO` is the one the CLI itself is built on. It holds the resampler, the WAV writer and the disk-backed capture buffer, so recording a long meeting does not hold the meeting in memory. It lived inside the executable, where no check could import it, which is how the one path every user runs ended up as the only path with no coverage.

### ScreenPreset

The decisions behind a screen recording, with no ScreenCaptureKit, no AVFoundation and no TCC anywhere in the file. Display resolution and geometry (`fitBox`), display choice (`resolveDisplay`), disk preflight (`checkSpace`), conference-window detection (`isConferenceWindow`), and the `Sidecar` shape a completed video is described by. It decides on plain structs you pass in, so the caller does the ScreenCaptureKit work and this does the arithmetic.

**Adding your own conferencing app.** The shipped set is data, not code, because the set of conferencing tools is not knowable in advance. Edit it in Swift, or load it from a JSON file so it changes without a rebuild:

```swift
var detection = ScreenPreset.ConferenceDetection.default
detection.bundleIDs.insert("com.example.MyConferenceApp")
detection.titlePrefixes.append("standup – ")

let fromDisk = try ScreenPreset.ConferenceDetection.load(
    fromJSONAt: "~/.config/meeting-capture/conference.json")

let pick = ScreenPreset.resolveDisplay(
    choice: .auto, displays: displays, windows: windows, detecting: detection)
print(pick?.how ?? "no display")   // e.g. "auto:MyConferenceApp"
```

```json
{
  "bundleIDs": ["us.zoom.xos", "com.example.MyConferenceApp"],
  "titlePrefixes": ["meet – ", "meet - ", "meet — ", "standup – "]
}
```

A field the file omits keeps the shipped default. A field the file **sets replaces** the shipped default for that field, so the JSON above has to repeat the Google Meet prefixes to keep them. The tilde is expanded for you. `load` throws only on unreadable or malformed JSON, so a file that parses but sets nothing is a valid way to say "use the defaults".

Two rules in the default set carry their reason in the source, and both cost a real meeting to learn. `bundleIDs` asserts "any window of this app is a call", which is only true for apps that exist solely to hold meetings, so Slack is deliberately absent and matches by title instead. And Google Meet is matched by a **title prefix** rather than a needle, because a live Meet call in Chrome is titled `Meet – Weekly project sync` while a bare `meet` needle also matches a document called `Quarterly review | Meeting Notes | Acme`.

### SpeakerNaming

Pure transcript speaker relabeling. String in, string out, no filesystem. It renames `Speaker N` in the two positions the token legitimately appears, the frontmatter participant list and a body utterance's speaker slot, and nowhere else. `Speaker 1` mentioned inside spoken text is left alone, because the replacement is anchored to a regex slot rather than a global string swap.

The two shapes it rewrites, and nothing else:

```
  - Speaker 1 (remote)              frontmatter participant, also (in-person)
1   [00:00:04] Speaker 1: Hi.       body utterance, index, timestamp, slot, colon
```

`detect(in:)` returns the distinct tokens in first-appearance order. `apply(_:to:)` takes a map and rewrites only those slots, so a line reading `I think Speaker 1 was right` is left alone.

A name is skipped, leaving its token untouched, when it is blank after trimming or contains `:` or a newline. Either would corrupt the downstream `Name: text` parse. Indices, timestamps and spacing survive exactly.

### SilenceGate

A replayable answer to "should this recording still be running?". You feed it `[level]` lines or parsed samples with an elapsed-time value, never a clock, and it returns `.keepGoing`, `.warn` or `.stop`. Injected time is what makes a 50-minute meeting replay in milliseconds.

Two fuses, and which one applies is the whole design:

- **Remote-gated** (virtual call, a system track exists, and it has made a sound at least once): warn at 5 minutes of remote quiet, stop at 8. Short, because the signal is categorical. A hung-up call reads exactly `0.0000` on every block.
- **Mic-only**: warn at 15 minutes, stop at 18. Long, because on the measured trace room noise and live speech overlap almost completely and no threshold separates them. This path is a backstop, not a detector.

Three guards keep it from cutting a live meeting:

- A system track that has **never** made a sound is a broken capture, not a finished call, so it never gates. Without this, a missing Screen Recording grant would stop every recording at eight minutes.
- A stop needs the host to have been quiet too. `micActiveLevel` at 0.08 asks "is the host talking", well above the 0.02 that asks "is there any sound". It is an extra condition on stopping, so it can only ever prevent a stop, never cause one. Presenting to a muted room does not get you cut off.
- "Keep recording" resets both clocks, not just one, so the stop does not land on schedule anyway.

`SilenceGate` **is** wired into `meeting-capture`, behind `--auto-stop`. The CLI feeds it the same level readings it prints, warns when the gate says the room has gone quiet, and ends the take when the gate says the meeting is over. Without `--auto-stop` the gate is not consulted and a run stops only when you stop it or `--seconds` expires.

Used as a library on its own, it is pure: levels in, a decision out, no clock and no I/O, which is what lets `silence-gate-check` replay a 50-minute call against it in milliseconds.

### MeetingPresence

Two rules over window geometry, with no AppKit and no CoreGraphics window list. Depends on `ScreenPreset` for `WindowInfo`.

`CallPresence` answers "a new call window appeared, prompt about it". Identity is the window-server id, not the app, so two back-to-back Zoom calls are two windows and one window across a lunch break is one. An id is forgotten only when the window closes, which is what makes "prompt once per call" hold across a poll running every few seconds for an hour. Every window in a fresh batch is marked prompted, not only the one returned, so a Zoom control strip that lost the size comparison does not prompt on the next poll.

`PanelAnchor` answers "the host dragged this panel, stand down". The comparison is against the **last origin you set**, never a fixed anchor, because automatic re-anchoring moves the panel often and anything comparing to a start position reads your own moves as the host's. `PanelPoint` is plain `Double`s rather than `CGPoint`, and that is not stylistic: a `CGPoint` in this API crashed the release build outright with a deserialization failure while the debug build compiled and every check passed.

### LiveAudio

The audio arithmetic behind a live streaming path: a bounded `PCMRing`, a `Mixer`, a `FrameAssembler`, a `StreamingResampler`, and a `WireFormat` byte layout.

**There is no example caller for it in this package.** The tap that consumed it stayed in the private app. What ships here is the component library and `live-audio-check`, which exercises it. Treat it as parts, not as a product.

What each part is for:

- `PCMRing` is a fixed-capacity FIFO between an audio callback and a writer. It never blocks and it drops the **oldest** frame on overflow. Drop-newest would hold a stale window while live speech is thrown away, and the consumer would see a contiguous `seq` run with no gap to detect.
- `Mixer` sums two mono tracks and clamps to `[-1, 1]` before encoding to PCM16. Two tracks each at a legitimate 0.8 sum to 1.6, which does not fit in an `Int16`. Wrapped, a loud two-way passage becomes full-scale noise of the opposite sign. The `Int16` initialiser is deliberately the trapping one, so losing the clamp kills the process rather than producing plausible nonsense.
- `FrameAssembler` turns two independent 16 kHz sources into fixed-size mono frames. It emits only whole frames, only when every contributing source has one, and drops a source that stops delivering rather than letting it stall the stream. Every event that makes output non-contiguous is announced as a named `DiscontinuityReason` with a bumped generation, and the reason rides out on the frame it precedes.
- `StreamingResampler` holds one persistent `AVAudioConverter` for the life of a take. It watches its input format on every push and either reinitialises or hard-fails. It never emits samples converted across a transition it did not handle, because a converter built for 48 kHz fed 44.1 kHz emits well-formed frames of garbage.
- `WireFormat` is a 16-byte stream header, an 8-byte frame prefix, and the rule for when a re-emitted header goes on the wire. Its checks assert byte literals rather than round-tripping through a decoder written beside the encoder, which would only measure the pair against each other.

---

## Checks

Seven runnable executables, one per library. They are plain executables rather than XCTest targets because a machine with only the Command Line Tools has no XCTest to link against, and these run there and on a CI runner unchanged.

```bash
swift build

swift run audio-pipeline-check
swift run silence-gate-check
swift run speaker-naming-check
swift run screen-record-check
swift run meeting-presence-check
swift run live-audio-check
swift build && "$(swift build --show-bin-path)/transcribe-check"
```

`transcribe-check` runs the built `meeting-transcribe` as a child process, so it needs a full `swift build` first rather than `swift run`, which would build only the check. It exits 2 when that binary or its fixtures are missing.

Each prints one line per case and exits 0 when every case passes, 1 when one fails. `silence-gate-check` has a third code: it exits 2 when its fixture is missing or empty, so a run that would have verified nothing cannot be read as a pass.

**None of them needs a microphone grant, a screen-recording grant, a display, or the network.** No audio device is opened and no window server is touched. The one socket is `transcribe-check`'s stub server, bound to 127.0.0.1, and the transcriber refuses any API base that is not a loopback host, so no run of the checks can send a key or audio off the machine. `silence-gate-check` replays a real level trace from `Fixtures/overrun-trace.levels`, taken from a recording that ran past the end of its call. That fixture is peaks only, one reading per track per five-second tick. No speech content and no participant identity are recoverable from it.

### Where the falsifier is named

`silence-gate-check`, `meeting-presence-check` and `live-audio-check` take a required `breaksIf:` string on every case, saying which mutation should turn that case red. Printing it beside a failure tells the next reader what the case was defending. `audio-pipeline-check` takes one too, on every case it currently has, though its parameter still defaults to `""` rather than being required — tightening that is a welcome change, and this paragraph forgot the check existed until a reader counted. `screen-record-check` and `speaker-naming-check` take a name and a condition only, so their falsifiers live in the mutation scripts instead.

### The mutation scripts

`Scripts/*-mutations.sh` break the sources on purpose and assert that the **named** check goes red, not merely that the suite failed. All seven run against this package. Run them from anywhere:

```bash
bash Scripts/silence-gate-mutations.sh
bash Scripts/speaker-naming-mutations.sh
bash Scripts/screen-record-mutations.sh
bash Scripts/meeting-presence-mutations.sh
bash Scripts/live-audio-mutations.sh
bash Scripts/transcribe-mutations.sh
```

Every mutation in them has been observed to make its named check go red. Sources are mutated in place and restored from an `EXIT INT TERM` trap, so an interrupt still puts the tree back. Each script prints one `ok` or `FAIL` line per mutation and a pass or fail banner at the end, so the result comes from the run rather than from this file. Each build a script runs — the baseline and every mutation — goes into its own `--scratch-path`, so a harness run leaves your `.build` untouched. Measured: `rm -rf .build`, run `screen-record-mutations.sh`, and `.build` is still absent afterwards. The baseline run used to omit the flag, which put about 100 MB there on the first line that builds anything. `live-audio-mutations.sh` carries many more mutations than the other four and takes correspondingly longer.

**What counts as a bite.** A compile error never counts. It would fail every mutation equally and says nothing about the limb, so every script separates it from a real red and reports it as having tested nothing.

A runtime trap counts **only where the mutation declares it.** `Scripts/live-audio-mutations.sh` marks two mutations with an expected result of `<crash>`, both aimed at code whose point is that it traps rather than producing plausible nonsense: the PCM16 clamp in `Mixer`, and the frame-readiness guard in `FrameAssembler`. For those it greps the output for `Fatal error`, `Illegal instruction` or `Trace/BPT`, which is how a trap is told from a compile error. Everywhere else a trap is reported as having tested nothing.

Three honest limits:

- **The scripts do not classify a bite the same way.** `live-audio`, `screen-record` and `meeting-presence` test for the named case **first** and only then explain a run that produced no bite, which is the order that keeps a real red from being reclassified as a build error. `speaker-naming` and `silence-gate` still test the build-error branch first, and they anchor on a bare `error: ` rather than the `file:line:col: error:` form, so a clean build whose output happens to quote the string can be scored as "did not build". That is the defect `live-audio-mutations.sh` records having mis-scored 77 mutations once. Bringing those two into line is a welcome change.
- **Coverage is narrower than it was before the carve.** The consent notice, the recorder, the screen CLI and the live tap had 34 limbs among them and have none here, because those targets are not in this package. What was cut was cut for that reason and nothing else.
- **Nothing in `Scripts/` covers `MeetingCaptureCLI` itself.** The capture path has no mutation script. It is the one place where a check would need a real device, and that is exactly why it is missing. `CaptureIO`, which is everything that happens to the samples after the device hands them over, is covered by `captureio-mutations.sh` and needs no device at all.
- **`SampleSink`'s write-error propagation has no falsifier.** `finish()` is documented to throw any error the background writer hit, and removing the error capture makes it stop throwing with no check noticing. Forcing a real write failure needs a full or read-only filesystem that a check running on any machine cannot assume. `captureio-mutations.sh` prints this gap when it finishes rather than leaving it to be discovered.

---

## What this is not

- **`meeting-capture` does not transcribe.** No speech recognition, no model, no API call. `--transcriber` runs an executable you supply and reports its exit status. `meeting-transcribe` is a separate executable, and it does send audio to ElevenLabs, once a person has consented.
- **It does not summarise.** Nothing here reads a transcript for meaning.
- **There is no app bundle.** No `.app`, no menu bar item, no UI. Command line only.
- **There is no code signing and no notarization.** You build it, you run it.
- **There is no `Info.plist`.** Usage-description strings are what an app bundle supplies. A command-line binary inherits the launching app's TCC identity instead, which is why the grant lands on your terminal.
- **Intel is untested.** No claim either way.
- **Windows and Linux are not supported.** Core Audio, AVFoundation and ScreenCaptureKit are macOS only. The package will not resolve elsewhere.
- **The tap's TCC behaviour is not documented here** because it has not been verified. See [Permissions](#permissions-tcc).

## Maintenance

Published as-is. Issues are read, but a response is not promised.

## License

MIT. See [LICENSE](LICENSE).
