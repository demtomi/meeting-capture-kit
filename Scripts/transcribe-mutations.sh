#!/usr/bin/env bash
# Falsification for the transcriber, the queue worker and the capture CLI's delete rule.
#
# `transcribe-check` passes. A check that passes is evidence about nothing until a defect
# makes it fail, so each limb below plants one defect in the source and asserts that the
# NAMED case goes red, not merely that the run failed, which a compile error would also do.
#
# Three controls run first, because each is a way for this script to report bites that
# never happened:
#   1. the unmutated tree must pass, or every "bite" below is the baseline failing
#   2. a sed that changes nothing must be caught, or a stale pattern reads as coverage
#   3. a mutation that does not compile must be reported as testing nothing
#
# Sources are mutated IN PLACE and restored by an EXIT trap. Every build goes into its own
# --scratch-path, so the caller's .build is left alone. Nothing here needs a device, a
# grant, a key, a credit or the network: the check's only socket is on 127.0.0.1.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE/.."
PASS=1

CORE="Sources/NotetakerCore"
HANDOFF="$CORE/Handoff.swift"
WORKER="$CORE/Worker.swift"
TRANSCRIBE="$CORE/Transcribe.swift"
CLIENT="$CORE/ScribeClient.swift"
CLAIM="$CORE/TakeClaim.swift"
CONSENT="$CORE/Consent.swift"
KEYS="$CORE/KeySource.swift"
WAV="$CORE/WavPeak.swift"
MANIFEST="$CORE/Manifest.swift"
PROOF="$CORE/TakeProof.swift"
RENDER="$CORE/Renderer.swift"
INSTALL="$CORE/Install.swift"
CAPMAN="$CORE/CaptureManifest.swift"
MAIN="Sources/meeting-transcribe/main.swift"
FILES=("$HANDOFF" "$WORKER" "$TRANSCRIBE" "$CLIENT" "$CLAIM" "$CONSENT" "$KEYS" "$WAV"
       "$MANIFEST" "$PROOF" "$RENDER" "$INSTALL" "$CAPMAN" "$CORE/Doctor.swift" "$MAIN")

BACKUP="$(mktemp -d)"
for f in "${FILES[@]}"; do
    [ -f "$f" ] || { echo "   FAIL missing source: $f"; exit 1; }
    mkdir -p "$BACKUP/$(dirname "$f")"; cp "$f" "$BACKUP/$f"
done
restore() {
    for f in "${FILES[@]}"; do [ -f "$BACKUP/$f" ] && cp "$BACKUP/$f" "$f"; done
    rm -rf "$BACKUP"
}
trap restore EXIT INT TERM

# Does text $2 contain the fixed string $1? A here-string, never a pipe: under pipefail,
# `printf "$OUT" | grep -q` fails with 141 once OUT outgrows the pipe buffer, because grep
# exits on the first match and the writer takes SIGPIPE. That reads a real match as a miss.
contains() { grep -qF -- "$1" <<< "$2"; }
contains_re() { grep -qE -- "$1" <<< "$2"; }

ok()  { echo "   ok   $1"; }
bad() { echo "   FAIL $1"; PASS=0; }

# Builds only the two products the check needs, into a fresh scratch path, and runs it.
# Sets OUT and RC. RC 97 means the build failed.
build_and_check() {
    local scratch; scratch="$(mktemp -d)"
    if ! swift build --scratch-path "$scratch" --product meeting-transcribe > "$scratch.build.log" 2>&1 \
       || ! swift build --scratch-path "$scratch" --product transcribe-check >> "$scratch.build.log" 2>&1; then
        OUT="$(cat "$scratch.build.log")"; RC=97
    else
        OUT="$("$scratch/debug/transcribe-check" 2>&1)"; RC=$?
    fi
    rm -rf "$scratch" "$scratch.build.log"
}

# Applies one mutation, runs the check, restores, and classifies. Returns:
#   0 the named case went red        1 the sed changed nothing
#   2 build error (tested nothing)   3 the run exited 0 or went red elsewhere
mutate() {
    local file="$1" expr="$2" expect="$3"
    local before; before="$(mktemp)"; cp "$file" "$before"
    sed -i '' "$expr" "$file"
    if cmp -s "$before" "$file"; then cp "$before" "$file"; rm -f "$before"; return 1; fi
    build_and_check
    cp "$before" "$file"; rm -f "$before"
    # The NAMED case first. A build log can quote source containing the word error, so a
    # real red must never be reclassified as a build failure by testing that first.
    if [ "$RC" -ne 0 ] && [ "$RC" -ne 97 ] && contains "FAIL  $expect" "$OUT"; then return 0; fi
    if [ "$RC" -eq 97 ]; then return 2; fi
    return 3
}

limb() {
    local label="$1" file="$2" expr="$3" expect="$4"
    mutate "$file" "$expr" "$expect"
    case $? in
        0) ok "$label -> \"$expect\" bit" ;;
        1) bad "$label: the sed changed NOTHING, so this limb tested nothing" ;;
        2) bad "$label: the mutation did not build, so it tested nothing" ;;
        *) bad "$label: \"$expect\" did not go red (exit $RC; red: $(grep '  FAIL  ' <<< "$OUT" | head -3 | tr '\n' ';'))" ;;
    esac
}

# ======================================================================== controls
echo "== controls"
# The classifier must find a named FAIL in an output far larger than a pipe buffer. Under
# pipefail a pipe into grep -q can report a real match as a miss (the writer takes SIGPIPE
# when grep exits early), which would score a biting mutant as "did not go red".
BIG="$(printf '  FAIL  planted named case\n'; head -c 2000000 /dev/zero | tr '\0' 'x')"
if contains "FAIL  planted named case" "$BIG"; then
    ok "control: a named FAIL is found in a 2 MB output"
else
    bad "control: a named FAIL in a 2 MB output was MISSED by the classifier"
fi
[ "${CONTROLS_ONLY:-}" = 1 ] && { echo "CONTROLS_ONLY: stopping after the output-size control"; [ "$PASS" = 1 ]; exit $?; }
build_and_check
if [ "$RC" -eq 0 ] && contains_re '=== ([0-9]+)/\1 checks passed ===' "$OUT"; then
    ok "baseline: transcribe-check passes on the unmutated tree ($(grep -E '^=== ' <<< "$OUT" | tail -1))"
else
    bad "baseline: transcribe-check does NOT pass unmutated (exit $RC). Every result below would mean nothing."
fi

mutate "$HANDOFF" 's/THIS PATTERN MATCHES NOTHING IN THE FILE/x/' "g2 a transcriber that exits 0 and writes nothing"
[ $? -eq 1 ] && ok "control: a sed that changes nothing is caught" || bad "control: a no-op sed was NOT caught"

mutate "$HANDOFF" 's/^public func efficiencyCoreCount() -> Int {$/public func efficiencyCoreCount() -> Int { let broken: Int = "not an int"/' "g2 a transcriber that exits 0 and writes nothing"
[ $? -eq 2 ] && ok "control: a mutation that does not compile is reported as testing nothing" \
             || bad "control: a compile error was NOT classified as testing nothing"

# ======================================================================== the delete rule
echo
echo "== deletion only on proof"
limb "the capture CLI deletes on exit 0 alone" "$HANDOFF" \
    's/        if status == 0 \&\& !keepAudio \&\& proofPasses {/        if status == 0 \&\& !keepAudio {/' \
    "g2 a transcriber that exits 0 and writes nothing leaves .work/<id>/ intact"
limb "the worker deletes on exit 0 alone" "$WORKER" \
    's/                if let failure = proveTake(manifestPath: dir + "\/manifest.json", outputDir: layout.root) {/                if let failure = Optional<ProofFailure>.none {/' \
    "a exit 0 with no transcript leaves .work/<id>/ intact and marks .no-transcript"
limb "the proof ignores meeting_id" "$PROOF" \
    's/    guard fields\["meeting_id"\] == meetingID else/    guard fields["meeting_id"] != nil else/' \
    "proof: a transcript naming another meeting fails"
limb "keep-audio is not consulted by the worker" "$WORKER" \
    's/                } else if keepAudio || manifestKeepsAudio(dir) {/                } else if manifestKeepsAudio(dir) {/' \
    "w keep-audio: transcript written, audio kept, marked done, not uploaded twice"

# ======================================================================== paying once
echo
echo "== paying once"
limb "a cached track is not reused" "$TRANSCRIBE" \
    's/            if let b = body, ScribeResult.parse(b) != nil {/            if let b = body, ScribeResult.parse(b) != nil, b.isEmpty {/' \
    "b mic 200 then system 500, then a retry, sends zero new mic uploads"
limb "the losing drain reports success" "$WORKER" \
    's/            return ExitCode.heldElsewhere/            return ExitCode.ok/' \
    "d two --drain runs started together upload the take once in total, and the loser exits 6"
limb "a take held elsewhere reads as done to the capture CLI" "$TRANSCRIBE" \
    's/            return ExitCode.heldElsewhere/            return ExitCode.ok/' \
    "d the capture CLI's own transcriber run on a claimed take exits 6 and keeps the audio"
limb "the token is never re-checked" "$CLAIM" \
    's/        return s.split(separator: " ").dropFirst().first.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } == token/        return !s.isEmpty/' \
    "g3 a holder stopped past the stale age loses its claim: it exits 6, uploads nothing, writes nothing"
limb "a stale claim can never be taken over" "$CLAIM" \
    's/            guard age > stale || dead else {/            guard age > stale * 1000 || dead else {/' \
    "g3 ...and the runner that took over finishes with exactly one upload per track"

# ======================================================================== the status table
echo
echo "== the status table"
limb "403 is not account-wide" "$CLIENT" \
    's/\[401, 402, 403\].contains(status)/[401, 402].contains(status)/' \
    "c row 403 plan gate -> exit 5"
limb "a quota body is not account-wide" "$CLIENT" \
    's/    static let accountBodies = \["quota_exceeded", /    static let accountBodies = [/' \
    "c row 400 quota body -> exit 5"
limb "413 is retried" "$CLIENT" \
    's/\[400, 413, 422\].contains(status)/[400, 422].contains(status)/' \
    "c row 413 too large -> exit 3"
limb "429 is not backed off" "$CLIENT" \
    's/            if status == 429, retries < Self.backoff.count {/            if status == 429, retries < 0 {/' \
    "c row 429 x4 backs off 3 times then exit 1 -> exit 1"
limb "the resource timeout is a fixed value" "$CLIENT" \
    's/    public static func resourceTimeout(audioSeconds: Double) -> Double { 900 + 0.5 \* audioSeconds }/    public static func resourceTimeout(audioSeconds: Double) -> Double { 60 }/' \
    "c timeouts: 900 s plus half the audio in total, and 30/60/120 s backoff"

# ======================================================================== the worker
echo
echo "== the worker"
limb "exit 5 does not pause" "$WORKER" \
    's/                guard write(layout.pauseFile, why) else { return stopOnMarker(id) }/                guard write(layout.pauseFile + ".not", why) else { return stopOnMarker(id) }/' \
    "c drain: exit 5 pauses the drain with the reason and burns no attempt"
limb "no cooldown" "$WORKER" \
    's/                return !(a.count > 0 \&\& now - a.last < cooldown)/                return true/' \
    "c drain: exit 1 keeps the take, counts one attempt and cools down"
limb "no attempt cap" "$WORKER" \
    's/                if count >= Self.maxAttempts {/                if count >= 99 {/' \
    "c drain: three failed attempts write .upload-failed and keep the audio"
limb "exit 6 is counted as a failure" "$WORKER" \
    's/            case ExitCode.heldElsewhere:/            case 99:/' \
    "c drain: exit 6 (held elsewhere) burns no attempt and keeps the take"
limb "a signal death reads as exit 0" "$WORKER" \
    's/        return (signalled ? 128 + p.terminationStatus : p.terminationStatus, reason, signalled)/        return (signalled ? 0 : p.terminationStatus, reason, signalled)/' \
    "c drain: an unlisted exit (a signal death) counts as an attempt and keeps the audio"
limb "no length ceiling" "$TRANSCRIBE" \
    's/        if let longest = durations.values.max(), longest > ceiling {/        if let longest = durations.values.max(), longest > ceiling * 1e9 {/' \
    "w a take longer than the ceiling exits 3 before any upload"

# ======================================================================== what gets sent
echo
echo "== what gets sent"
limb "an absent head count means one speaker" "$TRANSCRIBE" \
    's/            if m.expectedSpeakers == 1 { return (false, nil) }/            if m.expectedSpeakers ?? 1 == 1 { return (false, nil) }/' \
    "e a manifest with no expected_speakers diarizes the remote track"
limb "one remote speaker is diarized" "$TRANSCRIBE" \
    's/            if m.expectedSpeakers == 1 { return (false, nil) }/            if m.expectedSpeakers == 2 { return (false, nil) }/' \
    "e1 one remote speaker is not diarized"
limb "an unreadable WAV is treated as loud" "$WAV" \
    's/        let i = try info(path: path)/        guard let i = try? info(path: path) else { return 1.0 }/' \
    "h an unreadable WAV gives exit 3 and .unreadable, uploads nothing, keeps the audio"
limb "the silence threshold moves" "$WAV" \
    's/    public static let silenceThreshold = 5e-4/    public static let silenceThreshold = 5e-3/' \
    "silent: a track just above the threshold is not silent, one just below is"
limb "schema 3 is accepted" "$MANIFEST" \
    's/    public static let supportedSchemas: Set<Int> = \[1, 2\]/    public static let supportedSchemas: Set<Int> = [1, 2, 3]/' \
    "i manifest schema 3 gives exit 3 and no upload"
limb "the turn gap is ignored" "$RENDER" \
    's/    public static let turnGap = 1.2/    public static let turnGap = 100.0/' \
    "r line format: <n>, two spaces, [HH:MM:SS], speaker, colon, text"

# ======================================================================== consent and the key
echo
echo "== consent and the key"
limb "consent is not checked" "$TRANSCRIBE" \
    's/        switch Consent.state() {/        switch Consent.State.valid {/' \
    "f no consent file means no upload (exit 5)"
limb "a consent to any disclosure counts" "$CONSENT" \
    's/        guard let r = read(path), r.disclosure_sha256 == disclosureHash, r.version == version else { return .stale }/        guard let r = read(path), r.version == version else { return .stale }/' \
    "f a consent to another disclosure means no upload (exit 5)"
limb "consent does not need a terminal" "$MAIN" \
    's/    guard KeySource.stdinIsTerminal else {/    guard true else {/' \
    "j --consent-upload with stdin not a TTY exits 2 and writes no file"
limb "install does not need consent" "$MAIN" \
    's/    guard Consent.state() == .valid else {/    guard true else {/' \
    "install: without consent it is a dry run that writes nothing and exits 5"
limb "the plist carries an environment block" "$INSTALL" \
    's/            "ProcessType": "Background",/            "ProcessType": "Background", "EnvironmentVariables": ["X": "y"],/' \
    "install: the plist carries no EnvironmentVariables and no key"
limb "the env key is used without a terminal" "$KEYS" \
    's/        if interactive, let k = environment\["ELEVENLABS_API_KEY"\], !k.isEmpty {/        if let k = environment["ELEVENLABS_API_KEY"], !k.isEmpty {/' \
    "k ELEVENLABS_API_KEY is ignored when stdin is not a terminal"
limb "the API base override accepts any host" "$CLIENT" \
    's/        guard loopbackHosts.contains(h.lowercased()) else {/        guard !h.isEmpty else {/' \
    "override: a non-loopback API base is refused with exit 2 and nothing is sent"

# ======================================================================== review fixes
echo
echo "== review fixes"
limb "a valued flag's argument is read as the output dir" "$MAIN" \
    's/        if valuedFlags.contains(a) { j += 2; continue }/        if false { j += 2; continue }/' \
    "args: --drain --transcriber <path> drains the configured dir, not <path>/.work"
limb "relative paths are resolved twice" "$HANDOFF" \
    's/    let workDir = absolute(workDir), manifestPath = absolute(manifestPath), outputDir = absolute(outputDir)/    let workDir = workDir, manifestPath = manifestPath, outputDir = outputDir/' \
    "g2 a relative output dir still hands the transcriber a manifest path that exists"
limb "the idle timeout is a fixed 300 s" "$CLIENT" \
    's/    public static func requestTimeout(audioSeconds: Double) -> Double { resourceTimeout(audioSeconds: audioSeconds) }/    public static func requestTimeout(audioSeconds: Double) -> Double { 300 }/' \
    "c the idle timeout covers server processing: it is never shorter than the total timeout"
limb "every manifest is stamped schema 2" "$CAPMAN" \
    's/            "schema": needsSchema2 ? 2 : 1,/            "schema": 2,/' \
    "capture-manifest: a take with no schema-2 field is written as schema 1"
limb "the worker ignores the take's keep_audio" "$WORKER" \
    's/                } else if keepAudio || manifestKeepsAudio(dir) {/                } else if keepAudio {/' \
    "keep: a take recorded with --keep-audio keeps its audio through the worker"
limb "the capture CLI ignores the take's keep_audio" "$HANDOFF" \
    's/        let keepAudio = keepAudio || ((try? Manifest.load(path: manifestPath))?.keepAudio ?? false)/        let keepAudio = keepAudio/' \
    "keep: the capture CLI's delete honours keep_audio in the manifest too"
limb "--keep-audio is not written into the take" "$CAPMAN" \
    's/        if keepAudio { m\["keep_audio"\] = true }/        if false { m["keep_audio"] = true }/' \
    "capture-manifest: --keep-audio is written into the take as keep_audio, as schema 2"
limb "a dead holder's claim waits out the stale age" "$CLAIM" \
    's/            let dead = holderIsDead(seen)/            let dead = false/' \
    "claim: a fresh claim whose holder PID is dead is taken over at once"
limb "takeover is not serialised" "$CLAIM" \
    's/            guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {/            guard true else {/' \
    "claim: two takers of one stale claim, interleaved, leave exactly one holder"
limb "the takeover lock does not exclude a second taker" "$CLAIM" \
    's/            guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {/            guard true else {/' \
    "claim: two takers racing for a stale takeover lock leave exactly one claim holder"
limb "the capture CLI deletes without the claim" "$HANDOFF" \
    's/            if case .heldElsewhere(let why) = removeTakeHoldingClaim(workDir) {/            try? FileManager.default.removeItem(atPath: workDir); if case .heldElsewhere(let why) = TakeRemoval.removed {/' \
    "del: the capture CLI does not delete a proven take while another live runner holds its claim"
limb "the worker deletes without the claim" "$WORKER" \
    's/                    if case .heldElsewhere(let why) = removeTakeHoldingClaim(dir, log: log) {/                    try? fm.removeItem(atPath: dir); if case .heldElsewhere(let why) = TakeRemoval.removed {/' \
    "del: the worker does not delete a proven take while another live runner holds its claim"
limb "a vanished take aborts the drain" "$WORKER" \
    's/    func takeGone(_ dir: String) -> Bool { !fm.fileExists(atPath: dir) }/    func takeGone(_ dir: String) -> Bool { false }/' \
    "del: a take whose dir vanished mid-drain is skipped and the drain carries on"
limb "the installer does not wait for bootout" "$INSTALL" \
    's/            if !isLoaded() { return true }/            return true/' \
    "install: after bootout it waits until the job is gone, and gives up after its timeout"
limb "a relative transcriber reaches taskpolicy" "$HANDOFF" \
    's/    let transcriber = absolute(transcriber)/    let transcriber = transcriber/' \
    "g2 a relative transcriber path runs on the throttled path too"
limb "a take is deleted in place" "$CLAIM" \
    's/        guard rename(takeDir, tomb) == 0 else {/        guard rename(takeDir, takeDir) == 0 else {/' \
    "tomb: the take is out of .work/<id> before the recursive delete starts"
limb "a crash's tombstone is never cleaned" "$WORKER" \
    's/^        clearTombstones()$/        _ = 0/' \
    "tomb: a tombstone left by a crash is cleaned by the next drain, and is never transcribed"
limb "the stalled-send watchdog never fires" "$CLIENT" \
    's/        timer.setEventHandler { if watch.stalled(for: stallLimit) { task.cancel() } }/        timer.setEventHandler { }/' \
    "c a stalled upload is abandoned as transient long before the processing timeout"
limb "the watchdog also fires during processing" "$CLIENT" \
    's/        guard !didStall, !bodyDone, Date().timeIntervalSince(lastProgress) > limit else { return false }/        guard !didStall, Date().timeIntervalSince(lastProgress) > limit else { return false }/' \
    "c a slow answer after the whole body is sent is waited for, not called a stall"
limb "a kept, proven take is left unmarked" "$HANDOFF" \
    's/        } else if status == 0 \&\& keepAudio \&\& proveTake(manifestPath: manifestPath, outputDir: outputDir) == nil {/        } else if false {/' \
    "keep: a kept take the capture CLI already transcribed is marked done and never re-run"
limb "--output-dir is ignored by the worker commands" "$MAIN" \
    's/    let d = value(after: "--output-dir") ?? rest.first ?? config.output_dir ?? defaultOutputDir/    let d = rest.first ?? config.output_dir ?? defaultOutputDir/' \
    "args: --output-dir is honoured by --status, --requeue and --drain, over the config"
limb "--status ignores a dead holder" "$WORKER" \
    's/                      !TakeClaim.holderIsDead(read(d + "\/" + TakeClaim.fileName) ?? "") {/                      true {/' \
    "claim: --status shows a take whose claim holder is dead as pending, not claimed"
limb "the wait gives up without a last look" "$INSTALL" \
    's/        return !isLoaded()$/        return false/' \
    "install: a job that is gone right after the last wait still counts as gone"
limb "install() bootstraps without waiting" "$INSTALL" \
    's/        guard waitUntilUnloaded(isLoaded: { isLoaded(label, runner: runner) }, sleep: sleep) else {/        guard true else {/' \
    "install: bootstrap runs only after print says the old job is gone, and never while it stays"
limb "the doctor probe bootstraps without waiting" "$CORE/Doctor.swift" \
    's/        guard LaunchAgent.waitUntilUnloaded(isLoaded: { LaunchAgent.isLoaded(label, runner: runner) }, sleep: sleep) else {/        guard true else {/' \
    "doctor: the key probe bootstraps only after print says the old probe is gone, and never while it stays"

echo
echo "======================================================="
[ "$PASS" = 1 ] && echo "  TRANSCRIBE FALSIFICATION: PASS" || echo "  TRANSCRIBE FALSIFICATION: FAIL"
echo "======================================================="
[ "$PASS" = 1 ]
