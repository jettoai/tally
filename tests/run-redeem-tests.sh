#!/bin/bash
# Compiles the redeem propagation window logic (Tally/Core/RedeemPropagation.swift) and the
# four-state reset offer (Tally/Core/ResetOffer.swift, with the types it reads) with a small
# assertion harness and runs it. The file is Foundation-only, so nothing else comes along; no
# Xcode test target needed. Exits non-zero on failure.
set -euo pipefail
cd "$(dirname "$0")/.."
out=$(mktemp -d)/run
swiftc -o "$out" tests/redeem/main.swift tests/redeem/offerchecks.swift tests/redeem/listparitychecks.swift \
  Tally/Core/RedeemPropagation.swift Tally/Core/ResetOffer.swift Tally/Core/LimitReset.swift \
  Tally/Providers/ProviderModels.swift
"$out"
