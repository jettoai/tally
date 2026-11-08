#!/bin/bash
# The Detailed panel's text contrast on the worst desktop (Tally/Core/PanelPalette.swift), a pure
# arithmetic harness: Foundation only, no AppKit and no Xcode test target. Exits non-zero on failure.
set -euo pipefail
cd "$(dirname "$0")/.."
out=$(mktemp -d)/run
swiftc -o "$out" tests/panelcontrast/main.swift Tally/Core/PanelPalette.swift Tally/Core/PanelMetrics.swift Tally/Core/PanelGeometry.swift
"$out"
