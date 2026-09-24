#!/usr/bin/env bash
# Falsification for CaptureIO — the resampler, the WAV writer and the disk-backed
# capture sink. This is the code EVERY recording passes through.
#
# It is the last library in the package to get a harness, and it should have been the
# first. An outside reviewer wrote a throwaway probe against it and found that four of
# eight mutations to this library were NOT caught: the encoder could be switched from
# rounding to truncation, its clamp could be deleted, `padLead` could be given a 3x
# alignment error, and two exported functions had no caller at all. The suite stayed
# green through every one. A check that cannot fail is not coverage, it reads as
# coverage, and it had been reading as coverage over the user path.
#
# The tolerance is the lesson worth keeping. The equivalence cases compare the
# streaming path against the one-shot path, and both carry the same encoder, so a
# defect in that encoder moves both sides equally and the comparison never notices.
# Comparing a thing against itself measures agreement, never correctness. The cases
# those mutations bite are the ones that check the encoder against ARITHMETIC.
#
# Sources are mutated IN PLACE and restored by an EXIT trap. NOTE that the trap does
# not survive SIGKILL or an out-of-memory kill: if this script is killed outright, run
# `git diff` and expect to find a mutation still in the tree.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# Shared classifiers (here-strings, never a pipe into grep -q) and their 2 MB control.
. "$HERE/lib-mutations.sh"
lib_self_test || exit 1
cd "$HERE/.."
PASS=1

AUDIO="Sources/CaptureIO/Audio.swift"
SINK="Sources/CaptureIO/SampleSink.swift"

BACKUP="$(mktemp -d)"
for f in "$AUDIO" "$SINK"; do
    [ -f "$f" ] || { echo "   FAIL missing source: $f"; exit 1; }
done
cp "$AUDIO" "$BACKUP/Audio.swift"
cp "$SINK"  "$BACKUP/SampleSink.swift"
restore() {
    [ -f "$BACKUP/Audio.swift" ]      && cp "$BACKUP/Audio.swift" "$AUDIO"
    [ -f "$BACKUP/SampleSink.swift" ] && cp "$BACKUP/SampleSink.swift" "$SINK"
    rm -rf "$BACKUP"
}
trap restore EXIT INT TERM

ok()   { echo "   ok   $1"; }
bad()  { echo "   FAIL $1"; PASS=0; }

echo "== audio-pipeline-check (baseline)"
base_scratch="$(mktemp -d)"
if swift run --scratch-path "$base_scratch" audio-pipeline-check >/dev/null 2>&1; then ok "audio-pipeline-check passes clean"
else bad "audio-pipeline-check does NOT pass clean"; fi
rm -rf "$base_scratch"

echo
echo "== audio-pipeline-check under mutation — each must break its NAMED case"

mutate_swift() {
    local label="$1" expect="$2" file="$3" expr="$4"
    local before; before="$(mktemp)"; cp "$file" "$before"
    sed -i '' "$expr" "$file"
    if cmp -s "$before" "$file"; then
        bad "$label — the sed changed NOTHING, so this limb tested nothing"
        cp "$before" "$file"; rm -f "$before"; return
    fi
    # A FRESH scratch path per mutation, so SPM's mtime check cannot hand back the
    # previous build and score the last mutation as this one.
    local out rc scratch
    scratch="$(mktemp -d)"
    out="$(swift run --scratch-path "$scratch" audio-pipeline-check 2>&1)"; rc=$?
    rm -rf "$scratch"
    cp "$before" "$file"; rm -f "$before"
    if [ $rc -eq 0 ]; then
        bad "$label — the suite still EXITED 0 under mutation"
        return
    fi
    # THE NAMED CASE IS MATCHED FIRST. A Swift diagnostic quotes the offending source
    # line back, so a clean run can carry the substring `error: ` in its output, and
    # testing for a build failure first scores a real bite as "did not build".
    if contains "FAIL $expect" "$out"; then
        ok "$label -> \"$expect\" bit"
        return
    fi
    if contains_re ': error: |Fatal error|Illegal instruction|Trace/BPT' "$out"; then
        bad "$label — the mutation did not RUN clean (build error or trap); it tested nothing"
        return
    fi
    bad "$label — the suite failed, but NOT on \"$expect\""
}

# --- THE ENCODER. Every sample of every recording goes through these two lines, and
# --- until section 5 of the check existed neither could be falsified.

# Truncation instead of rounding. Inaudible per sample, a DC-shifted quieter recording
# across a meeting, and invisible to any check that compares the encoder against a copy
# of itself.
mutate_swift "truncate instead of rounding in the PCM16 encoder" \
    "every sample is the ROUNDED PCM16 value, exactly" "$AUDIO" \
    's/for f in samples { pcm.append(Int16((max(-1, min(1, f)) \* 32767).rounded())) }/for f in samples { pcm.append(Int16(max(-1, min(1, f)) * 32767)) }/'

# Delete the clamp. The equivalence fixture peaks at 0.82, so nothing there reaches it;
# only a fixture that exceeds +-1 can tell. Unclamped, a loud passage wraps to
# full-scale noise of the opposite sign.
mutate_swift "remove the clamp from the streaming PCM16 encoder" \
    "over-unity samples clamp to full scale instead of wrapping" "$AUDIO" \
    's/for f in samples { pcm.append(Int16((max(-1, min(1, f)) \* 32767).rounded())) }/for f in samples { pcm.append(Int16(truncatingIfNeeded: Int(f * 32767))) }/'

# --- ALIGNMENT. padLead decides where a track starts relative to the other one.

# Count the lead at the TARGET rate rather than the native one: a 3x error at 48 kHz,
# which shifts every timestamp in the resulting transcript.
mutate_swift "count lead frames at the target rate instead of the native rate" \
    "padLead prepends lead frames counted at the NATIVE rate" "$AUDIO" \
    's|let leadFrames = Int((Double(leadNs) / 1_000_000_000.0) \* nativeRate)|let leadFrames = Int((Double(leadNs) / 1_000_000_000.0) * targetRate)|'

# Append the pad instead of prepending it. The take is the right LENGTH and every
# timestamp in it is wrong, which is the failure a duration check cannot see.
mutate_swift "append the alignment pad instead of prepending it" \
    "padLead's padding is silence and the body survives it" "$AUDIO" \
    's|return \[Float\](repeating: 0, count: leadFrames) + samples|return samples + [Float](repeating: 0, count: leadFrames)|'

# --- THE DESTINATION. A failure must leave no file where a recording was announced.

# THREE edits, because the invariant is structural: the writer opens the destination,
# nothing is moved into place, and the pre-existing-file guard is neutralised. A
# one-line sed leaves the function incoherent and fails to build, which tests nothing.
mutate_swift "open the destination directly instead of writing to a temp file" \
    "and leaves NO file at the destination" "$AUDIO" \
    's|let writer = try WavWriter(path: tmpPath)|let writer = try WavWriter(path: path)|; s|if FileManager.default.fileExists(atPath: path) {|if false {|; s|try FileManager.default.moveItem(atPath: tmpPath, toPath: path)||'

# --- THE SINK. The disk-backed buffer that keeps a long meeting out of memory.

# Skip the final drain: the tail of every recording is silently lost.
mutate_swift "skip the final drain in finish()" \
    "finish() on a sink that was never started still writes its staging" "$SINK" \
    's/        writeChunk(remainder)//'

# Sum the channels instead of averaging them. Anything centred in the mix clips.
mutate_swift "sum the stereo pair instead of averaging it" \
    "a stereo pair is averaged, not summed" "$SINK" \
    's|let mono = acc / Float(channels)|let mono = acc|'

# The peak must be reset when it is read, or a quiet interval reports the loudest
# moment of the meeting and the silence gate never fires.
mutate_swift "make the level peak read non-destructive" \
    "the peak read is destructive" "$SINK" \
    's/let p = levelPeak; levelPeak = 0; return p/let p = levelPeak; return p/'

echo
echo "======================================================="
if [ $PASS -eq 1 ]; then echo "  CAPTUREIO FALSIFICATION: PASS"
else echo "  CAPTUREIO FALSIFICATION: FAIL"; fi
echo "======================================================="
echo
echo "KNOWN GAP, stated rather than hidden: there is no mutation here for"
echo "SampleSink's write-error propagation — the contract at SampleSink.swift that"
echo "finish() THROWS any error the background thread hit. Removing the error capture"
echo "makes finish() stop throwing, and no check catches it, because forcing a real"
echo "write failure needs a full or read-only filesystem that a check running on any"
echo "machine cannot assume. It is a real hole and it is the next one to close."
[ $PASS -eq 1 ]
