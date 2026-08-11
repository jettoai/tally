#!/bin/bash
# Runs the completion script (TallyCLI/Completion.swift) inside a real interactive zsh and checks
# what it puts at the cursor. No Xcode test target needed; exits non-zero on failure.
#
# HERMETIC: the `tally` the script asks its questions of is a stub in this fixture, so the answers
# are the fixture's rather than this machine's fleet - the assertions can then name the worktrees
# and accounts they expect. What is under test is the script's half of the contract: given those
# lines on stdout, these words at the cursor.
set -euo pipefail
cd "$(dirname "$0")/.."

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# The script itself, out of the constant the CLI prints it from.
swiftc -o "$work/dump" tests/completion/main.swift \
  TallyCLI/Completion.swift TallyCLI/Snapshot.swift TallyCLI/AccountPick.swift \
  TallyCLI/AccountComfort.swift TallyCLI/ProviderExecutable.swift TallyCLI/ResumePrompt.swift \
  Tally/Core/LaunchAxisNames.swift
mkdir -p "$work/fpath" "$work/stub" "$work/repo"
"$work/dump" > "$work/fpath/_tally"

# A syntax error would fail every behaviour check below with the same unhelpful silence.
zsh -n "$work/fpath/_tally"

# The stub the completion asks. Same contract as the real binary: `worktree list` is one
# tab-separated line per worktree with the branch first, `completion data accounts` is one candidate
# per line. TALLY_STUB_MODE=bare answers as a repository with no worktrees does (nothing on stdout,
# a note on stderr, exit 0).
cat > "$work/stub/tally" <<'STUB'
#!/bin/sh
case "$1 $2" in
  "worktree list")
    if [ "${TALLY_STUB_MODE:-full}" = bare ]; then
      echo "no worktrees" >&2
      exit 0
    fi
    printf 'wt-alpha\t2 days ago\t\t-\tsome commit subject\n'
    printf 'wt-beta\t3 weeks ago\t*\t2 agents\tanother subject\n'
    exit 0
    ;;
  "completion data")
    [ "$3" = accounts ] && [ "$4" = claude ] || exit 2
    printf 'Stub One\nStub Two\n'
    exit 0
    ;;
esac
exit 2
STUB
chmod +x "$work/stub/tally"

# The directory the completion runs in, carrying a file whose name no check may ever see: this
# binary has no argument that takes a path.
touch "$work/repo/a-file-here.txt"

zsh -f tests/completion/drive.zsh "$work/fpath" "$work/stub" "$work/repo"
