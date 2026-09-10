#!/usr/bin/env bash
# Falsification for MeetingPresence — call detection over window geometry, and the
# panel-anchor drag latch.
#
# `swift run meeting-presence-check` passes. A suite that passes is evidence about
# nothing until a defect makes it fail, so every limb is broken on purpose and the
# NAMED limb must go red — not merely "the suite failed", which a compile error would
# also produce.
#
# These two rules are worth the harness because both fail SILENTLY and neither has a
# user-visible symptom until a real meeting is underway:
#   · prompt-once — getting it wrong means a modal every 3 seconds for an hour
#   · the drag latch — getting it wrong means the pill snaps back to the screen edge
#     at the exact moment the no-remote-audio alarm resizes it
#
# SCOPE. This package ships the RULES, not the app that draws them. The invariants that
# once asserted the shape of the overlay controller and the window watcher were carved
# out with those files and are gone; what remains is the one invariant that keeps the
# library replayable, plus every suite mutation, which is where the two rules above
# actually live.
#
# Sources are mutated IN PLACE and restored by an EXIT trap, so an interrupt still puts
# the tree back. No window server, no displays, no TCC, no network.
set -uo pipefail

# The package root is the PARENT of Scripts/, and the paths below are relative to it.
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE/.."
PASS=1

PRESENCE="Sources/MeetingPresence/MeetingPresence.swift"
CHECK="Sources/meeting-presence-check/main.swift"

# ---------------------------------------------------------------- restore trap
# Only files that EXIST are backed up and restored. A trap that copies a file which is
# not there fails partway and leaves the tree mutated, which is the worst outcome this
# script can produce.
BACKUP="$(mktemp -d)"
for f in "$PRESENCE" "$CHECK"; do
    [ -f "$f" ] || { echo "   FAIL missing source: $f"; exit 1; }
done
cp "$PRESENCE" "$BACKUP/presence.swift"
cp "$CHECK"    "$BACKUP/check.swift"
restore() {
    [ -f "$BACKUP/presence.swift" ] && cp "$BACKUP/presence.swift" "$PRESENCE"
    [ -f "$BACKUP/check.swift" ]    && cp "$BACKUP/check.swift"    "$CHECK"
    rm -rf "$BACKUP"
}
trap restore EXIT INT TERM

ok()  { echo "   ok   $1"; }
bad() { echo "   FAIL $1"; PASS=0; }

# CODE ONLY, comments stripped: this file's comments discuss the very tokens the
# invariants forbid, and a substring classifier over prose reads the prohibition as the
# violation.
code() { grep -v '^[[:space:]]*//' "$1"; }

# COUNT, never `grep -q`, and never a bare pipeline as the return value. `! producer |
# grep -q X` under `set -o pipefail` is INVERTED: grep -q exits on first match, the
# producer takes SIGPIPE, pipefail reports failure, and `!` turns that into success.
occurrences() { code "$2" | grep -c "$1"; }
absent()  { [ "$(occurrences "$1" "$2")" -eq 0 ]; }

# ================================================================= A. source invariants

# The library half must stay replayable: no AppKit, no window server, no TCC. The moment
# it imports AppKit, the two rules stop being checkable without a real desktop and every
# limb below quietly becomes something only a workstation can run.
inv_presence_is_pure() {
    absent "import AppKit" "$PRESENCE" \
        && absent "CGWindowListCopyWindowInfo" "$PRESENCE" \
        && absent "NSScreen" "$PRESENCE"
}

echo "== A. source invariants (baseline)"
for inv in inv_presence_is_pure; do
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
mutate_invariant "pull AppKit into the pure library" inv_presence_is_pure "$PRESENCE" \
    's/^import Foundation$/import Foundation\nimport AppKit/'

# ===================================================================== B. suite baseline
echo
echo "== B. meeting-presence-check (baseline)"
if swift run meeting-presence-check >/dev/null 2>&1; then ok "meeting-presence-check passes clean"
else bad "meeting-presence-check does NOT pass clean"; fi

echo
echo "== B. under mutation — each must break its NAMED limb"
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
    out="$(swift run --scratch-path "$scratch" meeting-presence-check 2>&1)"; rc=$?
    rm -rf "$scratch"
    cp "$before" "$file"; rm -f "$before"
    if [ $rc -eq 0 ]; then bad "$label — the suite still EXITED 0 under mutation"; return; fi
    # THE NAMED LIMB IS CHECKED FIRST, and that ordering is load-bearing. A Swift
    # diagnostic quotes the offending source line back, so a build that merely emitted a
    # warning about a call with an `error:` argument label puts the substring `error: `
    # in the output of a perfectly clean run. Testing for a build failure BEFORE testing
    # for the bite scored every mutation in the sibling live-audio harness as "did not
    # build" while each was in fact biting its named limb. Matching the bite first means
    # a real red can never be reclassified as a build error.
    if printf '%s' "$out" | grep -qF "FAIL  $expect"; then
        ok "$label -> \"$expect\" bit"
        return
    fi
    # A build error or a trap fails for every mutation equally and says nothing about the
    # limb, so it is named as such rather than scored as a red. Anchored on `: error: `,
    # the `file:line:col: error:` diagnostic form.
    if printf '%s' "$out" | grep -qE ': error: |Fatal error|Illegal instruction|Trace/BPT'; then
        bad "$label — the mutation did not RUN clean (build error or trap); it tested nothing"
        return
    fi
    bad "$label — expected \"$expect\"; suite failed on: $(printf '%s' "$out" | grep '  FAIL  ' | head -3 | tr '\n' ';')"
}

# --- prompt-once. The headline failure: a modal every 3 s for an hour.
mutate_swift "forget prompted ids every poll" \
    "a window left open for an hour never prompts again" "$PRESENCE" \
    's/^        prompted.formIntersection(now)$/        prompted.removeAll()/'

# The opposite failure, and the quieter one: ids are never forgotten, so a REUSED window
# id is swallowed and the next real meeting silently never prompts.
mutate_swift "never forget a closed window" \
    "after the window closes, the same id prompts again" "$PRESENCE" \
    's/^        prompted.formIntersection(now)$//'

mutate_swift "mark only the returned window as prompted" \
    "the window that lost the size comparison does not prompt on the next poll" "$PRESENCE" \
    's/^        for w in fresh { prompted.insert(w.windowID) }$/        prompted.insert(pick.windowID)/'

mutate_swift "pick the first fresh window instead of the largest" \
    "when two windows appear together the LARGEST is the meeting" "$PRESENCE" \
    's/            .sorted { \$0.info.frame.area > \$1.info.frame.area }/            .sorted { $0.windowID < $1.windowID }/'

mutate_swift "key presence on the app rather than the window" \
    "a NEW window alongside the old one prompts" "$PRESENCE" \
    's/            .filter { !prompted.contains(\$0.windowID) }/            .filter { _ in !prompted.isEmpty ? false : true }/'

mutate_swift "gate placement on the prompt" \
    "currentCall still answers after the call has been prompted" "$PRESENCE" \
    's|^        windows.max(by: { \$0.info.frame.area < \$1.info.frame.area })$|        windows.filter { !prompted.contains($0.windowID) }.max(by: { $0.info.frame.area < $1.info.frame.area })|'

mutate_swift "placement picks by order instead of area" \
    "currentCall picks the largest window on screen" "$PRESENCE" \
    's|^        windows.max(by: { \$0.info.frame.area < \$1.info.frame.area })$|        windows.first|'

# --- the drag latch.
# Range-addressed to `noteProgrammaticMove` alone. A bare `s/lastProgrammatic = origin/`
# also hits the trailing assignment in noteObservedOrigin, and that combination makes
# NOTHING a drag — which breaks the opposite limbs and names the wrong consequence.
#
# Stop recording what we set and our own re-anchoring is compared against a stale
# origin, so the pill latches itself the first time it moves and never follows the
# meeting again.
mutate_swift "stop recording our own placement" \
    "our own placement is not a drag" "$PRESENCE" \
    '/func noteProgrammaticMove/,/^    }$/ s/^        lastProgrammatic = origin$//'

mutate_swift "recompute userMoved per move instead of latching" \
    "a subsequent programmatic move does not un-latch it" "$PRESENCE" \
    's/^        if moved { userMoved = true }$/        userMoved = moved/'

mutate_swift "drop the tolerance" \
    "sub-pixel jitter is not a drag" "$PRESENCE" \
    's/    public static let tolerance: Double = 2.0/    public static let tolerance: Double = 0.0/'

mutate_swift "compare with >= instead of >" \
    "a move of exactly the tolerance is not a drag" "$PRESENCE" \
    's/        let moved = abs(origin.x - last.x) > Self.tolerance/        let moved = abs(origin.x - last.x) >= Self.tolerance/'

mutate_swift "latch on the creation-time didMove" \
    "a move before the first placement is not a drag" "$PRESENCE" \
    '/A move before we ever placed it/,/^        }$/ s/^            return false$/            userMoved = true; return true/'

mutate_swift "start the latch engaged" \
    "a fresh anchor may be positioned" "$PRESENCE" \
    's/    private(set) public var userMoved = false/    private(set) public var userMoved = true/'

mutate_swift "share one latch between panels" \
    "dragging one panel leaves the other free" "$PRESENCE" \
    's/    public var mayReposition: Bool { !userMoved }/    public var mayReposition: Bool { !userMoved \&\& !PanelAnchor.anyMoved }/;s/^public struct PanelAnchor: Sendable {$/public struct PanelAnchor: Sendable {\n    nonisolated(unsafe) static var anyMoved = false/;s/^        if moved { userMoved = true }$/        if moved { userMoved = true; PanelAnchor.anyMoved = true }/'

echo
echo "======================================================="
[ "$PASS" = 1 ] && echo "  MEETING PRESENCE FALSIFICATION: PASS" || echo "  MEETING PRESENCE FALSIFICATION: FAIL"
echo "======================================================="
[ "$PASS" = 1 ]
