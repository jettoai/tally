#!/bin/bash
# Compiles the press-versus-drag rule (Tally/Core/PointerIntent.swift) with a small assertion
# harness and runs it. CoreGraphics only, so no AppKit and no Xcode test target; the event loop that
# consumes the rule (DragOrTapArea, in Tally/MenuBar/PinnedPanelController.swift) is asserted by
# reading its source, because a real window and a real pointer cannot be driven from here.
# Exits non-zero on failure.
set -euo pipefail
cd "$(dirname "$0")/.."
out=$(mktemp -d)/run
swiftc -o "$out" tests/dragortap/main.swift Tally/Core/PointerIntent.swift
"$out"
