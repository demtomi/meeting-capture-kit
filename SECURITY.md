# Security policy

This package records audio from your microphone and from everything playing on your machine. That is a sensitive capability, so a report about it is worth making even when you are not sure it is a real defect.

## How to report

**Open a GitHub security advisory on this repository.** Use the Security tab, then "Report a vulnerability". That keeps the report private until there is something to say publicly.

Do not open a normal issue for a security report. Issues are public from the moment you file them.

Include what you would want to receive: your macOS version, your chip, the exact command or API call, what you expected, what happened, and a reproduction if you have one.

## Response time

**A response time is not promised.** This package is published as-is, and its maintenance stance is in the README. Reports are read. Whether one is acted on, and when, is not something you should plan around.

If you find something serious and you need it fixed on a schedule, fix it in your fork. The license permits that and it is the faster path.

## In scope

Report anything in these areas:

- **The capture path.** Everything that opens a device or writes a track: `main.swift`, `SystemTap`, `SystemCaptureSCK`, `SystemCapturer`, `MicCapture`, and the WAV write and resample step. Capture that starts without the permission it should need, capture that continues after `stop()`, or audio reaching a buffer that outlives the run.
- **The aggregate-device lifecycle.** `SystemTap` creates a process tap and a private aggregate device and tears both down in `stop()`. A path that leaves either alive after the process exits is a system-wide audio object that outlived its owner. A crash mid-`start()` that leaves a tap object behind counts.
- **Anything that writes outside the configured output directory.** The CLI creates `<output-dir>` and `<output-dir>/.work/<meeting-id>/` and writes nothing else, and it deletes the work directory after a transcriber run that exited 0, unless `--keep-audio` or `MEETING_CAPTURE_KEEP_AUDIO` is set. A path traversal through `--label` or `--output-dir`, a delete that reaches further than the work directory, or a temp file written somewhere else, are all in scope.
- **The transcriber handoff.** `--transcriber` runs an executable you name, with a modified `PATH` and possibly under `taskpolicy`. An injection into the child's argument list or environment that you did not ask for is in scope.
- **Anything that sends data off the machine.** Nothing in this package opens a network connection. If you find one, that is the report to file.
- **`ScreenPreset.ConferenceDetection.load(fromJSONAt:)`.** It parses a file you supply. A crafted file that does more than change the configuration is in scope.

## Out of scope

- **Permission problems.** A missing Microphone or Screen Recording grant is not a vulnerability. It is the most common incoming report and it belongs in a bug report, not an advisory. See the bug report template.
- **The TCC grant attaching to your terminal rather than to the binary.** That is how macOS treats an unbundled command-line binary. It is documented in the README and it is not a defect in this code.
- **A recording being audible or discoverable to another user on the same machine.** File permissions on the output directory are the operating system's, not this package's. Choose an `--output-dir` accordingly.
- **The absence of code signing, notarization or an app bundle.** Named in the README as things this package does not do.
- **Anything in a fork, a vendored copy, or the private app this was carved out of.**
- **Dependency reports.** The package has no external dependencies. Every import is a system framework.
- **Legality of recording a call.** Consent and recording law where you are is your responsibility. It is not a software defect and there is no advice here about it.

## What a fix looks like

A fix to the capture path or to a verified invariant needs a mutation added to the relevant `Scripts/*-mutations.sh`, shown biting. That rule is in [CONTRIBUTING.md](CONTRIBUTING.md) and it applies to a security fix too. A patch that makes the symptom go away without a check that would have caught it is a patch that gets reintroduced.
