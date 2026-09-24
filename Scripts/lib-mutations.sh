# Shared by every Scripts/*-mutations.sh. Source it, do not run it.
#
# THE CLASSIFIER READS OUTPUT THROUGH A HERE-STRING, NEVER A PIPE. Under `set -o pipefail`,
# `printf '%s' "$out" | grep -q X` returns 141 on a REAL match once $out outgrows the pipe
# buffer: grep -q exits at the first match, the writer takes SIGPIPE, and pipefail reports
# the pipeline as failed. A harness using it scores a biting mutant as "did not go red".
# Measured on a 2 MB output: pipe form rc 141, here-string rc 0.

# Does text $2 contain the fixed string $1?
contains()    { grep -qF -- "$1" <<< "$2"; }
# Does text $2 match the extended regex $1?
contains_re() { grep -qE -- "$1" <<< "$2"; }
# The first three lines of $2 matching $1, joined with ';'. Display only.
first_lines() { grep -- "$1" <<< "$2" | head -3 | tr '\n' ';'; }

# How a mutant's run reads. $1 is the exact named-FAIL line to look for (the caller's own
# prefix, since checks differ in spacing), $2 the run's output. Prints one word:
#   bit     the named case went red
#   broken  a build error or a trap, so the mutant tested nothing
#   other   it went red somewhere else, or not at all
# The NAMED FAIL is tested FIRST, and the build pattern is anchored on ': error: '. A warning
# can quote source that contains 'error: ', and testing a loose build pattern first scores
# a real bite as "did not build".
classify_output() {
    if contains "$1" "$2"; then echo bit; return; fi
    if contains_re ': error: |Fatal error|Illegal instruction|Trace/BPT' "$2"; then echo broken; return; fi
    echo other
}

# The control every harness runs first: a named FAIL at the top of a 2 MB output must be
# found by the fixed-string and the regex classifier alike.
lib_self_test() {
    local big
    big="$(printf '  FAIL  planted named case\n'; head -c 2000000 /dev/zero | tr '\0' 'x')"
    if ! { contains "FAIL  planted named case" "$big" && contains_re 'FAIL +planted' "$big"; }; then
        echo "   FAIL control: the classifier MISSED a named FAIL in a 2 MB output"
        return 1
    fi
    echo "   ok   control: the classifier finds a named FAIL in a 2 MB output"
    # A real bite whose output also quotes 'error: ' (a warning on a line of source).
    local mixed
    mixed="$(printf 'warning: result unused\n    conv.convert(to: out, error: &e)\n  FAIL  planted named case\n')"
    if [ "$(classify_output "FAIL  planted named case" "$mixed")" != bit ]; then
        echo "   FAIL control: a named FAIL next to a quoted 'error: ' was NOT scored as a bite"
        return 1
    fi
    echo "   ok   control: a named FAIL next to a quoted 'error: ' is scored as a bite"
    return 0
}
