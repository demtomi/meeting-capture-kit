#!/usr/bin/env bash
# Falsification for SpeakerNaming — transcript speaker relabeling.
#
# `swift run speaker-naming-check` passes. A suite that passes is evidence about nothing
# until a defect makes it fail (D-48, D-49), so every limb here is broken on purpose and
# the NAMED check must go red — not merely "the suite failed", which a compile error
# would also produce.
#
# THIS REWRITE IS WORTH THE HARNESS because every way of getting it wrong produces a
# transcript that still LOOKS like a transcript, lands in the repo, and is read months
# later as the record of what was said:
#   · a global string swap renames a name mentioned INSIDE an utterance, so the file now
#     says a participant said something they did not
#   · half the rewrite landing leaves the frontmatter naming people the body does not,
#     which is two different answers to "who was in this meeting"
#   · the host label is not a `Speaker N` and must never be renamed — it is the one
#     participant whose identity is known from the track, not from diarization
# None of the three throws, and none is visible in a diff of the code that caused it.
#
# TWO KINDS OF LIMB.
#
#   A. SOURCE INVARIANTS. Claims about the shape of the code that no compiler and no unit
#      test can check, because what is asserted is an ABSENCE. "Replacement is anchored,
#      never a global string swap" is not a value any function returns. Grep is a weak
#      instrument, so each is watched to flip under a mutation before it is believed.
#
#   B. SUITE MUTATIONS. Each breaks one limb of speaker-naming-check, by name.
#
# Sources are mutated IN PLACE and restored by an EXIT trap, so an interrupt still puts
# the tree back. String-in / string-out: nothing here touches a transcript on disk,
# needs a device, a display, a TCC grant, the network, or a credit.
set -uo pipefail

# The package root is the PARENT of Scripts/, and the paths below are relative to it.
HERE="$(cd "$(dirname "$0")" && pwd)"
# Shared classifiers (here-strings, never a pipe into grep -q) and their 2 MB control.
. "$HERE/lib-mutations.sh"
lib_self_test || exit 1
cd "$HERE/.."
PASS=1

NAMING="Sources/SpeakerNaming/SpeakerNaming.swift"
CHECK="Sources/speaker-naming-check/main.swift"

# ---------------------------------------------------------------- restore trap
BACKUP="$(mktemp -d)"
cp "$NAMING" "$BACKUP/SpeakerNaming.swift"
cp "$CHECK"  "$BACKUP/check-main.swift"
restore() {
    cp "$BACKUP/SpeakerNaming.swift" "$NAMING"
    cp "$BACKUP/check-main.swift"    "$CHECK"
    rm -rf "$BACKUP"
}
trap restore EXIT INT TERM

ok()  { echo "   ok   $1"; }
bad() { echo "   FAIL $1"; PASS=0; }

# CODE ONLY, comments stripped. This file's doc comment states the prohibitions in the
# words the invariants forbid — "anchored replacement, not a global string swap", "The
# host label (mic track, e.g. \"Host\")" — and a substring classifier over prose reads
# the prohibition as the violation. The screen-recording harness reported two invariants
# broken at baseline for exactly this reason, and both hits were its own doc comments.
code() { grep -v '^[[:space:]]*//' "$1"; }

# COUNT, never `grep -q`, and never a bare pipeline as the return value. `! producer |
# grep -q X` under `set -o pipefail` is INVERTED: grep -q exits on first match, the
# producer takes SIGPIPE, pipefail reports failure, and `!` turns that into success.
# Measured on the screen-recording harness: a file with 5 occurrences reported "absent".
occurrences() { code "$2" | grep -c "$1"; }
absent()  { [ "$(occurrences "$1" "$2")" -eq 0 ]; }

# ================================================================= A. source invariants

# "String-in / string-out so it is unit-testable without touching the filesystem; the app
# reads and writes the file around these calls." A file API reaching this target means the
# rename can no longer be replayed on a string, and a half-applied rename would then be
# written over the only copy of the transcript.
inv_naming_touches_no_filesystem() {
    local n=0 t
    for t in FileManager FileHandle "URL(fileURLWithPath" "write(to:" \
             "String(contentsOf" "Data(contentsOf" OutputStream; do
        n=$(( n + $(occurrences "$t" "$NAMING") ))
    done
    [ "$n" -eq 0 ]
}

# THE ANCHORS ARE THE WHOLE MECHANISM. Both patterns match a WHOLE LINE — `^` through
# `$` — which is what confines a rename to the two slots where a speaker token
# legitimately appears. Drop either anchor and the same regex starts matching mid-line,
# which is a global string swap wearing a regex's clothes.
inv_patterns_are_whole_line_anchored() {
    [ "$(occurrences '#"\^(' "$NAMING")" -eq 2 ] \
        && [ "$(occurrences ')\$"#' "$NAMING")" -eq 2 ]
}

# The absence the header names by name: "anchored replacement, not a global string swap".
# `replacingCharacters(in:with:)` takes a RANGE the matcher produced;
# `replacingOccurrences(of:with:)` takes a token and rewrites the line wherever it appears,
# utterance text included.
inv_no_global_string_swap() {
    absent "replacingOccurrences" "$NAMING"
}

# "The host label (mic track, e.g. \"Host\") is never a `Speaker N`, so it is never
# renamed." The rule holds because the host's participant line and body slot are shaped
# differently from a diarized speaker's and neither pattern admits them — so the host is
# never a token the code can see, and that is an absence, not a branch.
inv_host_label_is_not_matchable() {
    absent "host" "$NAMING" && absent "Host" "$NAMING"
}

# Both slots or neither. The frontmatter list and the body utterances are two renders of
# the same fact, and a rewrite that lands on one leaves the file saying two different
# things about who was in the meeting.
inv_both_slots_are_matched() {
    [ "$(occurrences 'let matchers = \[participant, utterance\]' "$NAMING")" -eq 1 ]
}

echo "== A. source invariants (baseline)"
for inv in inv_naming_touches_no_filesystem inv_patterns_are_whole_line_anchored \
           inv_no_global_string_swap inv_host_label_is_not_matchable \
           inv_both_slots_are_matched; do
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
mutate_invariant "read the transcript from disk inside the library" \
    inv_naming_touches_no_filesystem "$NAMING" \
    's|^    public static func detect(in text: String) -> \[String\] {$|    public static func detect(in text: String) -> [String] {\n        _ = FileManager.default|'

mutate_invariant "unanchor the utterance pattern at the line start" \
    inv_patterns_are_whole_line_anchored "$NAMING" \
    's|pattern: #"\^(\\d+\\s+|pattern: #"(\\d+\\s+|'

mutate_invariant "swap the anchored replacement for a token swap" \
    inv_no_global_string_swap "$NAMING" \
    's|^            return line.replacingCharacters(in: range, with: name)$|            return line.replacingOccurrences(of: tok, with: name)|'

mutate_invariant "admit the host participant line to the pattern" \
    inv_host_label_is_not_matchable "$NAMING" \
    's|(?:remote\|in-person)|(?:remote\|in-person\|host, mic)|'

mutate_invariant "drop the frontmatter matcher" inv_both_slots_are_matched "$NAMING" \
    's/let matchers = \[participant, utterance\]/let matchers = [utterance]/'

# ===================================================================== B. suite baseline
echo
echo "== B. speaker-naming-check (baseline)"
# The baseline gets its own scratch path for the same reason every mutation
# does: this script must not write into the caller's `.build`. It used to run
# here with no --scratch-path, so a single harness run left about 100 MB of
# build output behind and the README's claim that it leaves your .build alone
# was false on the first line that builds anything.
base_scratch="$(mktemp -d)"
if swift run --scratch-path "$base_scratch" speaker-naming-check >/dev/null 2>&1; then ok "speaker-naming-check passes clean"
else bad "speaker-naming-check does NOT pass clean"; fi
rm -rf "$base_scratch"

echo
echo "== B. speaker-naming-check under mutation — each must break its NAMED limb"
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
    out="$(swift run --scratch-path "$scratch" speaker-naming-check 2>&1)"; rc=$?
    rm -rf "$scratch"
    cp "$before" "$file"; rm -f "$before"
    if [ $rc -eq 0 ]; then
        bad "$label — the suite still EXITED 0 under mutation"
        return
    fi
    # The NAMED FAIL first, then an anchored build error or a trap (lib-mutations.sh). A regex
    # mutation can TRAP at load (`try!` on an invalid pattern), which is a crash, not a check
    # result. speaker-naming-check prints "  FAIL <label>", ONE space; a fixed string.
    case "$(classify_output "FAIL $expect" "$out")" in
        bit)    ok "$label -> \"$expect\" bit" ;;
        broken) bad "$label — the mutation did not RUN clean (build error or trap); it tested nothing" ;;
        *)      bad "$label — expected \"$expect\" to fail; suite failed on: $(first_lines '  FAIL ' "$out")" ;;
    esac
}

# --- THE DUAL REWRITE. Frontmatter and body are two renders of one fact, and each half
# --- alone leaves a transcript that contradicts itself. Both halves get a mutation
# --- because dropping either compiles, runs, and rewrites something.

mutate_swift "drop the frontmatter matcher" \
    "renames frontmatter participant lines" "$NAMING" \
    's/let matchers = \[participant, utterance\]/let matchers = [utterance]/'

mutate_swift "drop the body-utterance matcher" \
    "renames body speaker slots" "$NAMING" \
    's/let matchers = \[participant, utterance\]/let matchers = [participant]/'

# The rewrite that lands in the right LINE and the wrong COLUMN. Replacing from the token
# to the end of the line drops the index and the timestamp with it, so the body loses its
# ordering and the frontmatter loses its list marker — a transcript that no longer parses
# as one. Named at the body limb; the frontmatter limb falls with it, because the same
# line does both slots.
mutate_swift "replace from the slot to the end of the line" \
    "renames body speaker slots" "$NAMING" \
    's|^            return line.replacingCharacters(in: range, with: name)$|            return name + line[range.upperBound...]|'

# --- THE GLOBAL SWAP. The founding defect this type exists to avoid: the check's sample
# --- deliberately carries a body line where the HOST says "I think Speaker 1 was right",
# --- and a token swap rewrites that sentence into a claim nobody made.

mutate_swift "swap the token everywhere after the anchored rewrite" \
    "Speaker mention inside utterance text is untouched" "$NAMING" \
    's|^        return rewritten.joined(separator: .*$|        return clean.reduce(rewritten.joined(separator: "\\n")) { $0.replacingOccurrences(of: $1.key, with: $1.value) }|'

# --- THE HOST LABEL. Widen the body slot from `Speaker N` to any label and the host
# --- becomes renameable — the one participant whose identity comes from the mic track
# --- rather than from diarization, silently reassigned.
#
# NO MUTATION CAN BREAK THE HOST LIMB ALONE, and that is stated rather than papered over.
# The host is renameable exactly when the host is a slot the matchers can see, and a
# token in a slot is by definition what `detect` returns — so limbs 1 and 10 ("detect
# finds remote speakers in order", "in-person transcript has no renameable speakers")
# fall with it necessarily. The host limb is kept because it additionally proves the
# rename ACTS on that token, not merely that detect reports it.
mutate_swift "widen the body slot from Speaker N to any label" \
    "host label (Host) is never renamed" "$NAMING" \
    's|(Speaker \\d+)(:\\s|([^:]+)(:\\s|'

# --- THE SANITIZER. A rejected name means "leave the token alone", never "replace it
# --- with the rejected value". Each rejection reason gets its own mutation: a mutation
# --- that drops the whole guard breaks both limbs and proves less about either.

mutate_swift "accept an empty name" \
    "blank name leaves that speaker unchanged" "$NAMING" \
    's/guard !t.isEmpty, !t.contains(":")/guard !t.contains(":")/'

# The same limb reached from the other side: the guard is intact, the input never gets
# trimmed, so a whitespace-only name is "non-empty" and is written into the slot. This is
# the realistic version — a text field that was not trimmed, not a deleted check.
mutate_swift "stop trimming before the emptiness test" \
    "blank name leaves that speaker unchanged" "$NAMING" \
    's/let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)/let t = raw/'

mutate_swift "accept a name containing a colon" \
    "name containing a colon is rejected" "$NAMING" \
    's/guard !t.isEmpty, !t.contains(":"),/guard !t.isEmpty,/'

# --- MIC-MULTI. An in-person meeting whose single mic track was diarized into two
# --- speakers: same slots, different parenthetical. It was added to the pattern after
# --- the fact, which is exactly the kind of alternation a later edit tidies away.

mutate_swift "drop in-person from the participant alternation" \
    "mic-multi renames in-person frontmatter + body" "$NAMING" \
    's/(?:remote|in-person)/(?:remote)/'

echo
echo "======================================================="
[ "$PASS" = 1 ] && echo "  SPEAKER NAMING FALSIFICATION: PASS" || echo "  SPEAKER NAMING FALSIFICATION: FAIL"
echo "======================================================="
[ "$PASS" = 1 ]
