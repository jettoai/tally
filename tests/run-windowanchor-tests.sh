#!/bin/bash
# Compiles the resize anchor's pure geometry (Tally/Core/ResizeAnchor.swift) with a small assertion
# harness and runs it. CoreGraphics only, so no AppKit and no Xcode test target; the window
# controllers apply this arithmetic through NSWindow.setFrameOrigin (see WindowPlacement.swift).
# Exits non-zero on failure.
set -euo pipefail
cd "$(dirname "$0")/.."
out=$(mktemp -d)/run
swiftc -o "$out" tests/windowanchor/main.swift tests/windowanchor/popover.swift \
    Tally/Core/ResizeAnchor.swift Tally/Core/StatusAnchor.swift Tally/Core/TogglePress.swift
"$out"
