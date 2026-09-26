#!/bin/bash
# Ratchet on blocking IO written directly on the main thread in Tally/ (tests/mainio/mainio_lint.py).
#
# WHAT IT GUARDS. Three fixes in one day (82cba81, d5d740e, d9e5139) moved file reads, file writes
# and process-table walks off the main thread after Sentry reported the app hanging for 2000 ms on
# users' machines; nothing at commit time would have turned red for any of them. This suite counts
# every direct IO call (tests/mainio/io_api.txt) whose enclosing context runs on the main thread (a
# @MainActor type or func, a View body, MainActor.run / DispatchQueue.main / `queue: .main` /
# Timer.scheduledTimer closures, `Task {}` inheriting) and compares it with tests/mainio/baseline.tsv
# keyed by (file, Type.func, api). A new site, or a background site moved back onto the main thread,
# is red and printed as file:line with the source line. Fewer sites than the baseline is green with
# a note to lower the baseline. tests/mainio/allowlist.tsv exempts a key for good; each row carries
# a reason, and a row without one is red.
#
# WHAT IT DOES NOT SEE (named blind spots). Only the direct site counts: a sync helper doing IO that
# is called from the main thread is invisible, and so is IO reached through protocol dispatch, a
# function reference or an injected closure. `nonisolated` funcs are treated as off the main
# thread. The checker is a lexical approximation of Swift (brace tracking, string stripping), not
# the compiler: macros, `#if` branches and unusual closure shapes can be misread. The d5d740e replay
# below is green for exactly this reason: every site that commit moved was one call deep
# (SessionProcessGroups.load / record, the stray readers injected into ProjectLoadAccounting, the
# reload readiness read behind a computed value).
#
# The mutations work on a copy of Tally/ in a temp directory, never on the working tree, and each
# one prints the line it landed before its verdict is read (a mutation that did not land looks
# exactly like a check that did not fire).
set -euo pipefail
cd "$(dirname "$0")/.."
lint=tests/mainio/mainio_lint.py
base=tests/mainio/baseline.tsv
allow=tests/mainio/allowlist.tsv
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failed=0
pass() { echo "PASS $1"; }
fail() { echo "FAIL $1"; failed=1; }

# expect NAME red|green TREE [needle] [allowlist]: red also needs the needle in the report.
expect() {
    local name=$1 want=$2 tree=$3 needle=${4:-} al=${5:-$allow} rc=0
    python3 "$lint" "$tree" --baseline "$base" --allowlist "$al" > "$work/$name.out" 2>&1 || rc=$?
    sed 's/^/    | /' "$work/$name.out"
    if [ "$want" = green ] && [ $rc -eq 0 ]; then pass "$name green"
    elif [ "$want" = red ] && [ $rc -eq 1 ] && command grep -qF -- "$needle" "$work/$name.out"; then pass "$name red"
    else fail "$name: wanted $want, rc=$rc"; fi
}

# fresh NAME: a copy of the current Tally/ sources to mutate.
fresh() { mkdir -p "$work/$1"; cp -R Tally "$work/$1/"; echo "$work/$1"; }

# mutate FILE OLD NEW: replaces exactly one occurrence or dies.
mutate() {
    python3 - "$@" <<'PY'
import sys
path, old, new = sys.argv[1:4]
src = open(path, encoding='utf-8').read()
assert src.count(old) == 1, 'mutation anchor not found exactly once in %s: %r' % (path, old)
open(path, 'w', encoding='utf-8').write(src.replace(old, new))
PY
}

landed() { echo "  landed: $(command grep -nF -- "$2" "$1" | head -1)"; [ -n "$(command grep -nF -- "$2" "$1")" ] || fail "mutation did not land in $1"; }

echo "== working tree against the baseline"
expect head green .

probe='_ = FileManager.default.fileExists(atPath: "/tmp/mainio-probe")'
card=Tally/Views/SessionCardFootprint.swift
store=Tally/Stores/UsageStore.swift

echo "== M1: IO added to a View computed property"
t=$(fresh m1)
mutate "$t/$card" $'var sessionPortsText: String? {\n' $'var sessionPortsText: String? {\n        '"$probe"$'\n'
landed "$t/$card" "$probe"
expect m1 red "$t" "$card"

echo "== M2: HostHealthMonitor's write moved back onto the main thread (d9e5139's parent file)"
t=$(fresh m2)
git show d9e5139^:Tally/Core/HostHealthMonitor.swift > "$t/Tally/Core/HostHealthMonitor.swift"
landed "$t/Tally/Core/HostHealthMonitor.swift" "try? data.write(to: file, options: .atomic)"
expect m2 red "$t" "HostHealthMonitor.publish"

echo "== M3: the same line as M1 inside Task.detached (control: must stay green)"
t=$(fresh m3)
mutate "$t/$card" $'var sessionPortsText: String? {\n' $'var sessionPortsText: String? {\n        Task.detached { '"$probe"$' }\n'
landed "$t/$card" "$probe"
expect m3 green "$t"

echo "== M4: a nonisolated static helper in a @MainActor type (named blind spot: stays green)"
t=$(fresh m4)
mutate "$t/$store" $'final class UsageStore {\n' $'final class UsageStore {\n    nonisolated static func mainioProbe() { '"$probe"$' }\n'
landed "$t/$store" "$probe"
expect m4 green "$t"

echo "== M5: the same helper without nonisolated is on the main actor"
t=$(fresh m5)
mutate "$t/$store" $'final class UsageStore {\n' $'final class UsageStore {\n    static func mainioProbe() { '"$probe"$' }\n'
landed "$t/$store" "$probe"
expect m5 red "$t" "UsageStore.mainioProbe"

strip=Tally/MenuBar/MenuBarStrip.swift
echo "== M7: a Timer.scheduledTimer closure in a plain enum runs on the main run loop"
t=$(fresh m7)
mutate "$t/$strip" $'enum MenuBarStripRenderer {\n' $'enum MenuBarStripRenderer {\n    static func mainioTimer() { Timer.scheduledTimer(withTimeInterval: 1, repeats: false) { _ in '"$probe"$' } }\n'
landed "$t/$strip" "$probe"
expect m7 red "$t" "MenuBarStripRenderer.mainioTimer"

echo "== M8: an observer on queue: .main in a plain enum"
t=$(fresh m8)
mutate "$t/$strip" $'enum MenuBarStripRenderer {\n' $'enum MenuBarStripRenderer {\n    static func mainioObserve() { NotificationCenter.default.addObserver(forName: .init("x"), object: nil, queue: .main) { _ in '"$probe"$' } }\n'
landed "$t/$strip" "$probe"
expect m8 red "$t" "MenuBarStripRenderer.mainioObserve"

echo "== M6: an allowlist row without a reason"
cp "$allow" "$work/allow-m6.tsv"
printf 'Tally/Stores/UsageStore.swift\tUsageStore.refresh\twrite\t\n' >> "$work/allow-m6.tsv"
landed "$work/allow-m6.tsv" "UsageStore.refresh"
expect m6 red . "has no reason" "$work/allow-m6.tsv"

# Replays of the three real fixes: the parent tree against a baseline taken from the fix itself
# must be red on a file the fix touched, and the fix against its own baseline green. d5d740e is
# reported, not asserted: its sites are one call deep (see the header).
replay() {
    local sha=$1 want=$2 p="$work/r-$1/p" c="$work/r-$1/c" rc=0
    mkdir -p "$p" "$c"
    git archive "$sha^" Tally | tar -x -C "$p"
    git archive "$sha" Tally | tar -x -C "$c"
    python3 "$lint" "$c" --dump > "$work/r-$sha.base"
    python3 "$lint" "$p" --baseline "$work/r-$sha.base" > "$work/r-$sha.out" 2>&1 || rc=$?
    sed 's/^/    | /' "$work/r-$sha.out"
    if [ "$want" = red ]; then
        if [ $rc -eq 1 ] && command grep -E '^    Tally/' "$work/r-$sha.out" | cut -d: -f1 | sed 's/^ *//' \
            | command grep -qxF -f <(git diff --name-only "$sha^" "$sha" -- Tally); then
            pass "replay $sha parent red"
        else fail "replay $sha parent: wanted red on a file the fix touched, rc=$rc"; fi
    else
        echo "INFO replay $sha parent rc=$rc (named blind spot, not asserted)"
    fi
    rc=0
    python3 "$lint" "$c" --baseline "$work/r-$sha.base" > /dev/null || rc=$?
    [ $rc -eq 0 ] && pass "replay $sha fix green" || fail "replay $sha fix: wanted green, rc=$rc"
}
echo "== replay d9e5139 (host health report written on the main thread)"
replay d9e5139 red
echo "== replay 82cba81 (board, account watch and hook checks on the main thread)"
replay 82cba81 red
echo "== replay d5d740e (reload readiness, group ledger, stray counters)"
replay d5d740e info

[ $failed -eq 0 ] && echo "mainio: all checks passed" || echo "mainio: FAILED"
exit $failed
