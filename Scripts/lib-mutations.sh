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

# The control every harness runs first: a named FAIL at the top of a 2 MB output must be
# found by the fixed-string and the regex classifier alike.
lib_self_test() {
    local big
    big="$(printf '  FAIL  planted named case\n'; head -c 2000000 /dev/zero | tr '\0' 'x')"
    if contains "FAIL  planted named case" "$big" && contains_re 'FAIL +planted' "$big"; then
        echo "   ok   control: the classifier finds a named FAIL in a 2 MB output"
        return 0
    fi
    echo "   FAIL control: the classifier MISSED a named FAIL in a 2 MB output"
    return 1
}
