#!/bin/bash
# Live measurement of Settings pane switches (Tally/MenuBar/SettingsTabBench.swift). Not part of
# run-all-tests.sh: it opens a real window for about 15s and needs it visible on screen.
#
#   tests/settingstab-bench.sh [path/to/Tally Dev.app] [out.jsonl]
#
# With no app, builds Debug and uses that. Opens a SECOND instance (open -g -n), never touching one
# already running, with demo data so the numbers repeat and nothing is written to ~/.tally/snapshot.
# Regression gate: exits non-zero if any of the 20 switches clipped a frame, stalled the main thread
# over 80ms, or took over 320ms to settle. Dropped frames are printed but not judged: they are a
# known remaining cost (every pane, collapsed ones included, lays out on each switch), to be
# tightened when collapsed panes stop taking part in layout.
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

for _ in $(seq 1 120); do
    [ "$(wc -l < "$out")" -ge 20 ] && break
    sleep 0.5
done
lines=$(wc -l < "$out" | tr -d ' ')
[ "$lines" -ge 20 ] || { echo "bench wrote $lines of 20 lines in 60s ($out)" >&2; exit 3; }

python3 - "$out" <<'EOF'
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1])]
print(f"{'from':>12} {'to':>12} {'toPane':>6} {'content':>7} {'settle':>6} {'frames':>6} {'dropped':>7} {'maxGap':>6} {'clipped':>7}")
bad = 0
for r in rows:
    fail = r["clippedFrames"] > 0 or r["maxGapMs"] > 80 or r["settleMs"] > 320
    bad += fail
    print(f"{r['from']:>12} {r['to']:>12} {r['toPaneHeight']:>6.0f} {r['contentHeight']:>7.0f} "
          f"{r['settleMs']:>6} {r['frames']:>6} {r['droppedFrames']:>7} {r['maxGapMs']:>6} "
          f"{r['clippedFrames']:>7}{'  FAIL' if fail else ''}")
print(f"{len(rows)} switches, {bad} over threshold (clipped>0, maxGap>80ms or settle>320ms)")
sys.exit(1 if bad else 0)
EOF
