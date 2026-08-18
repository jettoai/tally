#!/bin/bash
# Runs every tests/run-*-tests.sh at once and prints one table.
#
# The suites are independent by construction: each one compiles its own binary into its own
# mktemp directory and touches no shared port, server or output file, so the only thing that was
# ever serialising them is the loop that called them. Measured on this machine, the whole set runs
# in about 93s one after another and in about 70s at the default of 4 at a time, which is the
# slowest suite plus the queue behind it rather than the sum of them. Change it with
# TALLY_TEST_JOBS.
#
# WHY THE DEFAULT IS FOUR AND NOT EIGHT, which is faster. The floor is the longest suite either way:
# three of them are 36s to 50s on their own (supervisor, worktree, completion) and every other one
# finishes inside 20s. What eight buys is about 18s of the 70, and what it costs is a suite that
# fails for reasons that have nothing to do with the code. The completion suite drives a real zsh
# through a pty and decides the shell has finished answering when it has been silent for half a
# second, and a machine running eight swift compilations produces half-second silences on its own.
# Measured here, 2026-08-18, same tree, alternating: eight at a time failed 3 runs of 8, always the
# same probe (`tally claude -w <Tab>`, the one that forks the stub); four at a time failed 0 of 10;
# the suite on its own passed every time, including with eight spinning CPU hogs beside it. So the
# contention that reaches it is the compiles rather than the load average, and the numbers above
# are the reason this default is not tuned for the wall clock alone.
#
# EVERY SUITE'S EXIT CODE IS WRITTEN DOWN, and those files are the verdict rather than the return
# of xargs: xargs answers 123 for "one or more of them failed" and says nothing about which, and a
# worker that died before writing its status is a case that coarse code cannot tell from success.
# A missing status file therefore counts as a failure, and so does an xargs return nobody's status
# file explains.
#
# Output goes to one log per suite so nothing interleaves, and the log of anything that failed is
# printed in full under the table, which is where a failure is read from.
#
# THIS FILE'S OWN NAME MATCHES THE PATTERN IT EXPANDS, so the list is filtered and the recursion is
# refused as well. Unfiltered, the first run of this script was a fork bomb: it ran itself as its
# 35th suite, and each copy ran itself again, 151 suite processes and 481 swift jobs deep before it
# was killed. One guard would have been enough; there are two because the cost of the miss is the
# machine and the cost of the guard is a line.
set -euo pipefail
cd "$(dirname "$0")/.."

if [ -n "${TALLY_TEST_ALL:-}" ]; then
    echo "run-all-tests.sh called itself: refusing to recurse" >&2
    exit 1
fi
export TALLY_TEST_ALL=1

jobs=${TALLY_TEST_JOBS:-4}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

self=$(basename "$0")
suites=()
for script in tests/run-*-tests.sh; do
    if [ -f "$script" ] && [ "$(basename "$script")" != "$self" ]; then
        suites+=("$script")
    fi
done
[ ${#suites[@]} -gt 0 ] || { echo "no suites matched tests/run-*-tests.sh" >&2; exit 1; }

# The worker is a file rather than an exported shell function on purpose: xargs starts a fresh
# bash, and a function exported by one version of bash is not importable by another.
cat > "$work/run-suite" <<'WORKER'
#!/bin/bash
suite=$(basename "$1" .sh)
began=$(date +%s)
if "$1" > "$TALLY_TEST_WORK/$suite.log" 2>&1; then rc=0; else rc=$?; fi
printf '%s %s\n' "$rc" "$(( $(date +%s) - began ))" > "$TALLY_TEST_WORK/$suite.status"
WORKER
chmod +x "$work/run-suite"
export TALLY_TEST_WORK="$work"

echo "running ${#suites[@]} suites, $jobs at a time"
began=$(date +%s)
xargs_rc=0
printf '%s\0' "${suites[@]}" | xargs -0 -P "$jobs" -n1 "$work/run-suite" || xargs_rc=$?
elapsed=$(( $(date +%s) - began ))

failed=()
for script in "${suites[@]}"; do
    suite=$(basename "$script" .sh)
    # A worker that never reached the end of its own script left no status, or half of one. Both
    # are failures: what they cannot be is mistaken for the suite having passed.
    rc=1
    secs=0
    note="no status file"
    if [ -f "$work/$suite.status" ]; then
        if read -r rc secs < "$work/$suite.status"; then
            note="exit $rc"
        else
            rc=1
            secs=0
            note="truncated status file"
        fi
    fi
    if [ "$rc" = 0 ]; then
        printf '  %-32s PASS %4ss\n' "$suite" "$secs"
    else
        printf '  %-32s FAIL %4ss (%s)\n' "$suite" "$secs" "$note"
        failed+=("$suite")
    fi
done

if [ ${#failed[@]} -gt 0 ]; then
    for suite in "${failed[@]}"; do
        echo
        echo "----- $suite -----"
        cat "$work/$suite.log" 2>/dev/null || echo "(no log was written)"
    done
fi

echo
echo "${#suites[@]} suites, ${#failed[@]} failed, ${elapsed}s wall clock"
if [ ${#failed[@]} -gt 0 ]; then
    exit 1
fi
if [ "$xargs_rc" -ne 0 ]; then
    # Every suite reported success and the runner still returned something: that is a failure of
    # the run rather than of a suite, and the safe reading of an unexplained code is not "green".
    echo "xargs exited $xargs_rc with no failing suite to explain it" >&2
    exit 1
fi
