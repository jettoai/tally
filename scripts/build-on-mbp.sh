#!/bin/bash
# Build split across two machines: compile on the MBP (no credential leaves this Mac), then sign,
# notarize and staple here. Everything after the DMG (appcast, upload) stays with the caller.
# Usage: scripts/build-on-mbp.sh [--with-overlay] [BUILD_SETTING=value ...]
#                                [--dist DIR] [--skip-sentry] [--version V] [--build N]
#   BUILD_SETTING=value goes to the build on the MBP; the other options to sign-and-notarize.sh.
#   --with-overlay builds the overlay linked at ./overlay: its git-tracked files (minus .env*,
#   build/ and rust/target, which git does not track, and the rust/public link, which
#   link-public.sh makes again) are staged in build/overlay-send, sent to the MBP and linked there as ./overlay.
#   TALLY_BUILD_HOST_RUN is the command that runs a job on the MBP (it takes --quiet, --send and
#   --fetch before `--`); the overlay's handoff.env supplies it, and an exported value wins.
set -euo pipefail

cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
[ ! -f overlay/handoff.env ] || . overlay/handoff.env
[ -n "${TALLY_BUILD_HOST_RUN:-}" ] || { echo "TALLY_BUILD_HOST_RUN is not set (the overlay's handoff.env supplies it)" >&2; exit 1; }
read -r -a RUN <<< "$TALLY_BUILD_HOST_RUN"
MODE=public
SETTINGS=()
SIGN_ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --with-overlay) MODE=overlay ;;
    --dist|--version|--build) SIGN_ARGS+=("$1" "${2:?$1 needs a value}"); shift ;;
    --skip-sentry) SIGN_ARGS+=("$1") ;;
    *=*) SETTINGS+=("$1") ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
  shift
done

fallback() { echo "MBP build failed or the MBP is unreachable. Fall back to the old all-local path: scripts/build-release.sh$([ "$MODE" = overlay ] && echo ' --with-overlay') (no --handoff), or run the release with --local" >&2; }

HEAD_SHA=$(git rev-parse HEAD)
REMOTE="TALLY_HANDOFF_HEAD=$HEAD_SHA"
SEND=()
QUIET=40m
if [ "$MODE" = overlay ]; then
  [ -f overlay/Overlay.xcconfig ] || { echo "overlay missing at ./overlay" >&2; exit 1; }
  [ -z "$(git -C overlay status --porcelain)" ] || { echo "overlay has uncommitted changes" >&2; exit 1; }
  OVERLAY_HEAD=$(git -C overlay rev-parse HEAD)
  rm -rf build/overlay-send
  mkdir -p build/overlay-send
  git -C overlay ls-files -z -- . ':(exclude,glob).env*' ':(exclude,glob)**/.env*' ':(exclude)rust/public' \
    | rsync -a --from0 --files-from=- overlay/ build/overlay-send/
  [ -f build/overlay-send/Overlay.xcconfig ] && [ ! -e build/overlay-send/.env.release ] \
    || { echo "overlay staging went wrong" >&2; exit 1; }
  SEND=(--send build/overlay-send)
  REMOTE="ln -sfn build/overlay-send overlay && $REMOTE TALLY_HANDOFF_OVERLAY_HEAD=$OVERLAY_HEAD"
  QUIET=60m
fi
REMOTE="$REMOTE scripts/build-release.sh --handoff"
if [ "$MODE" = overlay ]; then REMOTE="$REMOTE --with-overlay"; fi
for s in ${SETTINGS[@]+"${SETTINGS[@]}"}; do REMOTE="$REMOTE $(printf '%q' "$s")"; done

rm -rf build/handoff
echo "[$(date +%T)] ==> build on the MBP ($MODE)"
"${RUN[@]}" --quiet "$QUIET" ${SEND[@]+"${SEND[@]}"} --fetch build/handoff -- \
  bash -c "$REMOTE" || { fallback; exit 1; }
echo "[$(date +%T)] <== build on the MBP"
TAR=""
for f in build/handoff/Tally-*-"$MODE".tar; do [ -f "$f" ] && TAR="$f"; done
[ -n "$TAR" ] || { echo "the MBP job left no handoff tar" >&2; fallback; exit 1; }
exec scripts/sign-and-notarize.sh ${SIGN_ARGS[@]+"${SIGN_ARGS[@]}"} "$TAR"
