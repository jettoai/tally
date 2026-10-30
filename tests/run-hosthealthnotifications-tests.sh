#!/bin/bash
# Compile the real host-health monitor against deterministic readers and a recording sink.
set -euo pipefail
cd "$(dirname "$0")/.."
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
swiftc -parse-as-library -o "$work/run" \
  tests/hosthealthnotifications/main.swift Tally/Core/HostHealthMonitor.swift \
  Tally/Core/HostHealthLogic.swift Tally/Core/HostHealthNaming.swift \
  Tally/Core/HostHealthSessions.swift Tally/Core/KeystrokeText.swift
# Isolated Foundation homes: the harness never mutates user data.
for case_name in muted enabled legacy independent default scan-mute memory; do
  mkdir -p "$work/$case_name"
  echo "case: $case_name"
  case "$case_name" in
    muted) cpu=0; host=0; expected=0 ;;
    enabled) cpu=0; host=1; expected=2 ;;
    legacy) cpu=0; host=unset; expected=0 ;;
    independent) cpu=1; host=0; expected=0 ;;
    default) cpu=unset; host=unset; expected=2 ;;
    scan-mute) cpu=1; host=1; expected=0 ;;
    memory) cpu=1; host=0; expected=0 ;;
  esac
  (
    export CFFIXED_USER_HOME="$work/$case_name" TALLY_TEST_EXPECTED="$expected"
    if [ "$cpu" != unset ]; then export cpuAlertEnabled="$cpu"; fi
    if [ "$host" != unset ]; then export hostHealthAlertEnabled="$host"; fi
    if [ "$case_name" = scan-mute ]; then export TALLY_TEST_SCAN_MUTE=1; fi
    if [ "$case_name" = memory ]; then export TALLY_TEST_MEMORY=1; fi
    "$work/run"
  )
done
