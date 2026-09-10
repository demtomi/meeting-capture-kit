# Contributing

Read the [Maintenance](README.md#maintenance) note first. This package is published as-is and a response to a pull request is not promised. If your change matters to you on a schedule, fork it.

What follows is how to build it, how to check it, and the one rule that is not negotiable.

## Build

```bash
swift build
```

You need macOS 14.2 or later. That is the `platforms:` floor in `Package.swift`, and SwiftPM refuses to resolve the package below it. The Command Line Tools are enough. A full Xcode install is not required, because nothing here links XCTest.

## Run the checks

```bash
swift run audio-pipeline-check
swift run silence-gate-check
swift run speaker-naming-check
swift run screen-record-check
swift run meeting-presence-check
swift run live-audio-check
```

Each exits 0 on success and 1 with the failing case named. `silence-gate-check` also exits 2 when its fixture is missing or empty, so a run that verified nothing cannot read as a pass. All of them must exit 0 before you open a pull request.

None of them needs a microphone grant, a screen-recording grant, a display, or the network. If a change you make introduces one of those dependencies into a check, that is the thing to reconsider, not the check.

To run them all and see which one broke:

```bash
for c in audio-pipeline silence-gate speaker-naming screen-record meeting-presence live-audio; do
  swift run "$c-check" > /dev/null 2>&1 && echo "ok   $c" || echo "FAIL $c"
done
```

## The rule

**Any pull request that touches capture or a verified invariant must add a mutation to the relevant `Scripts/*-mutations.sh` and show it biting.**

"Show it biting" means: paste the output where the mutation is applied and the check you named goes red, and the output where the mutation is reverted and it goes green again. Not "the suite failed". The **named** case has to be the one that fails.

Why: a check that passes is evidence about nothing until a defect makes it fail. This package is full of invariants no compiler can see, and several of them are absences, which no unit test can assert directly. Three cases in an earlier suite could not fail at all, and nobody knew until each one was broken on purpose. A limb that cannot fail is worse than no limb, because it reads as coverage.

### Which changes the rule covers

- Anything in `Sources/MeetingCaptureCLI/`. That is the capture path.
- Anything in `Sources/LiveAudio/`, `Sources/SilenceGate/`, `Sources/ScreenPreset/`, `Sources/SpeakerNaming/`, `Sources/MeetingPresence/` that changes behaviour rather than a comment.
- Any change that weakens or removes a `breaksIf:` string in a check. That string names the mutation the case exists to catch. Removing it without a reason removes the case's meaning.
- Any change that renames or deletes a check case. The mutation scripts assert on the case name, so a rename that looks cosmetic turns a real bite into a silent miss.

Documentation, comments, and the CI workflow are outside it.

### The mutation scripts

All five run against this package, from any directory:

```bash
bash Scripts/silence-gate-mutations.sh
bash Scripts/speaker-naming-mutations.sh
bash Scripts/live-audio-mutations.sh
bash Scripts/meeting-presence-mutations.sh
bash Scripts/screen-record-mutations.sh
```

Every mutation in them has been observed to make its named check go red. A build failure never counts as a bite, because it would fail every mutation equally. A runtime trap counts only where the mutation is declared to expect one: `live-audio-mutations.sh` marks two mutations `<crash>`, on the PCM16 clamp in `Mixer` and the frame-readiness guard in `FrameAssembler`, and greps for `Fatal error`, `Illegal instruction` or `Trace/BPT` to tell a trap from a compile error. Everywhere else a trap is reported as having tested nothing.

Each script backs up what it touches, restores from an `EXIT INT TERM` trap, prints one `ok` or `FAIL` line per mutation, and ends with a pass or fail banner. Each rebuilds into its own `--scratch-path`, so none of them touches your `.build`. `live-audio-mutations.sh` carries many more mutations than the other four and takes correspondingly longer.

`MeetingCaptureCLI` has no mutation script at all. It is the one part that needs a real audio device. If your change is in the capture path, say in the pull request how you tested it and what you could not test.

### How a mutation is shaped

The existing scripts follow one pattern. Copy it.

- Back the file up to a `mktemp -d` directory before touching it, and restore it from an `EXIT INT TERM` trap, so an interrupt still puts the tree back.
- Mutate one thing. One operator, one constant, one deleted line. A mutation that changes two things cannot tell you which case caught it.
- Rebuild, run the one check, and assert that the case you named appears as a failure. Assert on the case name, not on the exit code alone.
- Test for the named case **before** you test for a build error, and anchor the build-error test on `: error: ` rather than a bare `error: `. A Swift diagnostic quotes the offending source line back, so a clean build can carry the string `error: ` in its output. Getting that order wrong once scored 77 live-audio mutations as "did not build" while every one of them was biting. `live-audio-mutations.sh`, `screen-record-mutations.sh` and `meeting-presence-mutations.sh` have the right order. `speaker-naming-mutations.sh` and `silence-gate-mutations.sh` do not yet.
- Restore, rebuild, and assert the check goes green again. A mutation that leaves the tree broken is a mutation that poisons every case after it.
- Classify it. The scripts distinguish **source invariants**, where the claim is an absence and grep is the only instrument available, from **suite mutations**, which break a named case in a check. Both need to be watched biting. Grep is a weak instrument and a source invariant that has never been seen to flip is a belief, not a check.

## Style

Match the file you are editing. The sources carry long comments that say why a line is the way it is, usually naming the failure that produced it. That is deliberate and it is the most useful thing in the repository. If you change one of those lines, change the comment with it.

Do not reformat code you did not otherwise change.

## Scope

Small, single-purpose pull requests. A behaviour change and a refactor in one diff is two reviews to do and one to skip.

The package has no external dependencies and every import is a system framework. Adding a dependency needs an argument in the pull request description, not just a line in `Package.swift`.
