#!/bin/bash
# The refusal paths of scripts/sign-and-notarize.sh: a handoff tar that disagrees with this
# checkout (project.yml hash, git HEAD, one Mach-O replaced, an extra Mach-O) must be refused
# before any credential or signing step; one that agrees must get past the check. Also a pool
# agent file (an overlay's, not a Mach-O) replaced after the handoff was written. Uses a fixture
# app (a copy of /bin/ls as its binary), touches no key and no network.
# Count assertions with `command grep -c '^PASS:'`.
set -euo pipefail
cd "$(dirname "$0")/.."
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export TALLY_SIGN_WORK="$work/work"
# A profile that does not exist, so a handoff that gets past the check still cannot reach 1Password.
export NOTARIZE_PROFILE=tally-handoff-test-no-such-profile
# The helper agent directory an overlay would name; set here so the test does not depend on a linked overlay.
export TALLY_HANDOFF_AGENT_DIR=Contents/Resources/helper-agent
app="$work/pkg/Tally.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/helper-agent" "$work/pkg/dSYMs"
echo agent > "$app/Contents/Resources/helper-agent/helper-agent-linux-x86_64"
cp /bin/ls "$app/Contents/MacOS/Tally"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleShortVersionString</key><string>9.9.9</string>
<key>CFBundleVersion</key><string>999</string>
<key>SUPublicEDKey</key><string>7zissQ63o4tFhLie6cYtZnRSV6aas7x/0pqBOV3ZbxI=</string>
</dict></plist>
PLIST

# pack <name>: tars the fixture package as it stands into $work/<name>.tar
pack() { tar -cf "$work/$1.tar" -C "$work/pkg" Tally.app dSYMs handoff.json; }

# make_tar <name> <project sha> <git head>: records the fixture app's Mach-O list as handoff.json
make_tar() {
  scripts/handoff-machos.sh "$app" > "$work/machos.tsv"
  scripts/handoff-machos.sh --agents "$app" > "$work/agents.tsv"
  H_PROJECT_SHA="$2" H_HEAD="$3" python3 -I - "$work/machos.tsv" "$work/agents.tsv" "$work/pkg/handoff.json" <<'PY'
import json, os, sys
machos = [dict(zip(("path", "sha256", "archs"), l.rstrip("\n").split("\t"))) for l in open(sys.argv[1])]
agents = dict(l.rstrip("\n").split("\t") for l in open(sys.argv[2]))
json.dump({"mode": "public", "git_head": os.environ["H_HEAD"], "overlay_head": None,
           "project_yml_sha256": os.environ["H_PROJECT_SHA"],
           "marketing_version": "9.9.9", "build_number": "999", "xcodebuild": "", "rustc": "", "machos": machos,
           "agents": agents},
          open(sys.argv[3], "w"))
PY
  pack "$1"
}

# expect <name> <tar> <wanted text>: the script must exit non-zero with that text in its output
expect() {
  local out rc=0
  out=$(scripts/sign-and-notarize.sh "$2" 2>&1) || rc=$?
  if [ "$rc" -ne 0 ] && printf '%s' "$out" | command grep -qF -- "$3"; then echo "PASS: $1"; else echo "FAIL: $1 (rc=$rc)"; printf '%s\n' "$out" | tail -5; exit 1; fi
}

good_sha=$(shasum -a 256 project.yml | cut -d' ' -f1)
head=$(git rev-parse HEAD)
make_tar changed-project "0000$good_sha" "$head"
expect "changed project.yml hash is refused" "$work/changed-project.tar" "project_yml_sha256"
make_tar changed-head "$good_sha" "0000$head"
expect "changed git HEAD is refused" "$work/changed-head.tar" "git_head"
make_tar replaced "$good_sha" "$head"
cp /bin/cat "$app/Contents/MacOS/Tally"
pack replaced
expect "a replaced Mach-O is refused" "$work/replaced.tar" "Mach-O Contents/MacOS/Tally"
cp /bin/cat "$app/Contents/MacOS/Extra"
pack extra
expect "an extra Mach-O is refused" "$work/extra.tar" "Mach-O Contents/MacOS/Extra"

make_tar agent "$good_sha" "$head"
echo replaced > "$app/Contents/Resources/helper-agent/helper-agent-linux-x86_64"
pack agent
expect "a replaced helper agent file is refused" "$work/agent.tar" "helper agent file Contents/Resources/helper-agent/helper-agent-linux-x86_64"
echo agent > "$app/Contents/Resources/helper-agent/helper-agent-linux-x86_64"

# The matching handoff gets past the comparison (it stops later: the fixture binary is not
# universal, so the universal check is the next refusal).
cp /bin/ls "$app/Contents/MacOS/Tally"
rm -f "$app/Contents/MacOS/Extra"
make_tar good "$good_sha" "$head"
out=$(scripts/sign-and-notarize.sh "$work/good.tar" 2>&1) || true
if printf '%s' "$out" | command grep -qF "does not match this checkout"; then echo "FAIL: matching handoff refused"; printf '%s\n' "$out"; exit 1; fi
echo "PASS: a matching handoff passes the comparison"
