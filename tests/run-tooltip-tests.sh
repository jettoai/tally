#!/bin/bash
# Compiles the hover callout's placement geometry (Tally/Core/TooltipPlacement.swift) with a small
# assertion harness and runs it. CoreGraphics only, so no SwiftUI and no Xcode test target; the
# callout applies this arithmetic through two alignment guides (see Tally/Views/TallyTooltip.swift).
# Exits non-zero on failure.
set -euo pipefail
cd "$(dirname "$0")/.."
out=$(mktemp -d)/run
swiftc -o "$out" tests/tooltip/main.swift Tally/Core/TooltipPlacement.swift
"$out"
