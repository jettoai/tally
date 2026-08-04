#!/bin/bash
# Compiles the panel's provider sections and their fold rule (Tally/Core/PanelSections.swift) with
# a small assertion harness and runs it. Foundation only, so no SwiftUI and no Xcode test target;
# the panel draws these sections (Tally/Views/PopoverCardGrid.swift) and the fleet strip's chevron
# writes the same state (Tally/Views/FleetStripView.swift). Exits non-zero on failure.
set -euo pipefail
cd "$(dirname "$0")/.."
out=$(mktemp -d)/run
swiftc -o "$out" tests/sections/main.swift Tally/Core/PanelSections.swift
"$out"
