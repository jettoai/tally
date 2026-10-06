#!/bin/bash
# Installs scripts/hooks/pre-push as this clone's pre-push hook, shared by every worktree.
# usage: scripts/hooks/install.sh [--required]
#   --required  marks this clone as one whose pushes must be scanned against the overlay's term
#               list, so a missing overlay refuses the push instead of skipping the scan.
# A symlink in the common hooks directory, not core.hooksPath: a relative core.hooksPath resolves
# per worktree, and a worktree checked out at an older commit has no hook file, which git treats as
# no hook at all.
set -euo pipefail
common=$(git rev-parse --path-format=absolute --git-common-dir)
root=$(dirname "$common")
if [ -n "$(git config --get core.hooksPath || true)" ]; then
  echo "core.hooksPath is set, so git would not run $common/hooks; unset it first" >&2
  exit 1
fi
[ -f "$root/scripts/hooks/pre-push" ] || { echo "no scripts/hooks/pre-push in $root" >&2; exit 1; }
mkdir -p "$common/hooks"
ln -sfn "$root/scripts/hooks/pre-push" "$common/hooks/pre-push"
if [ "${1:-}" = --required ]; then git config tally.leakguard required; fi
echo "pre-push linked to $root/scripts/hooks/pre-push"
