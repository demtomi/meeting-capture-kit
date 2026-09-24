#!/usr/bin/env bash
# Falsification for SilenceGate — the "should this recording still be running?" decision.
#
# `swift run silence-gate-check` passes. A suite that passes is evidence about nothing
# until a defect makes it fail (D-48, D-49), so every limb here is broken on purpose and
# the NAMED check must go red — not merely "the suite failed", which a compile error
# would also produce.
#
# THIS DECISION IS WORTH THE HARNESS because both directions of getting it wrong are
# silent and expensive, and they are opposites:
#   · stop too late  — every idle minute is uploaded and billed (the 2026-07-27 overrun,
#     28.6 min of dead air, ~19,000 credits)
#   · stop too early — the meeting is truncated mid-sentence and there is no second copy
# Nothing in the recording's own output says which one happened.
#
# TWO KINDS OF LIMB.
#
#   A. SOURCE INVARIANTS. Claims about the shape of the code that no compiler and no unit
#      test can check, because what is asserted is an ABSENCE or an ORDERING. "Time is
#      injected, never read from a clock" is not a value any function returns, and
#      "the warn fuse burns before the stop fuse" is true of two numbers that live six
#      lines apart with nothing between them. Grep is a weak instrument, so each is
#      watched to flip under a mutation before it is believed.
#
#   B. SUITE MUTATIONS. Each breaks one limb of silence-gate-check, by name.
#
# Sources are mutated IN PLACE and restored by an EXIT trap, so an interrupt still puts
# the tree back. Nothing here needs a microphone, a display, a TCC grant, the network,
# or a credit: the whole decision replays against Fixtures/overrun-trace.levels.
set -uo pipefail

# The package root is the PARENT of Scripts/, and the paths below are relative to it.
HERE="$(cd "$(dirname "$0")" && pwd)"
# Shared classifiers (here-strings, never a pipe into grep -q) and their 2 MB control.
. "$HERE/lib-mutations.sh"
lib_self_test || exit 1
cd "$HERE/.."
PASS=1

GATE="Sources/SilenceGate/SilenceGate.swift"
CHECK="Sources/silence-gate-check/main.swift"
FIXTURE="Fixtures/overrun-trace.levels"

# ---------------------------------------------------------------- restore trap
BACKUP="$(mktemp -d)"
cp "$GATE"  "$BACKUP/SilenceGate.swift"
cp "$CHECK" "$BACKUP/check-main.swift"
restore() {
    cp "$BACKUP/SilenceGate.swift" "$GATE"
    cp "$BACKUP/check-main.swift"  "$CHECK"
    rm -rf "$BACKUP"
}
trap restore EXIT INT TERM

ok()  { echo "   ok   $1"; }
bad() { echo "   FAIL $1"; PASS=0; }

# CODE ONLY, comments stripped. This file's subject is a source file whose doc comments
# quote the very numbers and names the invariants are about — "0.08 measured on the
# 2026-07-27 overrun take" sits three lines above the constant. A substring classifier
# over prose reads the commentary as the code (the screen-recording harness reported two
# invariants broken at baseline for exactly this reason, and both hits were its own
# doc comments).
code() { grep -v '^[[:space:]]*//' "$1"; }

# COUNT, never `grep -q`, and never a bare pipeline as the return value. `! producer |
# grep -q X` under `set -o pipefail` is INVERTED: grep -q exits on first match, the
# producer takes SIGPIPE, pipefail reports failure, and `!` turns that into success.
# Measured on the screen-recording harness: a file with 5 occurrences reported "absent".
occurrences() { code "$2" | grep -c "$1"; }
absent()  { [ "$(occurrences "$1" "$2")" -eq 0 ]; }

# The body of the function whose signature line contains $2, by brace depth. Needed
# because two of the claims below are about WHERE a call appears: `hostTalkingRecently`
# is defined in this file and must be CONSULTED inside decide(), and a file-wide grep
# cannot tell a definition from a use.
func_body() {
    awk -v sig="$2" '
        !started && index($0, sig) { started = 1 }
        started {
            print
            o = gsub(/\{/, "&"); c = gsub(/\}/, "&")
            depth += o - c
            if (o > 0) opened = 1
            if (opened && depth <= 0) exit
        }' "$1"
}

# ================================================================= A. source invariants

# The header's first claim: "pure logic with no AppKit, no Date(), and no capture
# dependency". A clock read here is not a style point — it is what makes a 50-minute
# meeting stop being replayable in milliseconds, and it makes the fixture replay
# non-deterministic in a way that shows up as a flaky check months later.
inv_gate_reads_no_clock() {
    local n=0 t
    for t in "Date(" DispatchTime CFAbsoluteTime ProcessInfo "Timer(" mach_absolute_time; do
        n=$(( n + $(occurrences "$t" "$GATE") ))
    done
    [ "$n" -eq 0 ]
}

# The library half must stay replayable with nothing plugged in. The moment it imports
# AppKit or a capture framework, the whole decision stops being checkable without a
# desktop and a TCC grant, and the limbs below quietly become things only Host can run.
inv_gate_is_pure() {
    absent "import AppKit" "$GATE" \
        && absent "import AVFoundation" "$GATE" \
        && absent "import ScreenCaptureKit" "$GATE" \
        && absent "FileManager" "$GATE" \
        && absent "URLSession" "$GATE"
}

# ORDERING, not absence: on each path the warning must burn before the stop, or the
# recording dies with no banner ever shown. Nothing in the type enforces it — they are
# four independent stored properties with defaults.
#
# The extraction asserts all four numbers were FOUND. A fuse expressed some other way
# extracts empty, and an empty-vs-empty comparison would read green for the rest of this
# file's life (the D-49 shape).
fuse() { code "$GATE" | sed -n "s/.*$1: TimeInterval = \([0-9][0-9]*\) \* 60.*/\1/p" | head -1; }
inv_warn_burns_before_stop() {
    local mw ms rw rs
    mw="$(fuse micWarnAfter)";    ms="$(fuse micStopAfter)"
    rw="$(fuse remoteWarnAfter)"; rs="$(fuse remoteStopAfter)"
    [ -n "$mw" ] && [ -n "$ms" ] && [ -n "$rw" ] && [ -n "$rs" ] \
        && [ "$mw" -lt "$ms" ] && [ "$rw" -lt "$rs" ]
}

# `micActiveLevel` asks "is the host TALKING"; `level` asks "is there any sound at all".
# Collapse the two and dead-room noise holds every recording open forever — the exact
# failure the 0.08 threshold was measured to avoid (dead-air p50 0.0246 vs a 7.2 min run
# below 0.08 in the dead room after the call).
level_of() { code "$GATE" | sed -n "s/.*$1: Float = \([0-9.]*\).*/\1/p" | head -1; }
inv_talking_threshold_is_above_audible() {
    local lv act
    lv="$(level_of "var level")"; act="$(level_of micActiveLevel)"
    [ -n "$lv" ] && [ -n "$act" ] \
        && [ "$(awk -v a="$act" -v b="$lv" 'BEGIN { print (a > b) ? 1 : 0 }')" = 1 ]
}

# THE TWO DOORS. A stop needs the remote gone AND the host not mid-sentence. The second
# condition can only ever PREVENT a stop, so its worst case is over-recording — which is
# the accepted failure, and why it is safe to keep. Losing it is not.
inv_stop_needs_both_doors() {
    [ "$(func_body "$GATE" "func decide(at" | grep -c 'hostTalkingRecently')" -ge 1 ]
}

# `remoteEverLive` is the load-bearing condition in the gate, not bookkeeping: a system
# capture that silently failed reads 0.0000 from the first second and is indistinguishable
# from a call that hung up. Without this, a broken capture stops a LIVE meeting at 8:00.
inv_remote_gate_requires_a_live_track() {
    [ "$(func_body "$GATE" "var isRemoteGated" | grep -c 'remoteEverLive')" -ge 1 ]
}

# The fixture IS the evidence base. A replay against a fixture that shrank to a stub
# passes everything and measures nothing, so the count is asserted here rather than
# trusted — the check itself refuses on a missing file, but not on a gutted one.
inv_fixture_is_the_real_trace() {
    [ -f "$FIXTURE" ] && [ "$(grep -c '^[0-9]' "$FIXTURE")" -ge 500 ]
}

echo "== A. source invariants (baseline)"
for inv in inv_gate_reads_no_clock inv_gate_is_pure inv_warn_burns_before_stop \
           inv_talking_threshold_is_above_audible inv_stop_needs_both_doors \
           inv_remote_gate_requires_a_live_track inv_fixture_is_the_real_trace; do
    if $inv; then ok "$inv"; else bad "$inv failed at BASELINE"; fi
done

echo
echo "== A. source invariants under mutation — each must FLIP"
mutate_invariant() {
    local label="$1" inv="$2" file="$3" expr="$4"
    local before; before="$(mktemp)"; cp "$file" "$before"
    sed -i '' "$expr" "$file"
    if cmp -s "$before" "$file"; then
        bad "$label — the sed changed NOTHING, so this limb tested nothing"
        cp "$before" "$file"; rm -f "$before"; return
    fi
    if $inv; then bad "$label — $inv still passed under mutation"; else ok "$label -> $inv flipped"; fi
    cp "$before" "$file"; rm -f "$before"
}

# CODE, not a comment. A mutation inserted as a comment is stripped by `code` before it
# is counted, so the file changes, the sed-did-nothing guard is satisfied, and the
# invariant "still passes" for the one reason that proves nothing about it.
mutate_invariant "read the wall clock instead of the injected elapsed time" \
    inv_gate_reads_no_clock "$GATE" \
    's|^    private var lastAudioAt: TimeInterval = 0$|    private var startedAt = Date()\n    private var lastAudioAt: TimeInterval = 0|'

mutate_invariant "pull AppKit into the pure decision" inv_gate_is_pure "$GATE" \
    's/^import Foundation$/import Foundation\nimport AppKit/'

# The remote fuse pushed PAST its stop, so the warning never fires and the recording
# dies with no banner. Mutating the warn rather than the stop is deliberate: raising a
# warn reads as "fewer nags" in review, which is how the ordering gets inverted.
mutate_invariant "push the remote warning past the remote stop" \
    inv_warn_burns_before_stop "$GATE" \
    's/remoteWarnAfter: TimeInterval = 5 \* 60/remoteWarnAfter: TimeInterval = 9 * 60/'

mutate_invariant "collapse the talking threshold onto the any-sound threshold" \
    inv_talking_threshold_is_above_audible "$GATE" \
    's/micActiveLevel: Float = 0.08/micActiveLevel: Float = 0.02/'

mutate_invariant "let the stop through on the remote door alone" \
    inv_stop_needs_both_doors "$GATE" \
    's/return hostTalkingRecently(at: t) ? .warn : .stop/return .stop/'

mutate_invariant "gate on the track existing rather than on it ever being live" \
    inv_remote_gate_requires_a_live_track "$GATE" \
    's/config.isVirtual \&\& hasSystemTrack \&\& remoteEverLive/config.isVirtual \&\& hasSystemTrack/'

# The fixture invariant is the one that must not be believed on a baseline pass: every
# other mutation here edits Swift, so this one would read green all run whatever it was
# measuring. Truncated in a COPY and restored by byte count, never re-generated.
FIXTURE_BAK="$(mktemp)"
cp "$FIXTURE" "$FIXTURE_BAK"
head -20 "$FIXTURE_BAK" > "$FIXTURE"
if inv_fixture_is_the_real_trace; then
    bad "gut the level trace to a stub -> inv_fixture_is_the_real_trace still passed"
else
    ok "gut the level trace to a stub -> inv_fixture_is_the_real_trace flipped"
fi
cp "$FIXTURE_BAK" "$FIXTURE"; rm -f "$FIXTURE_BAK"

# ===================================================================== B. suite baseline
echo
echo "== B. silence-gate-check (baseline)"
# The baseline gets its own scratch path for the same reason every mutation
# does: this script must not write into the caller's `.build`. It used to run
# here with no --scratch-path, so a single harness run left about 100 MB of
# build output behind and the README's claim that it leaves your .build alone
# was false on the first line that builds anything.
base_scratch="$(mktemp -d)"
if swift run --scratch-path "$base_scratch" silence-gate-check >/dev/null 2>&1; then ok "silence-gate-check passes clean"
else bad "silence-gate-check does NOT pass clean"; fi
rm -rf "$base_scratch"

echo
echo "== B. silence-gate-check under mutation — each must break its NAMED limb"
mutate_swift() {
    local label="$1" expect="$2" file="$3" expr="$4"
    local before; before="$(mktemp)"; cp "$file" "$before"
    sed -i '' "$expr" "$file"
    if cmp -s "$before" "$file"; then
        bad "$label — the sed changed NOTHING, so this limb tested nothing"
        cp "$before" "$file"; rm -f "$before"; return
    fi
    # A FRESH scratch path per mutation: restoring with `cp` and re-`sed`ing lands both
    # writes in the same second, and SPM's mtime check can then hand back the PREVIOUS
    # build — a harness silently measuring the last mutation instead of this one.
    local out rc scratch
    scratch="$(mktemp -d)"
    out="$(swift run --scratch-path "$scratch" silence-gate-check 2>&1)"; rc=$?
    rm -rf "$scratch"
    cp "$before" "$file"; rm -f "$before"
    if [ $rc -eq 0 ]; then
        bad "$label — the suite still EXITED 0 under mutation"
        return
    fi
    # A build error fails for every mutation equally and says nothing about the limb, so
    # it is separated from a real red rather than scored as one.
    if contains_re 'error: |Compiling for macOS.*error' "$out"; then
        bad "$label — the mutation did not BUILD; it tested nothing"
        return
    fi
    # silence-gate-check prints "  FAIL  <label>" — TWO spaces. grep -F, so the
    # parentheses and colons in the limb names are literal.
    if contains "FAIL  $expect" "$out"; then
        ok "$label -> \"$expect\" bit"
    else
        bad "$label — expected \"$expect\" to fail; suite failed on: $(first_lines '  FAIL  ' "$out")"
    fi
}

# --- The remote gate. Two ways to lose the "never live" condition, and they are
# --- different edits reaching the same catastrophe: a recording whose system capture
# --- silently failed is auto-stopped at 8:00 while the meeting is still running.

mutate_swift "gate on the track existing rather than on it ever being live" \
    "never auto-stops when the system track was never live" "$GATE" \
    's/config.isVirtual \&\& hasSystemTrack \&\& remoteEverLive/config.isVirtual \&\& hasSystemTrack/'

# The same defect arrived at from the other end, and the more likely one: the flag is
# still consulted, it is just latched when the track APPEARS instead of when it first
# makes a sound. Every line of the gate still reads correctly.
mutate_swift "latch remoteEverLive on the track appearing, not on a sound" \
    "never auto-stops when the system track was never live" "$GATE" \
    's|^            hasSystemTrack = true$|            hasSystemTrack = true\n            remoteEverLive = true|'

# --- Which clock decides. The whole 2026-07-27 finding is that the mic cannot: room
# --- noise and live speech overlap almost completely, so a mic-driven decision never
# --- stops anything.

# NAMED AT THE FIRST LIMB IT BREAKS, and it breaks three. Limbs 2 and 3 are written as
# `(live.stopAt ?? 0) > …` and `(live.stopAt ?? .infinity) <= …`, so ANY mutation that
# produces no stop at all trips all three. That is structural, not a defect in the
# mutation: there is no edit that removes the stop from limb 1 while leaving a stop for
# limbs 2 and 3 to measure.
mutate_swift "let the mic clock decide on a virtual call" \
    "stops the overrun recording (it ran 50:00 unstopped)" "$GATE" \
    's/max(0, t - (isRemoteGated ? lastRemoteAudioAt : lastAudioAt))/max(0, t - lastAudioAt)/'

# The fuse LENGTH, mutated on its own. The remote gate still decides, the stop still
# happens, and the only thing that moves is WHEN — 18 min after the call ended instead
# of 8. Limbs 1 and 2 stay green, which is the point: this is the mutation that proves
# the 10-minute limb is doing work of its own.
mutate_swift "burn the mic-length fuse on the remote-gated path" \
    "stop lands within 10 min of the call ending" "$GATE" \
    's/^        let stopAfter = isRemoteGated ? config.remoteStopAfter : config.micStopAfter$/        let stopAfter = config.micStopAfter/'

# --- The second door. Cutting a recording while the host is still speaking is the one
# --- outcome the owner named as unacceptable, and it is invisible until a real call.

mutate_swift "remove the host-talking door from the stop" \
    "a 60-min monologue is NEVER auto-stopped" "$GATE" \
    's/return hostTalkingRecently(at: t) ? .warn : .stop/return .stop/'

# The opposite direction, and the one that reads as a safety improvement: make the door
# trigger on ANY sound. Then dead-room noise sitting between 0.02 and 0.08 holds every
# recording open forever, and the overrun this whole library exists to stop comes back.
mutate_swift "collapse the talking threshold onto the any-sound threshold" \
    "room noise below the talking threshold does NOT veto the stop" "$GATE" \
    's/micActiveLevel: Float = 0.08/micActiveLevel: Float = 0.02/'

# --- "Keep recording" on the banner. It resets BOTH clocks or it resets nothing worth
# --- resetting: on the remote-gated path it is the remote clock that fired.

# Named at limb 14 because that is the first to go red. Limbs 15 and 16 fall with it and
# cannot be separated: all three assert the same reset, at three distances from it.
mutate_swift "reset only the any-audio clock on keep-recording" \
    "keepRecording clears the warning" "$GATE" \
    's/^        lastRemoteAudioAt = t$//'

# --- The parser. A missing `sys=` field means THERE IS NO SYSTEM CAPTURER. A track that
# --- does not exist has not gone quiet, and conflating the two auto-stops every
# --- in-person recording.

mutate_swift "default a missing sys= field to 0" \
    "a line with no sys= field parses to sys: nil, NOT sys: 0" "$GATE" \
    's/return LevelSample(mic: mic, sys: sys)/return LevelSample(mic: mic, sys: sys ?? 0)/'

# THE SECOND GUARD, on its own. The check deliberately holds two independent defences
# here — the parse nil-ness and `remoteEverLive` — and says so: "breaks only if BOTH are
# dropped". So the mutation has to drop both, and it is written as one edit that reads
# like a simplification: treat the absent field as a silent track.
mutate_swift "read an absent system track as a silent one" \
    "an absent sys= field leaves the gate ungated (second, independent guard)" "$GATE" \
    's|^        if let s = sample.sys {$|        if true {\n            let s = sample.sys ?? 0\n            remoteEverLive = true|'

# --- The mic-only backstop. It exists, it is deliberately long, and both of the
# --- negative controls in the check exist to prove it can never substitute for the
# --- remote signal.

# Stop feeding the any-audio clock from the mic and the legacy collapsed trace — which
# has no other clock — goes quiet from t=0 and stops at 18:00, reproducing the bug the
# per-track split was introduced to fix.
mutate_swift "stop feeding the any-audio clock from the mic" \
    "legacy single-number trace does NOT stop (reproduces the bug)" "$GATE" \
    's/^        if let m = sample.mic, m >= config.level { lastAudioAt = t }$//'

# The mic-only fuse SHORTENED until room noise can trip it. 18 min is not a round number
# picked for comfort: measured on this trace, the longest gap between mic peaks at a 10x
# threshold is 8:10, so the backstop clears it with margin. At 6 min it does not, and a
# recording with a working mic auto-stops on silence that is not silence.
mutate_swift "shorten the mic-only backstop until room noise trips it" \
    "even a 10x mic threshold does not stop the recording" "$GATE" \
    's/micStopAfter: TimeInterval = 18 \* 60/micStopAfter: TimeInterval = 6 * 60/'

# --- The remote-quiet hint. On a mic-only recording there is no "other side" to have
# --- gone quiet, and showing one is an invented signal on the pill.

mutate_swift "invent a remote-quiet mark on a recording with no remote track" \
    "no remote-quiet hint is ever shown in-person" "$GATE" \
    's|^        guard isRemoteGated, quietFor(at: t) >= config.remoteQuietHint else { return nil }$||'

# --- The warning. A recording that stops with no banner first is a recording that
# --- stopped without the host being given the chance to say no.

# The fuse collapsed onto the stop: no window, so no banner. Limb 16 falls with it —
# both read `decide` inside the same 5-to-8-minute window and there is no edit that
# separates them.
mutate_swift "collapse the warn fuse onto the stop fuse" \
    "warns once the remote goes quiet past the fuse" "$GATE" \
    's/remoteWarnAfter: TimeInterval = 5 \* 60/remoteWarnAfter: TimeInterval = 8 * 60/'

# TWO SEDS, and the first version of this mutation is why. Named against limb 11 — a
# recording held open by the host's own voice must still SAY so — it removed the warn
# branch alone and limb 11 STAYED GREEN, because the held-open stop returns `.warn` and
# supplies the banner by itself. Aimed the other way it fails identically: turn the
# held-open return into `.keepGoing` on its own and the warn branch still fires in the
# 5-to-8 minute window before the stop branch is ever reached.
#
# So limb 11 has TWO independent sources of its warning and the mutation has to remove
# both, exactly as limb 9 above holds two independent guards and says so. Scoring the
# one-sed version as a bite would have credited limbs 13 and 16 — the two that did go
# red — to a limb nothing had touched. Limbs 13 and 16 fall here too, for the same
# reason they fall together above.
mutate_swift "hold the recording open with no banner at all" \
    "...but it still warns, so the recording never goes silently unattended" "$GATE" \
    's/^        if quiet >= warnAfter { return .warn }$//;s/return hostTalkingRecently(at: t) ? .warn : .stop/return hostTalkingRecently(at: t) ? .keepGoing : .stop/'

echo
echo "======================================================="
[ "$PASS" = 1 ] && echo "  SILENCE GATE FALSIFICATION: PASS" || echo "  SILENCE GATE FALSIFICATION: FAIL"
echo "======================================================="
[ "$PASS" = 1 ]
