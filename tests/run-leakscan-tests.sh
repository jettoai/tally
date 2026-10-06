#!/bin/bash
# Tests scripts/hooks/pre-push against a scratch repo and a fake overlay that prints made-up terms.
# LEAKSCAN_HOOK points the suite at another copy of the hook (to compare against an older one).
set -euo pipefail
cd "$(dirname "$0")/.."
HOOK=${LEAKSCAN_HOOK:-$PWD/scripts/hooks/pre-push}
export LC_ALL=C
ZERO=0000000000000000000000000000000000000000
TAB=$(printf '\t')
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
repo=$work/repo
fake=$work/fake
pass=0
failed=0

# gen normal|fail|short|noallow writes the fake overlay's term generator.
gen() {
  {
    echo '#!/bin/bash'
    case $1 in
      fail) echo 'exit 3' ;;
      short) printf 'echo "allow%s^README\\.md$%squartz lantern"\n' "$TAB" "$TAB" ;;
      *)
        echo 'for i in $(seq -w 1 24); do'
        printf '  echo "id%sFakeWidget$i"; echo "path%ssrc/FakeWidget$i.txt"\n' "$TAB" "$TAB"
        echo 'done'
        printf 'echo "word%squartz lantern"; echo "dir%svault"\n' "$TAB" "$TAB"
        [ "$1" = noallow ] || printf 'echo "allow%s^README\\.md$%squartz lantern"\n' "$TAB" "$TAB"
        ;;
    esac
  } > "$fake/leak-terms"
  chmod +x "$fake/leak-terms"
}

# start <name>: a fresh branch at the base commit, overlay linked, normal generator
start() {
  git checkout -q -f -B "$1" "$base"
  rm -rf "$repo/overlay"
  ln -sfn "$fake" "$repo/overlay"
  gen normal
}

# commit <file> <line> [message]: append a line to a file and commit it
commit() {
  mkdir -p "$(dirname "$1")"
  printf '%s\n' "$2" >> "$1"
  git add -f "$1"
  git commit -q -m "${3:-change}"
  sha=$(git log -1 --format=%h)
}

# check <name> <expected rc> <remote sha> [exact stderr line]
check() {
  local rc=0
  printf 'refs/heads/main %s refs/heads/main %s\n' "$(git rev-parse HEAD)" "$3" \
    | "$HOOK" origin "$work/remote.git" > /dev/null 2> "$work/err" || rc=$?
  if [ "$rc" != "$2" ]; then
    echo "FAIL $1: rc=$rc, expected $2"; sed 's/^/  | /' "$work/err"; failed=$((failed + 1)); return
  fi
  if [ -n "${4:-}" ] && ! command grep -qxF -- "$4" "$work/err"; then
    echo "FAIL $1: no stderr line: $4"; sed 's/^/  | /' "$work/err"; failed=$((failed + 1)); return
  fi
  pass=$((pass + 1))
}

line() { printf 'refs/heads/main\t%s\t%s\t%s' "$1" "$2" "$3"; }

mkdir -p "$fake"
git init -q -b main "$repo"
cd "$repo"
git config user.email test@example.com
git config user.name test
git config commit.gpgsign false
echo /overlay >> .git/info/exclude
mkdir -p docs src
echo readme > README.md
echo notes > docs/NOTES.md
echo app > src/app.txt
git add README.md docs/NOTES.md src/app.txt
git commit -q -m base
base=$(git rev-parse HEAD)
git update-ref refs/remotes/origin/main "$base"
git config remote.origin.url "$work/remote.git"

start c1; commit src/app.txt 'x FakeWidget07 y'
check "added line, existing branch" 1 "$base" "$(line "$sha" src/app.txt 'x FakeWidget07 y')"
check "added line, new branch" 1 "$ZERO" "$(line "$sha" src/app.txt 'x FakeWidget07 y')"

start c3; commit src/app.txt harmless 'docs: Quartz Lantern'
check "message, existing branch" 1 "$base" "$(line "$sha" COMMIT_MSG 'docs: Quartz Lantern')"
check "message, new branch" 1 "$ZERO" "$(line "$sha" COMMIT_MSG 'docs: Quartz Lantern')"

start c5; commit vault/x.txt harmless
check "private directory" 1 "$base" "$(line - vault/x.txt 'private directory')"

start c6; commit src/FakeWidget03.txt harmless
check "private path" 1 "$base" "$(line - src/FakeWidget03.txt 'private path')"

start c6b; commit lib/FakeWidget03Copy.txt harmless
check "renamed copy" 1 "$base" "$(line - lib/FakeWidget03Copy.txt lib/FakeWidget03Copy.txt)"

start c7; commit README.md 'see quartz lantern'
check "allowed text in allowed file" 0 "$base"

start c8; commit docs/NOTES.md 'see quartz lantern'
check "allowed text elsewhere" 1 "$base" "$(line "$sha" docs/NOTES.md 'see quartz lantern')"

start c9; commit src/app.txt 'quota pool note' 'docs: quota pool'
check "ordinary commit" 0 "$base"

start c10; ln -sfn "$work/gone" "$repo/overlay"
check "dangling overlay link" 1 "$base"
command grep -qF 'is missing (fail-closed)' "$work/err" || { echo "FAIL dangling overlay link: no fail-closed reason"; failed=$((failed + 1)); }

start c11; commit src/app.txt 'x FakeWidget07 y'
rm "$repo/overlay"; git config tally.leakguard required
check "required without overlay" 1 "$base"
command grep -qF 'is missing (fail-closed)' "$work/err" || { echo "FAIL required without overlay: no fail-closed reason"; failed=$((failed + 1)); }
git config --unset tally.leakguard
check "contributor clone" 0 "$base"

commit overlay/x harmless
# An overlay/ directory on disk already makes the scan required; drop it to reach the path check.
rm -rf "$repo/overlay"
check "overlay path in contributor clone" 1 "$base" "$(line - overlay/x 'path under overlay/')"

start c14; commit src/app.txt harmless; gen fail
check "generator fails" 1 "$base" "pre-push: leak term generator failed (fail-closed)"

gen short
check "short term list" 1 "$base" "pre-push: leak term list has 0 id lines (fail-closed)"

start c16; rc=0
printf '(delete) %s refs/heads/x %s\n' "$ZERO" "$base" | "$HOOK" origin "$work/remote.git" 2> "$work/err" || rc=$?
if [ "$rc" = 0 ]; then pass=$((pass + 1)); else echo "FAIL deleted ref: rc=$rc"; failed=$((failed + 1)); fi

start c17; bad=$(printf 'bin \377 FakeWidget09'); commit src/app.txt "$bad"
check "non UTF-8 bytes" 1 "$base" "$(line "$sha" src/app.txt "$bad")"

start c18; commit README.md 'see quartz lantern'; gen noallow
check "allow line removed" 1 "$base" "$(line "$sha" README.md 'see quartz lantern')"

echo "leakscan: $pass passed, $failed failed"
[ "$failed" = 0 ]
