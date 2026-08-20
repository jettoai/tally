#!/bin/bash
# Compiles the advisory knock's pure decision (TallyCLI/QuotaKnockLogic.swift) together with a small
# assertion harness and runs it. No Xcode target is needed; exits non-zero on failure.
#
# The source list is that decision's closure and nothing more. AccountPick brings the windows it
# reads and the two sentences it quotes (`bindingWindow`, `windowReason`, `pickReason`), with
# AccountComfort behind them for the nearly-dry reading those are taken through, and Snapshot for
# the account type (ResumePrompt and ProviderExecutable come with Snapshot, as they do for the
# smart-pick suite). Rebalance is here for one function: the same-drought rule this shares with the
# rebalance claim, which is the point of sharing it rather than writing a second tolerance. The tick
# that acts on all of this is asserted in the supervisor suite instead, which is where the session
# input channel and the snapshot read already compile.
set -euo pipefail
cd "$(dirname "$0")/.."
out=$(mktemp -d)/run
swiftc -o "$out" tests/quotaknock/main.swift \
  TallyCLI/QuotaKnockLogic.swift TallyCLI/Snapshot.swift TallyCLI/AccountPick.swift \
  TallyCLI/AccountBinding.swift TallyCLI/AccountReserveReader.swift Tally/Core/AccountReserve.swift \
  Tally/Core/ArtifactHookContract.swift \
  TallyCLI/AccountComfort.swift TallyCLI/Rebalance.swift TallyCLI/MoveField.swift TallyCLI/Quarantine.swift \
  TallyCLI/ResumePrompt.swift TallyCLI/ProviderExecutable.swift
"$out"
