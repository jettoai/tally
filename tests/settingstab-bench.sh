#!/bin/bash
# Live measurement of Settings pane switches (Tally/MenuBar/SettingsTabBench.swift). Not part of
# run-all-tests.sh: it opens a real window for about 15s and needs it visible on screen.
#
#   tests/settingstab-bench.sh [path/to/Tally Dev.app] [out.jsonl]
#
# With no app, builds Debug and uses that. Opens a SECOND instance (open -g -n), never touching one
# already running, with demo data so the numbers repeat and nothing is written to ~/.tally/snapshot.
# Regression gate for "a pane switch never changes the window": walks every ordered pane pair once
# and exits non-zero if any switch changed the window's size or the right-hand content column's size
# (before versus after, or on any frame in between), left the new pane scrolled away from its top
# (the column is parked at the foot of the old pane before each switch), or took over 320ms to
# settle. It also reads where the skeleton's landmarks stand on every page once it has settled (the
# header, the content column, its first element, the sidebar's brand and navigation; the numbers are
# PageSkeleton's) and fails a page that is missing one or has one elsewhere: a page that does not use
# the fixed-header shell reports no header at all. Dropped frames and maxGap (the longest gap between frames, a stand-in for a main-thread
# stall) are printed but not judged: entering Integrations stalls the main thread for 67 to 99ms
# on the unchanged pre-fixed-size build too (first expansion of that pane, every pane lays out on
# each switch), so a threshold on it fails for a reason this gate is not about.
set -euo pipefail
cd "$(dirname "$0")/.."

app="${1:-}"
out="${2:-$(mktemp -d)/bench.jsonl}"
if [ -z "$app" ]; then
    xcodebuild build -project Tally.xcodeproj -scheme Tally -destination 'platform=macOS' -quiet
    dir=$(xcodebuild -project Tally.xcodeproj -scheme Tally -configuration Debug -showBuildSettings 2>/dev/null \
        | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{print $2}')
    app="$dir/Tally Dev.app"
fi
[ -d "$app" ] || { echo "no app at $app" >&2; exit 2; }

: > "$out"
open -g -n "$app" --args -TallyDemoData YES -appLanguage en -TallySettingsTabBench "$out"

# The bench ends its file with a {"done": true} line, so wait for that rather than a line count.
for _ in $(seq 1 240); do
    command grep -q '"done"' "$out" && break
    sleep 0.5
done
command grep -q '"done"' "$out" || { echo "bench did not finish in 120s ($out)" >&2; exit 3; }

python3 - "$out" <<'EOF'
import json, os, sys
lines = [json.loads(l) for l in open(sys.argv[1])]
rows = [r for r in lines if "done" not in r]
done = [r for r in lines if "done" in r][0]
if done["switches"] != len(rows) or not rows:
    print(f"done line says {done['switches']} switches, file has {len(rows)} rows", file=sys.stderr)
    sys.exit(4)

def same(a, b):
    return all(abs(x - y) <= 0.5 for x, y in zip(a, b))

def dim(v):
    return f"{v[0]:.0f}x{v[1]:.0f}"

# Where each landmark stands, [x, y, width, height] in the window, tolerance half a point; None = any.
def landmarks(pane):
    return {
        f"{pane}.header": [200, 0, 780, 104],
        f"{pane}.column": [240, 116, 700, None],
        f"{pane}.first": [240, 116, 700, 0],
        "sidebar.nav": [None, 116, None, None],
        "sidebar.brand": [None, 46, None, None],
    }

def misplaced(r):
    geo = r.get("geometry", {})
    bad = []
    for key, want in landmarks(r["to"]).items():
        got = geo.get(key)
        if got is None:
            bad.append(f"{key} missing")
        elif any(w is not None and abs(w - g) > 0.5 for w, g in zip(want, got)):
            bad.append(f"{key} {[round(g, 1) for g in got]} not {want}")
    return bad

print(f"{'from':>12} {'to':>12} {'window':>9} {'content':>9} {'resized':>7} {'settle':>6} "
      f"{'top':>5} {'dropped':>7} {'maxGap':>6}")
bad = 0
for r in rows:
    off = misplaced(r)
    fail = (not same(r["windowBefore"], r["windowAfter"])
            or not same(r["contentBefore"], r["contentAfter"])
            or r["resizedFrames"] > 0 or r["scrolledFromTop"] > 1 or r["settleMs"] > 320 or bool(off))
    bad += fail
    if off:
        print(f"{r['from']:>12} {r['to']:>12} landmarks: {'; '.join(off)}")
    print(f"{r['from']:>12} {r['to']:>12} {dim(r['windowAfter']):>9} {dim(r['contentAfter']):>9} "
          f"{r['resizedFrames']:>7} {r['settleMs']:>6} {r['scrolledFromTop']:>5.0f} {r['droppedFrames']:>7} {r['maxGapMs']:>6}"
          f"{'  FAIL' if fail else ''}")
# The window size on every tick of every switch, for a reader: one line per switch, then the verdict.
def uniq(samples):
    seen = []
    for _, w, h in samples:
        if (round(w, 1), round(h, 1)) not in seen:
            seen.append((round(w, 1), round(h, 1)))
    return seen

sequence = os.path.join(os.path.dirname(os.path.abspath(sys.argv[1])), "換頁視窗尺寸取樣序列.md")
with open(sequence, "w") as md:
    md.write("# Settings window size sampled on every frame of every pane switch\n\n")
    md.write("One line per switch: from to to, number of samples, number of distinct window sizes, the sizes.\n\n")
    every = set()
    total = 0
    for r in rows:
        values = uniq(r["samples"])
        every.update(values)
        total += len(r["samples"])
        shown = ", ".join(f"{w:g}x{h:g}" for w, h in values)
        md.write(f"- {r['from']} to {r['to']}: {len(r['samples'])} samples, {len(values)} distinct, {shown}\n")
    md.write(f"\n{len(rows)} switches, {total} samples, {len(every)} distinct window sizes in all: "
             + ", ".join(f"{w:g}x{h:g}" for w, h in sorted(every)) + "\n")
print(f"sample sequence: {sequence}")

print(f"{len(rows)} switches, {bad} over threshold "
      "(window or content changed, not at top, settle>320ms, or a landmark off the skeleton)")
sys.exit(1 if bad else 0)
EOF
