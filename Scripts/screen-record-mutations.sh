#!/usr/bin/env bash
# Falsification for ScreenPreset — the decisions behind a screen recording: which window
# counts as a call, which display it lives on, how a panel is scaled into the capture box,
# and the byte-stability of the sidecar.
#
# `swift run screen-record-check` passes. A suite that passes is evidence about nothing
# until a defect makes it fail, so each mutation must break the limb NAMED for it — not
# merely "the suite failed", which a compile error would also produce.
#
# SCOPE. This package ships the DECISIONS, not the app that acts on them and not the
# consent notice that a recording is announced with. The source invariants this harness
# once carried were claims about the recorder, the screen CLI, the SwiftUI views and the
# nightly purge script, all of which were carved out; they are gone rather than left
# pointing at files that do not exist. What remains is the suite half, which is where
# every decision this package actually owns is checked.
#
# Sources are mutated IN PLACE and restored by an EXIT trap, so an interrupt still
# puts the tree back. Nothing here writes outside the package.
set -uo pipefail

# The package root is the PARENT of Scripts/, and the paths below are relative to it.
HERE="$(cd "$(dirname "$0")" && pwd)"
# Shared classifiers (here-strings, never a pipe into grep -q) and their 2 MB control.
. "$HERE/lib-mutations.sh"
lib_self_test || exit 1
cd "$HERE/.."
PASS=1

PRESET="Sources/ScreenPreset/ScreenPreset.swift"

# ---------------------------------------------------------------- restore trap
# Only files that EXIST are backed up and restored. A trap that copies a file which is
# not there fails partway and leaves the tree mutated, which is the worst outcome this
# script can produce.
BACKUP="$(mktemp -d)"
for f in "$PRESET"; do
    [ -f "$f" ] || { echo "   FAIL missing source: $f"; exit 1; }
done
cp "$PRESET" "$BACKUP/ScreenPreset.swift"
restore() {
    [ -f "$BACKUP/ScreenPreset.swift" ] && cp "$BACKUP/ScreenPreset.swift" "$PRESET"
    rm -rf "$BACKUP"
}
trap restore EXIT INT TERM

ok()   { echo "   ok   $1"; }
bad()  { echo "   FAIL $1"; PASS=0; }

# ================================================================= B. swift suite
echo "== B. screen-record-check (baseline)"
# The baseline gets its own scratch path for the same reason every mutation
# does: this script must not write into the caller's `.build`. It used to run
# here with no --scratch-path, so a single harness run left about 100 MB of
# build output behind and the README's claim that it leaves your .build alone
# was false on the first line that builds anything.
base_scratch="$(mktemp -d)"
if swift run --scratch-path "$base_scratch" screen-record-check >/dev/null 2>&1; then ok "screen-record-check passes clean"
else bad "screen-record-check does NOT pass clean"; fi
rm -rf "$base_scratch"

echo
echo "== B. screen-record-check under mutation — each must break its NAMED limb"
mutate_swift() {
    local label="$1" expect="$2" file="$3" expr="$4"
    local before; before="$(mktemp)"; cp "$file" "$before"
    sed -i '' "$expr" "$file"
    if cmp -s "$before" "$file"; then
        bad "$label — the sed changed NOTHING, so this limb tested nothing"
        cp "$before" "$file"; rm -f "$before"; return
    fi
    # A FRESH scratch path per mutation. Restoring with `cp` and re-`sed`ing lands
    # both writes in the same second, so SPM's mtime check can decide nothing
    # changed and hand back the PREVIOUS build — a harness silently measuring the
    # last mutation instead of this one. An empty scratch dir has nothing stale in
    # it to reuse, which removes the failure mode rather than timing around it.
    local out rc scratch
    scratch="$(mktemp -d)"
    out="$(swift run --scratch-path "$scratch" screen-record-check 2>&1)"; rc=$?
    rm -rf "$scratch"
    cp "$before" "$file"; rm -f "$before"
    if [ $rc -eq 0 ]; then
        bad "$label — the suite still EXITED 0 under mutation"
        return
    fi
    # THE NAMED LIMB IS CHECKED FIRST, and that ordering is load-bearing. A Swift
    # diagnostic quotes the offending source line back, so a build that merely emitted a
    # warning about a call with an `error:` argument label puts the substring `error: `
    # in the output of a perfectly clean run. Testing for a build failure BEFORE testing
    # for the bite scored every mutation in the sibling live-audio harness as "did not
    # build" while each was in fact biting its named limb. Matching the bite first means
    # a real red can never be reclassified as a build error.
    #
    # screen-record-check prints "  FAIL <label>" — ONE space. grep -F, so the
    # parentheses in the limb names are literal.
    if contains "FAIL $expect" "$out"; then
        ok "$label -> \"$expect\" bit"
        return
    fi
    # A build error or a trap fails for every mutation equally and says nothing about the
    # limb, so it is named as such rather than scored as a red. Anchored on `: error: `,
    # the `file:line:col: error:` diagnostic form.
    if contains_re ': error: |Fatal error|Illegal instruction|Trace/BPT' "$out"; then
        bad "$label — the mutation did not RUN clean (build error or trap); it tested nothing"
        return
    fi
    bad "$label — expected \"$expect\" to fail; suite failed on: $(first_lines '  FAIL' "$out")"
}

# --- WHICH WINDOW IS A CALL. Both directions are wrong in ways nothing else can see: a
# --- false positive puts the pill and the recording on the wrong display for the whole
# --- call, a false negative means the call is never detected at all.

# The regression that reads as an obvious inclusion: Slack is a conferencing app, so its
# bundle id belongs in the set — except an ordinary Slack window is then a call, and the
# recording follows a chat window instead of the meeting.
mutate_swift "re-add Slack to the conference bundle set" \
    "an ordinary Slack window is NOT a call" "$PRESET" \
    's/"us.zoom.xos",/"us.zoom.xos", "com.tinyspeck.slackmacgap",/'

# Every Google Meet call went undetected because the only Meet rule was a URL that a
# window title never carries. Drop the prefix rule and the measured live title stops
# matching again.
mutate_swift "drop the Meet title-prefix rule" \
    "a live Google Meet call in Chrome is a call" "$PRESET" \
    's/        if config.titlePrefixes.contains(where: { t.hasPrefix(\$0.lowercased()) }) { return true }//'

# The over-match in the other direction, and the reason the rule is a PREFIX. A bare
# `meet` needle matches a Meeting Notes document, which would put the pill and the
# recording on the wrong display for the whole call.
mutate_swift "loosen the Meet rule to a bare contains" \
    "a Meeting Notes document is NOT a call" "$PRESET" \
    's/        if config.titlePrefixes.contains(where: { t.hasPrefix(\$0.lowercased()) }) { return true }/        if t.contains("meet") { return true }/'

# --- WHICH DISPLAY, AND HOW IT IS SCALED.

# Break the built-in fallback: with no call display resolved, the recording has to land
# somewhere defined, and the built-in panel is that somewhere.
mutate_swift "break the built-in fallback" \
    "builtin resolves to the built-in panel" "$PRESET" \
    's/if let b = displays.first(where: { \$0.isBuiltin })/if let b = displays.first(where: { !\$0.isBuiltin })/'

# Height cap instead of a box — the rotated portrait panel loses half its pixels, and a
# capture that silently halves its own resolution looks like a working recording.
mutate_swift "replace the box with a height cap" \
    "portrait 1080x1920 survives the box intact" "$PRESET" \
    's|let scale = min(1.0, Double(maxLong) / longEdge, Double(maxShort) / shortEdge)|let scale = min(1.0, Double(maxShort) / Double(pixelHeight))|'

# --- CASE, AND THE BOUNDARY. Both of these were live defects and both failed SILENTLY:
# --- a pattern that never matches and a window that is never a call report nothing at
# --- all, and the cost lands as the wrong screen recorded for an entire meeting.

# Lowercase only the title, which is what the matcher used to do. A consumer's JSON
# entry of "Zoom Meeting" then matches nothing, forever, with no error.
mutate_swift "lowercase the title but not the needle" \
    "a CAPITALISED needle from a user's JSON still matches" "$PRESET" \
    's/config.titleNeedles.contains { t.contains(\$0.lowercased()) }/config.titleNeedles.contains { t.contains(\$0) }/'

mutate_swift "lowercase the title but not the prefix" \
    "a CAPITALISED prefix from a user's JSON still matches" "$PRESET" \
    's/config.titlePrefixes.contains(where: { t.hasPrefix(\$0.lowercased()) })/config.titlePrefixes.contains(where: { t.hasPrefix(\$0) })/'

# Exclusive size comparison. A window at exactly the documented minimum is discarded,
# which contradicts the field's own doc comment.
mutate_swift "make the minimum size exclusive again" \
    "a window EXACTLY at the minimum size is a call" "$PRESET" \
    's/w.frame.width >= config.minWidth,/w.frame.width > config.minWidth,/'

# --- THE SIDECAR. The key order must be byte-stable, or a diff of two identical takes is
# --- noise and the sidecar stops being usable as a completeness record.
mutate_swift "drop sortedKeys from the sidecar encoder" \
    "sidecar keys are in ascending order (byte-stable across runs)" "$PRESET" \
    's/e.outputFormatting = \[.prettyPrinted, .sortedKeys\]/e.outputFormatting = [.prettyPrinted]/'

echo
echo "======================================================="
[ "$PASS" = 1 ] && echo "  SCREEN RECORDING FALSIFICATION: PASS" || echo "  SCREEN RECORDING FALSIFICATION: FAIL"
echo "======================================================="
[ "$PASS" = 1 ]
