#!/usr/bin/env bash
# Falsification for LiveAudio — the live path's audio arithmetic: the streaming
# resampler, the mixer, the bounded PCM ring, the wire format and the frame assembler.
#
# `swift run live-audio-check` passes. A suite that passes is evidence about nothing until
# a defect makes it fail, so every limb here is broken on purpose and the NAMED check must
# go red — not merely "the suite failed", which a compile error would also produce.
#
# TWO KINDS OF LIMB.
#
#   A. SOURCE INVARIANTS. Claims about the shape of the code that no compiler and no unit
#      test can check, because what is asserted is an ABSENCE. "LiveAudio never writes
#      disk" is not a value any function returns. Grep is a weak instrument, so each is
#      watched to flip under a mutation before it is believed.
#
#   B. SUITE MUTATIONS. Each breaks one limb of live-audio-check, by name.
#
# SCOPE. This package ships the LIBRARY, not the tap executable that feeds it. The
# invariants that asserted the tap's thread discipline, its lack of a stdin path and the
# byte-identity of its capture selection against the original spike were carved out with
# those files; they are gone rather than left pointing at sources that do not exist. What
# remains is every claim about LiveAudio itself, which is where all the arithmetic lives.
#
# Sources are mutated IN PLACE and restored by an EXIT trap, so an interrupt still puts the
# tree back. Nothing here writes outside the package, and nothing here needs a
# device, a display, a TCC grant, the network, or a credit.
set -uo pipefail

# The package root is the PARENT of Scripts/, and the paths below are relative to it.
HERE="$(cd "$(dirname "$0")" && pwd)"
# Shared classifiers (here-strings, never a pipe into grep -q) and their 2 MB control.
. "$HERE/lib-mutations.sh"
lib_self_test || exit 1
cd "$HERE/.."
PASS=1

LIVE_SRC="Sources/LiveAudio"
RESAMP="$LIVE_SRC/StreamingResampler.swift"
RING="$LIVE_SRC/PCMRing.swift"
MIXER="$LIVE_SRC/Mixer.swift"
WIRE="$LIVE_SRC/WireFormat.swift"
ASM="$LIVE_SRC/FrameAssembler.swift"
# The check target is mutated too, for the two INSTRUMENT limbs — the ones that assert
# maxStep can resolve a boundary seam and dominantHz can tell 404 Hz from 440. Those are
# not claims about LiveAudio, they are claims about whether the limbs beside them are
# looking at anything, and they fail the same way everything else does: silently.
CHECK="Sources/live-audio-check/main.swift"
CAPTURE_SRC="Sources/MeetingCaptureCLI"

# ---------------------------------------------------------------- restore trap
# Only files that EXIST are backed up and restored. A trap that copies a file which is not
# there fails partway and leaves the tree mutated, which is the worst outcome this script
# can produce.
BACKUP="$(mktemp -d)"
for f in "$RESAMP" "$RING" "$MIXER" "$WIRE" "$ASM" "$CHECK"; do
    [ -f "$f" ] || { echo "   FAIL missing source: $f"; exit 1; }
done
[ -d "$CAPTURE_SRC" ] || { echo "   FAIL missing target dir: $CAPTURE_SRC"; exit 1; }
cp "$RESAMP" "$RING" "$MIXER" "$WIRE" "$ASM" "$BACKUP/"
cp "$CHECK" "$BACKUP/check-main.swift"
CAPTURE_SHA_BEFORE="$(find "$CAPTURE_SRC" -type f -name '*.swift' -exec shasum {} + | shasum | awk '{print $1}')"
# The probe file the untouched-target invariant is falsified with. Named here, above the
# trap, so an interrupt between creating it and removing it cannot leave a stray source
# file sitting in the capture CLI.
CAPTURE_PROBE="$CAPTURE_SRC/.mutation-probe.swift"
restore() {
    rm -f "$CAPTURE_PROBE"
    [ -f "$BACKUP/StreamingResampler.swift" ] && cp "$BACKUP/StreamingResampler.swift" "$RESAMP"
    [ -f "$BACKUP/PCMRing.swift" ]            && cp "$BACKUP/PCMRing.swift"            "$RING"
    [ -f "$BACKUP/Mixer.swift" ]              && cp "$BACKUP/Mixer.swift"              "$MIXER"
    [ -f "$BACKUP/WireFormat.swift" ]         && cp "$BACKUP/WireFormat.swift"         "$WIRE"
    [ -f "$BACKUP/FrameAssembler.swift" ]     && cp "$BACKUP/FrameAssembler.swift"     "$ASM"
    [ -f "$BACKUP/check-main.swift" ]         && cp "$BACKUP/check-main.swift"         "$CHECK"
    rm -rf "$BACKUP"
}
trap restore EXIT INT TERM

ok()  { echo "   ok   $1"; }
bad() { echo "   FAIL $1"; PASS=0; }

# CODE ONLY, comments stripped. A substring classifier over prose reads the prohibition as
# the violation, and this file's comments talk about writing to disk at length.
code_tree() { grep -rh -v '^[[:space:]]*//' "$1"; }

# COUNT, never `grep -q`, and never a bare pipeline as the return value. `! producer |
# grep -q X` under `set -o pipefail` is INVERTED: grep -q exits on first match, the producer
# takes SIGPIPE, pipefail reports failure, and `!` turns that into success. Measured on the
# screen-recording harness: a file with 5 occurrences reported "absent".
occurrences() { code_tree "$2" | grep -c "$1"; }
absent()  { [ "$(occurrences "$1" "$2")" -eq 0 ]; }

# ================================================================= A. source invariants

# The ring lives inside an audio callback and the whole live path is memory-only: it never
# blocks and never writes disk. A file API reaching this target is the same defect class
# the consumer side guards, in the other language.
#
# The token list is DELIBERATELY narrower than "anything file-shaped". Its first version
# carried a bare `contentsOf:` and failed at baseline on `Data.append(contentsOf:)` in the
# mixer's little-endian encoder — a substring classifier matching a method that never
# touches a filesystem. A token that fires on innocent code gets deleted by the next person
# who sees it go red, and the invariant goes with it.
inv_no_file_api() {
    local n=0 t
    for t in FileHandle FileManager "write(to:" "URL(fileURLWithPath" \
             OutputStream "Data(contentsOf" "String(contentsOf" NSFileHandle; do
        n=$(( n + $(occurrences "$t" "$LIVE_SRC") ))
    done
    [ "$n" -eq 0 ]
}

# The library is the half that needs no device. If ScreenCaptureKit or AVCaptureSession
# reach it, the check target stops being runnable without a TCC grant and every limb below
# quietly becomes something only a workstation can run.
inv_no_capture_frameworks() {
    absent "import ScreenCaptureKit" "$LIVE_SRC" \
        && absent "AVCaptureSession" "$LIVE_SRC" \
        && absent "SCStream" "$LIVE_SRC"
}

# The one-shot whole-array converter must not be reused: it lives in the capture CLI, and
# reaching for it here means the live path inherits a converter that resets its state at
# every chunk boundary — the exact defect StreamingResampler exists to avoid.
inv_no_reuse_of_batch_resampler() {
    absent "resampleTo16k" "$LIVE_SRC" && absent "import MeetingCaptureCLI" "$LIVE_SRC"
}

# `.endOfStream` per chunk IS the one-shot behaviour: it drains and resets the converter.
# The whole point of this type is that it does not.
inv_incremental_feed_not_endofstream() {
    absent "endOfStream" "$RESAMP"
}

# The capture CLI is the archival path and this harness has no business in it. Not a grep —
# a content hash of the whole target, taken before any mutation ran.
inv_capture_cli_untouched() {
    local now
    now="$(find "$CAPTURE_SRC" -type f -name '*.swift' -exec shasum {} + | shasum | awk '{print $1}')"
    [ "$now" = "$CAPTURE_SHA_BEFORE" ]
}

echo "== A. source invariants (baseline)"
for inv in inv_no_file_api inv_no_capture_frameworks inv_no_reuse_of_batch_resampler \
           inv_incremental_feed_not_endofstream inv_capture_cli_untouched; do
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

mutate_invariant "spill the ring to a debug file" inv_no_file_api "$RING" \
    's|^        return out$|        try? Data().write(to: URL(fileURLWithPath: "/tmp/ring.bin")); return out|'

mutate_invariant "pull ScreenCaptureKit into the library" inv_no_capture_frameworks "$RESAMP" \
    's/^import AVFoundation$/import AVFoundation\nimport ScreenCaptureKit/'

# CODE, not a comment. The first version of this mutation inserted `// resampleTo16k`,
# which `code_tree` strips before counting — so the mutation changed the file, the sed-did-
# nothing guard was satisfied, and the invariant "still passed" for the one reason that
# proves nothing about it.
mutate_invariant "reach for the batch resampler in the capture CLI" inv_no_reuse_of_batch_resampler "$RESAMP" \
    's|^    public static let targetRate: Double = 16_000$|    public static let targetRate: Double = 16_000\n    static let borrowed = Audio.resampleTo16k|'

mutate_invariant "signal endOfStream per chunk" inv_incremental_feed_not_endofstream "$RESAMP" \
    's/outStatus.pointee = .noDataNow; return nil/outStatus.pointee = .endOfStream; return nil/'

# The untouched-target invariant is the one that must not be believed on a baseline pass:
# every other mutation here edits LiveAudio, so this one would read green all run whatever
# it was measuring. Probed with a file the harness creates and removes itself.
: > "$CAPTURE_PROBE"
if inv_capture_cli_untouched; then
    bad "touch a file in the capture CLI -> inv_capture_cli_untouched still passed"
else
    ok "touch a file in the capture CLI -> inv_capture_cli_untouched flipped"
fi
rm -f "$CAPTURE_PROBE"

# ===================================================================== B. suite baseline
echo
echo "== B. live-audio-check (baseline)"
# The baseline gets its own scratch path for the same reason every mutation
# does: this script must not write into the caller's `.build`. It used to run
# here with no --scratch-path, so a single harness run left about 100 MB of
# build output behind and the README's claim that it leaves your .build alone
# was false on the first line that builds anything.
base_scratch="$(mktemp -d)"
if swift run --scratch-path "$base_scratch" live-audio-check >/dev/null 2>&1; then ok "live-audio-check passes clean"
else bad "live-audio-check does NOT pass clean"; fi
rm -rf "$base_scratch"

echo
echo "== B. live-audio-check under mutation — each must break its NAMED limb"
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
    out="$(swift run --scratch-path "$scratch" live-audio-check 2>&1)"; rc=$?
    rm -rf "$scratch"
    cp "$before" "$file"; rm -f "$before"
    if [ $rc -eq 0 ]; then
        bad "$label — the suite still EXITED 0 under mutation"
        return
    fi
    if [ "$expect" = "<crash>" ]; then
        # A trap is a legitimate way for a mutation to bite, but it must be distinguished
        # from a compile error, which would "fail" for every mutation equally.
        if contains_re 'Fatal error|Illegal instruction|Trace/BPT' "$out"; then
            ok "$label -> trapped at runtime"
        else
            bad "$label — expected a runtime trap; got: $(printf '%s' "$out" | tail -3 | tr '\n' ';')"
        fi
        return
    fi
    # THE NAMED LIMB IS CHECKED FIRST, and that ordering is load-bearing. A Swift
    # diagnostic quotes the offending source line back, and this library calls
    # `conv.convert(to:error:)` — so the substring `error: ` appears in the output of a
    # perfectly clean build that merely emitted a warning. Testing for a build failure
    # BEFORE testing for the bite scored all 77 of these as "did not build" while they
    # were in fact biting their named limb. Matching the bite first means a real red can
    # never be reclassified as a build error; the branch below only has to explain a run
    # that produced no bite at all.
    if contains "FAIL  $expect" "$out"; then
        ok "$label -> \"$expect\" bit"
        return
    fi
    # A build error or a trap fails for every mutation equally and says nothing about the
    # limb, so it is named as such rather than scored as a red. Anchored on `: error: `,
    # the `file:line:col: error:` diagnostic form — a bare `error: ` also matches an
    # argument label in quoted source.
    if contains_re ': error: |Fatal error|Illegal instruction|Trace/BPT' "$out"; then
        bad "$label — the mutation did not RUN clean (build error or trap); it tested nothing"
        return
    fi
    bad "$label — expected \"$expect\" to fail; suite failed on: $(first_lines '  FAIL  ' "$out")"
}

# --- limb 1. The two ways to lose converter state, which are the two ways the one-shot
# --- function is wrong: reset it per chunk, or rebuild it per chunk.

# Aimed at the TAIL limb, not the boundary one, because that is what it actually does:
# `.endOfStream` finishes the converter, so the stream does not merely develop seams, it
# STOPS — the last 10 s comes back empty. Naming the boundary limb here would have been a
# harness asserting the wrong consequence and passing on a coincidence.
mutate_swift "signal endOfStream per chunk (finish the converter)" \
    "the last 10 s of the stream is still at 16 kHz" "$RESAMP" \
    's/outStatus.pointee = .noDataNow; return nil/outStatus.pointee = .endOfStream; return nil/'

mutate_swift "rebuild the converter on every push" \
    "no discontinuity at any of the 239 chunk boundaries" "$RESAMP" \
    's/^        if converter == nil {$/        if true {/'

# The rate half of limb 1, mutated on its own: a converter fed a rate it was not built for
# emits at the wrong ratio, which the totals catch even when the seams look clean.
mutate_swift "convert at the wrong output rate" \
    "total output is within 1 chunk of the exact 3:1 ratio over 60 s" "$RESAMP" \
    's/sampleRate: StreamingResampler.targetRate,$/sampleRate: 8_000,/'

mutate_swift "refuse the mono format the tap actually pushes" \
    "60 s of chunks convert without an error" "$RESAMP" \
    's/guard format.channels == 1,$/guard format.channels == 3,/'

# The INSTRUMENT, not the subject. If maxStep cannot resolve a filter transient then the
# boundary limb above is measuring nothing, and it would sail through every one of these
# mutations looking green.
mutate_swift "blind the boundary instrument" \
    "the boundary instrument can see a seam (one-shot-per-chunk exceeds the ceiling)" "$CHECK" \
    's|^    for i in 1..<xs.count { m = max(m, abs(xs\[i\] - xs\[i - 1\])) }$|    for i in 1..<xs.count { _ = i }|'

# --- limb 2. Drop-newest, blocking append, and a counter that does not count.

mutate_swift "evict the NEWEST frame instead of the oldest" \
    "the survivors are the NEWEST 8, not the oldest 8" "$RING" \
    's|^        if count == capacity {$|        if count == capacity { return false }\n        if false {|'

mutate_swift "make append wait for the writer" \
    "100,000 appends against a full, never-drained ring complete without waiting" "$RING" \
    's|^        var evicted = false$|        var evicted = false\n        if count == capacity { Thread.sleep(forTimeInterval: 0.001) }|'

mutate_swift "stop counting evictions" \
    "20 frames into a ring of 8 evicts exactly 12" "$RING" \
    's/^            _droppedFrames += 1$//'

mutate_swift "renumber frames on the way out" \
    "seq is carried, never reassigned" "$RING" \
    's|^        for i in 0..<count { out.append(storage\[(head + i) % capacity\]) }$|        for i in 0..<count { let f = storage[(head + i) % capacity]; out.append(PCMFrame(seq: UInt64(i), hostTimeNs: f.hostTimeNs, pcm: f.pcm)) }|'

mutate_swift "evict one frame early" \
    "a ring filled exactly to capacity drops nothing" "$RING" \
    's/^        if count == capacity {$/        if count >= capacity - 1 {/'

mutate_swift "always claim headroom" \
    "append's return value reports every eviction" "$RING" \
    's/^        return !evicted$/        return true/'

mutate_swift "never claim headroom" \
    "every append below capacity reports headroom" "$RING" \
    's/^        return !evicted$/        return false/'

# The seq of the frame going IN, not the one being thrown out. Off by exactly one frame,
# and the consumer's staleness window then covers the wrong span of audio.
mutate_swift "record the arriving seq as the dropped one" \
    "the last dropped seq is 12, so the consumer sees the 12->13 hole" "$RING" \
    's/_lastDroppedSeq = storage\[head\].seq/_lastDroppedSeq = frame.seq/'

mutate_swift "let drain copy instead of take" \
    "drain empties the ring" "$RING" \
    's/^        head = 0$//;s/^        count = 0$//;s/^        storage.removeAll(keepingCapacity: true)$//'

# Caps the counter rather than removing it, so the 12-eviction limb still passes and only
# the 100,000-eviction one goes red. A mutation that breaks everything proves less.
mutate_swift "cap the drop counter" \
    "the drop counter survives 100,000 evictions" "$RING" \
    's/^            _droppedFrames += 1$/            if _droppedFrames < 1000 { _droppedFrames += 1 }/'

# --- limb 3. The clamp, both ways it can be removed.
#
# Two mutations, because in Swift these are DIFFERENT failures and only one of them is the
# one the spec describes. `Int16(55703.0)` traps; it does not wrap. The silent full-scale
# noise the wire format warns about needs a truncating conversion, which is exactly what a developer
# reaches for to "fix" the crash. Both must bite, and they bite differently.
# TWO mutations for one clamp, because in Swift these are DIFFERENT failures and only one
# is the one the wire format describes. `Int16(55703.0)` TRAPS; it does not wrap. The silent full-scale
# noise the spec warns about needs a truncating conversion — which is exactly what a
# developer reaches for to "fix" the crash. Both must bite, and they bite differently.
mutate_swift "remove the clamp from the PCM16 conversion" \
    "<crash>" "$MIXER" \
    's/out.append(Int16((clamp(f) \* 32767).rounded()))/out.append(Int16((f * 32767).rounded()))/'

mutate_swift "silence the crash with a truncating conversion (the wrap)" \
    "no sample flips sign (the wrap signature)" "$MIXER" \
    's/out.append(Int16((clamp(f) \* 32767).rounded()))/out.append(Int16(truncatingIfNeeded: Int((f * 32767).rounded())))/'

mutate_swift "clamp only the positive rail" \
    "the negative rail clips symmetrically" "$MIXER" \
    's/static func clamp(_ f: Float) -> Float { max(-1, min(1, f)) }/static func clamp(_ f: Float) -> Float { min(1, f) }/'

mutate_swift "truncate the mix to the shorter track" \
    "unequal lengths keep every sample" "$MIXER" \
    's/^        let n = max(a.count, b.count)$/        let n = min(a.count, b.count)/'

mutate_swift "remove the clamp from the sum" \
    "a 0.9 + 0.8 sum is clipped to the rail, not left at 1.7" "$MIXER" \
    's/out\[i\] = clamp(l + r)/out[i] = l + r/'

mutate_swift "clip at the wrong threshold" \
    "a quiet mix sums linearly and is not clipped" "$MIXER" \
    's/static func clamp(_ f: Float) -> Float { max(-1, min(1, f)) }/static func clamp(_ f: Float) -> Float { max(-0.25, min(0.25, f)) }/'

# Keeps the LENGTH right and zeroes the tail — the version that passes a count check while
# silently deleting whichever source ran longer this chunk.
mutate_swift "zero-fill the ragged tail" \
    "the overlap sums and the tail passes through" "$MIXER" \
    's/            let r = i < b.count ? b\[i\] : 0/            let r = i < b.count \&\& i < a.count ? b[i] : 0/'

mutate_swift "let an absent source zero the present one" \
    "an empty track leaves the other one intact" "$MIXER" \
    's/        if a.isEmpty { return b.map(clamp) }/        if a.isEmpty { return [] }/'

mutate_swift "emit the wire bytes big-endian" \
    "PCM16 goes out little-endian, 2 bytes per sample" "$MIXER" \
    's/withUnsafeBytes(of: s.littleEndian)/withUnsafeBytes(of: s.bigEndian)/'

# Scale to the wrong full-scale value. The clamp is still there and still symmetric, so
# both rail limbs pass; only the limb that names the Int16 rails goes red.
mutate_swift "encode against the wrong full-scale value" \
    "toPCM16 clamps out-of-range input to the Int16 rails" "$MIXER" \
    's/out.append(Int16((clamp(f) \* 32767).rounded()))/out.append(Int16((clamp(f) * 16000).rounded()))/'

# Drop the system track from the composed path. The two halves stay individually correct —
# `sum` still clips, `toPCM16` still clamps — and the remote voice is simply gone. Only the
# end-to-end limb can see it, which is why the end-to-end limb exists.
mutate_swift "drop the system track from the composed mix" \
    "the full mix path clips a loud two-way passage to full scale" "$MIXER" \
    's/        toPCM16(sum(mic, system))/        toPCM16(sum(mic, []))/'

# --- limb 13. The transition, four ways to lose it.

# The one-line regression: reinitialise, but forget to tear the old converter down. The
# new-format chunk then goes through a converter built for the old rate and comes back as
# well-formed 16 kHz frames at the wrong pitch — "garbage that reads as speech".
#
# An earlier attempt at this mutation recursed into push() with the old format and hung the
# suite on a stack overflow. A mutation that makes the harness hang is not evidence about
# the limb; it is evidence about the mutation.
mutate_swift "keep the stale converter across the format change" \
    "the post-transition audio is at the right pitch, not resampled by the stale converter" "$RESAMP" \
    '/case .reinitialise:/,$ s/^                invalidateConverter()$/                _ = generation/'

mutate_swift "handle the transition silently" \
    "the transition is reported to the caller so the tap can re-emit its header" "$RESAMP" \
    's/^                transition = t$//'

mutate_swift "compare sample rate only" \
    "a channel-count change at the same rate is a transition, not a pass-through" "$RESAMP" \
    's/if let current = currentFormat, current != format {/if let current = currentFormat, current.sampleRate != format.sampleRate {/'

# "There is no converter to rebuild when we are already at 16 kHz, so skip the comparison."
# It reads as an optimisation and it is the one place a format change is easiest to miss:
# the take moves off the pass-through onto a real rate and nothing is ever reported.
mutate_swift "skip the format comparison while on the pass-through path" \
    "a transition OUT of the 16 kHz pass-through path is caught too" "$RESAMP" \
    's/if let current = currentFormat, current != format {/if let current = currentFormat, current != format, abs(current.sampleRate - StreamingResampler.targetRate) >= 1 {/'

mutate_swift "throw an unnamed error instead of the transition" \
    "hardFail throws .formatChanged naming both formats" "$RESAMP" \
    's/throw ResampleError.formatChanged(t)/throw ResampleError.convertFailed("format")/'

# Leave currentFormat set after the throw and the resampler is WEDGED: every retry compares
# against the format it already refused and throws again, so a transition that should cost
# one chunk costs the rest of the meeting.
mutate_swift "leave the old format set after a hardFail throw" \
    "after a hardFail throw the resampler is rebuilt, not resumed" "$RESAMP" \
    's/^                currentFormat = nil$//'

mutate_swift "stop bumping the generation counter" \
    "the header version counter bumps exactly once" "$RESAMP" \
    's/^                generation += 1$//'

mutate_swift "accept multichannel input as though it were mono" \
    "an unsupported channel count is refused rather than reinterpreted as mono" "$RESAMP" \
    's/guard format.channels == 1,$/guard format.channels >= 1,/'

# The second INSTRUMENT limb. A pitch detector pinned to the right answer makes the
# stale-converter limb above unfalsifiable while it reads green.
mutate_swift "blind the pitch instrument" \
    "the pitch instrument resolves the 36 Hz it has to resolve" "$CHECK" \
    's|^    return Double(crossings) \* rate / (2.0 \* Double(xs.count))$|    return 440|'

mutate_swift "let the hardFail path emit before it throws" \
    "hardFail emits NO samples across the transition" "$RESAMP" \
    's|^                throw ResampleError.formatChanged(t)$|                if let c = converter, let f = inFmt { _ = c; _ = f }\n                currentFormat = format\n                return ResampleOutput(samples: samples, transition: t)|'

# --- limb 15. The wire format. Every one of these produces a stream the Python reader
# --- decodes into something, which is exactly why the limbs assert byte literals: a wrong
# --- layout does not throw, it transcribes garbage.

mutate_swift "add a field to the header" \
    "the stream header is exactly 16 bytes" "$WIRE" \
    's|        d.append(protocolVersion)|        d.append(protocolVersion)\n        d.append(UInt8(0))|'

mutate_swift "write the sample rate big-endian" \
    "the header matches the §2.0 byte layout exactly" "$WIRE" \
    's|appendLE32(&d, sampleRate)|appendLE32(\&d, sampleRate.byteSwapped)|'

mutate_swift "write the generation big-endian" \
    "generation is written little-endian at offset 12" "$WIRE" \
    's|        appendLE32(&d, generation)|        d.append(contentsOf: withUnsafeBytes(of: generation.bigEndian) { Array($0) })|'

# The collapse the wire format argues against by name: one number for both, so a change to the byte
# layout reads to the consumer exactly like AirPods connecting.
mutate_swift "collapse the protocol version into the generation" \
    "bumping the generation does not touch the protocol version byte" "$WIRE" \
    's|        d.append(protocolVersion)|        d.append(UInt8(truncatingIfNeeded: generation))|'

mutate_swift "resize the frame prefix" \
    "a frame is an 8-byte prefix plus 2 bytes per sample" "$WIRE" \
    's|        appendLE32(&d, tsMs)|        appendLE32(\&d, tsMs)\n        d.append(UInt8(0))|'

mutate_swift "swap seq and ts in the prefix" \
    "the frame prefix is seq then ts, both little-endian" "$WIRE" \
    's|appendLE32(&d, seq)|appendLE32(\&d, TMPTS)|; s|appendLE32(&d, tsMs)|appendLE32(\&d, seq)|; s|appendLE32(&d, TMPTS)|appendLE32(\&d, tsMs)|'

mutate_swift "re-encode the payload in the frame encoder" \
    "the payload is the mixer's little-endian PCM16, unaltered" "$WIRE" \
    's|        d.append(Mixer.littleEndianBytes(pcm))|        d.append(Data(Mixer.littleEndianBytes(pcm).reversed()))|'

mutate_swift "stop skipping the seq that reads as a header" \
    "the seq generator skips the one value that would be read as a header" "$WIRE" \
    's|        return n == magicSeq ? n &+ 1 : n|        return n|'

mutate_swift "skip on every value, not just the magic one" \
    "an ordinary seq advances by one" "$WIRE" \
    's|        return n == magicSeq ? n &+ 1 : n|        return n \&+ 1|'

# The INSTRUMENT for the skip. If magicSeq stops naming the header magic then the skip above
# guards the wrong number, and the limb that checks the skip sails through measuring nothing.
mutate_swift "point magicSeq at a value that is not the magic" \
    "the skipped value really is the header magic read little-endian" "$WIRE" \
    's|    public static let magicSeq: UInt32 = 0x314B_434D|    public static let magicSeq: UInt32 = 0x0000_0001|'

# --- limb 16. The header-ordering rule. Every mutation here produces a stream that still
# --- decodes; what moves is WHICH audio the consumer believes the staleness signal covers.

mutate_swift "peek at the generation log instead of consuming it" \
    "announcing is one-shot — the same header is not re-emitted per frame" "$WIRE" \
    's|^        var latest: UInt32?$|        var latest: UInt32?\n        let saved = points|; s|^        return latest$|        points = saved\n        return latest|'

mutate_swift "announce the header one frame early" \
    "a generation whose frames have not been written yet is not announced early" "$WIRE" \
    's|first.seq <= seq {|first.seq <= seq \&+ 1 {|'

mutate_swift "announce the header one frame late" \
    "the opening header is announced before the first frame" "$WIRE" \
    's|first.seq <= seq {|first.seq < seq {|'

mutate_swift "announce every intermediate generation" \
    "when the ring drops across two bumps, only the surviving generation is announced" "$WIRE" \
    's|        while let first = points.first, first.seq <= seq {|        if let first = points.first, first.seq <= seq {|'

# Consumes all but the last point, so the "only the surviving generation" limb still passes
# and only the one that checks the log is EMPTY afterwards goes red. A mutation that breaks
# both proves less about either.
mutate_swift "leave the last point in the log" \
    "both points are consumed, so neither is announced again later" "$WIRE" \
    's|^            latest = first.generation$|            latest = first.generation; if points.count == 1 { break }|'

# --- limb 17. The frame assembler: the three failure modes named in its header comment —
# --- it stalls, it drifts, it lies — plus the counters that make the soak readable.

mutate_swift "build a frame from an empty contributing set" \
    "an assembler with no source yet emits nothing" "$ASM" \
    's|        guard !contributing.isEmpty else { return nil }||'

mutate_swift "drain the whole backlog into one frame" \
    "the frame is exactly one frame long, never the whole backlog" "$ASM" \
    's|            take\[i\] = Array(fifo\[i\].prefix(frameSamples))|            take[i] = fifo[i]|'

# THE DRIFT MUTATIONS. Emit whatever is there and let the short source be short: every jitter
# dip then ships a short frame, and over an hour the stream runs ahead of the meeting.
#
# EACH IS TWO SEDS, and the reason is worth keeping. Dropping the readiness guard ALONE does
# not reach the limb — it traps first, on `removeFirst(frameSamples)` against a shorter
# buffer. So the guard turns out to be load-bearing twice over, and the realistic regression
# is the one a developer arrives at after hitting that trap and "fixing" it with a min().
# Aiming these at the named limb without the second sed would have been the harness scoring a
# crash as though it were the limb.
mutate_swift "emit a short frame instead of holding the remainder" \
    "a partial remainder is held back, not padded out to a frame" "$ASM" \
    's|        guard contributing.allSatisfy({ fifo\[$0\].count >= frameSamples }) else { return nil }||; s|            fifo\[i\].removeFirst(frameSamples)|            fifo[i].removeFirst(min(frameSamples, fifo[i].count))|'

mutate_swift "emit as soon as ANY source is ready" \
    "a frame is withheld while one active source is short" "$ASM" \
    's|guard contributing.allSatisfy({ fifo\[$0\].count >= frameSamples })|guard contributing.contains(where: { fifo[$0].count >= frameSamples })|; s|            fifo\[i\].removeFirst(frameSamples)|            fifo[i].removeFirst(min(frameSamples, fifo[i].count))|'

# The trap in its own right: the readiness guard is what keeps `removeFirst` in range, and a
# future edit that keeps the guard's SPIRIT but drops its exact condition loses that too.
mutate_swift "drop the readiness guard and let removeFirst run past the end" \
    "<crash>" "$ASM" \
    's|        guard contributing.allSatisfy({ fifo\[$0\].count >= frameSamples }) else { return nil }||'

mutate_swift "never readmit the system source to the mix" \
    "both sources present, the frame goes out" "$ASM" \
    's|        let contributing = (0..<2).filter { active\[$0\] \&\& !starved\[$0\] }|        let contributing = (0..<2).filter { active[$0] \&\& !starved[$0] \&\& $0 == 0 }|'

mutate_swift "drop the system track from the composed mix" \
    "the frame is the SUM of the two sources, not one of them" "$ASM" \
    's|Mixer.mixToPCM16(mic: take\[0\], system: take\[1\])|Mixer.mixToPCM16(mic: take[0], system: [])|'

# THE STALL MUTATION and its opposite. One drops a merely-late source and loses real audio;
# the other waits forever on a dead one and takes the whole stream down silently.
mutate_swift "drop a late source without waiting out the timeout" \
    "a source that is merely late does not stall the stream forever, but it does stall it for now" "$ASM" \
    's|            if now > lastPushNs\[i\], now - lastPushNs\[i\] > starveTimeoutNs {|            if now > lastPushNs[i] {|'

mutate_swift "never starve a dead source" \
    "past the timeout the dead source is dropped and the stream CONTINUES" "$ASM" \
    's|            if now > lastPushNs\[i\], now - lastPushNs\[i\] > starveTimeoutNs {|            if false {|'

mutate_swift "pad the survivor's frames by a sample" \
    "the surviving source's frames are still whole" "$ASM" \
    's|            take\[i\] = Array(fifo\[i\].prefix(frameSamples))|            take[i] = Array(fifo[i].prefix(frameSamples)) + [Float](repeating: 0, count: 1)|'

# THE LYING MUTATIONS. Each leaves the audio spliced and `seq` contiguous, so nothing else in
# the system can tell the consumer the two spans do not join up.
mutate_swift "splice at a starve without announcing it" \
    "the starve rides out ON the frame that opens the new generation" "$ASM" \
    's|                latch(.sourceStarved)||'

mutate_swift "splice at a resume without announcing it" \
    "a resumed source is latched as a discontinuity too" "$ASM" \
    's|            latch(.sourceResumed)||'

# --- limb 17/18. The reason travelling WITH its frame — the step-2 review's structural fix.
# --- Every mutation here leaves the audio spliced, `seq` contiguous, and the header attached
# --- to the wrong frame, which is the one thing no other signal in the system can reveal.

mutate_swift "detach the reason from the frame it belongs to" \
    "the starve rides out ON the frame that opens the new generation" "$ASM" \
    's|^        let reason = pendingReason$|        let reason: DiscontinuityReason? = nil|'

mutate_swift "clear the latch on an emit that produces no frame" \
    "a reason latched while no frame can be built survives the nil emit" "$ASM" \
    's|        guard contributing.allSatisfy({ fifo\[$0\].count >= frameSamples }) else { return nil }|        guard contributing.allSatisfy({ fifo[$0].count >= frameSamples }) else { pendingReason = nil; return nil }|'

# AIMED AT THE LIMB IT ACTUALLY BREAKS FIRST, and the first attempt was aimed wrong. Named
# against "three events between two frames collapse to ONE announced reason", it went red on
# "the reason is consumed by the frame, not left to fire again" (and on the resumed-source limb)
# BEFORE reaching it — the same trap-first shape as the two readiness-guard mutations in step 2.
# Scoring that as the collapse limb biting would have been the harness crediting one limb's
# failure to another.
#
# NO MUTATION CAN BREAK THE COLLAPSE LIMB ALONE, and that is stated rather than papered over:
# both limbs assert the SAME property — the latch is consumed exactly once — so anything that
# breaks one breaks the other. The collapse limb is kept because it additionally exercises the
# multi-event path (two events counted, one reason announced); the counting half of that pairing
# has its own mutation, "count only the discontinuity that got latched".
mutate_swift "announce the same reason on every following frame" \
    "the reason is consumed by the frame, not left to fire again" "$ASM" \
    's|^        pendingReason = nil$|        _ = pendingReason|'

mutate_swift "handle a format transition without latching it" \
    "a format transition latches a discontinuity like the other three" "$ASM" \
    's|        latch(.sourceFormatChanged)||'

mutate_swift "stop counting format transitions per source" \
    "the format transition is counted per source" "$ASM" \
    's|        _formatTransitions\[source.rawValue\] += 1||'

# The direction limb. Holding the reason until the pre-transition backlog has drained looks
# like a precision improvement and is the dangerous direction: frames of spliced audio then
# ship as continuous, which is what the header exists to prevent.
mutate_swift "hold the format transition until the stale backlog drains" \
    "the announcement LEADS the splice rather than lagging it" "$ASM" \
    's|^        _formatTransitions\[source.rawValue\] += 1$|        _formatTransitions[source.rawValue] += 1\n        if fifo[source.rawValue].count >= frameSamples { return }|'

mutate_swift "splice at a resync without announcing it" \
    "a resync drop is latched as a discontinuity" "$ASM" \
    's|            latch(.backlogResync)||'

mutate_swift "stop counting starves" \
    "the starve is counted" "$ASM" \
    's|                _starveEvents\[i\] += 1||'

mutate_swift "keep a resumed source excluded for the rest of the take" \
    "resume clears the starved flag and readmits the source" "$ASM" \
    's|            starved\[i\] = false||'

mutate_swift "drop the NEWEST samples on a resync" \
    "it is the OLDEST samples that were dropped, not the newest" "$ASM" \
    's|            fifo\[i\].removeFirst(excess)|            fifo[i].removeLast(excess)|'

mutate_swift "count the whole buffer as dropped" \
    "the dropped count is the overflow, not the whole buffer" "$ASM" \
    's|            _backlogDropped\[i\] += excess|            _backlogDropped[i] += fifo[i].count|'

mutate_swift "stop enforcing the backlog bound" \
    "a backlog past its bound is clipped to the bound" "$ASM" \
    's|        if fifo\[i\].count > maxBacklogSamples {|        if false {|'

mutate_swift "count only the discontinuity that got latched" \
    "every discontinuity is counted" "$ASM" \
    's|        _discontinuities += 1|        if pendingReason == nil { _discontinuities += 1 }|'

# A sleep inside push is the audio-callback stall 0c measured, planted where the ring's own
# blocking mutation plants it.
mutate_swift "make push wait while it resyncs" \
    "50,000 pushes against a full, never-drained assembler complete without waiting" "$ASM" \
    's|            _backlogDropped\[i\] += excess|            Thread.sleep(forTimeInterval: 0.001)\n            _backlogDropped[i] += excess|'

echo
echo "======================================================="
[ "$PASS" = 1 ] && echo "  LIVE AUDIO FALSIFICATION: PASS" || echo "  LIVE AUDIO FALSIFICATION: FAIL"
echo "======================================================="
[ "$PASS" = 1 ]
