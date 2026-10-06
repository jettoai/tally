#!/bin/bash
# The surface's pages after B-5671: three header tabs with Cost second, Spend / Tokens inside Cost,
# the -TallyTab words (old capture commands keep working), the pin hand-off carrying both halves,
# and the background cost-snapshot cadence riding the quota poll. Pure types compiled and run;
# the wiring around them asserted on code with comments stripped. Exits non-zero on failure.
set -euo pipefail
cd "$(dirname "$0")/.."
out=$(mktemp -d)/run
swiftc -o "$out" tests/costtab/main.swift Tally/Views/SurfacePage.swift \
  Tally/Stores/TokenScanCadence.swift
"$out"
