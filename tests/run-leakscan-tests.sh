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
    | "$HOOK" "${to:-origin}" "${to:-$work/remote.git}" > /dev/null 2> "$work/err" || rc=$?
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

# git log -p prints an added "++ x" line as "+++ x", the same as a file header.
start c2; commit src/app.txt '++ FakeWidget07'
check "added line starting with ++" 1 "$base" "$(line "$sha" src/app.txt '++ FakeWidget07')"

start c2b; commit README.md "$(printf '++ harmless\nsee quartz lantern')"
check "allow keeps the file name after a ++ line" 0 "$base"

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

# A merge whose conflict resolution writes a term: only the merge's own diff carries that line.
start c19; echo side > src/app.txt; git commit -q -am side; side=$(git rev-parse HEAD)
start c19b; echo main > src/app.txt; git commit -q -am main
git merge -q "$side" > /dev/null 2>&1 || true
printf 'merged\nx FakeWidget11 y\n' > src/app.txt; git add src/app.txt; git commit -q -m merge
check "term written while resolving a merge" 1 "$base" "$(line "$(git log -1 --format=%h)" src/app.txt 'x FakeWidget11 y')"

# A private path added while resolving a merge and dropped again by a later merge: a plain delete
# commit would list the path, so both steps are merges.
start c19d; echo notes2 >> docs/NOTES.md; git commit -q -am side2; side2=$(git rev-parse HEAD)
start c19c; echo main > src/app.txt; git commit -q -am main
git merge -q "$side" > /dev/null 2>&1 || true
echo merged > src/app.txt; echo x > src/FakeWidget05.txt; git add src/app.txt src/FakeWidget05.txt
git commit -q -m merge
git merge -q --no-ff --no-commit "$side2" > /dev/null 2>&1; git rm -q src/FakeWidget05.txt; git commit -q -m merge2
check "private path added by a merge, then deleted" 1 "$base" "$(line - src/FakeWidget05.txt 'private path')"

# Pushing to a URL: a commit that only a private remote has is still new to that URL.
start c20; commit src/app.txt 'x FakeWidget12 y'
git config remote.private.url "$work/private.git"
git update-ref refs/remotes/private/c20 HEAD
to=$work/public.git
check "URL push, commit only on another remote" 1 "$ZERO" "$(line "$sha" src/app.txt 'x FakeWidget12 y')"
to=$work/private.git
check "URL push equal to a named remote that has the commit" 0 "$ZERO"
git config remote.private.pushurl "$work/private.git"
to=private
check "named push, pushurl equal to url" 0 "$ZERO"

# A remote that fetches from the private repo but pushes to a public one: its tracking refs say
# nothing about the push target.
start c21; commit src/app.txt 'x FakeWidget13 y'
git config remote.mixed.url "$work/private2.git"
git config remote.mixed.pushurl "$work/public2.git"
git update-ref refs/remotes/mixed/c21 HEAD
to=mixed
check "named push, pushurl differs from url" 1 "$ZERO" "$(line "$sha" src/app.txt 'x FakeWidget13 y')"
to=$work/public2.git
check "URL push equal to a pushurl that differs from url" 1 "$ZERO" "$(line "$sha" src/app.txt 'x FakeWidget13 y')"
to=

echo "leakscan: $pass passed, $failed failed"
[ "$failed" = 0 ]
