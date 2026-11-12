#!/bin/bash
# Compiles the one-process CPU watch's pure half (ProcessCPUWatchLogic) and its ps reader with an
# assertion harness and runs it. Logic reaches hostHealthIsSystemPath, so the host-health sources
# come with it (the list tests/run-hosthealth-tests.sh builds). Foundation only, no Xcode target;
# exits non-zero on failure. The end of the harness reads the monitor, timer and catalog as text
# for the structural promises a pure harness cannot drive.
set -euo pipefail
cd "$(dirname "$0")/.."
out=$(mktemp -d)/run
swiftc -o "$out" tests/processcpu/main.swift \
  Tally/Core/ProcessCPUWatchLogic.swift Tally/Core/ProcessCPUWatchReaders.swift \
  Tally/Core/HostHealthLogic.swift Tally/Core/HostHealthCPU.swift Tally/Core/HostHealthStatus.swift Tally/Core/HostHealthNaming.swift Tally/Core/HostHealthSessions.swift \
  Tally/Core/KeystrokeText.swift TallyCLI/HostHealthKnockLogic.swift
"$out"
