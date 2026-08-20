#!/bin/bash
# Compiles the Artifact publishing guard (TallyCLI/HookArtifact.swift) together with a small
# assertion harness and runs it. No Xcode target is needed; exits non-zero on failure.
#
# The source list is that decision's closure and nothing more: the shared contract both processes
# read (Tally/Core/ArtifactHookContract.swift), and Snapshot.swift for the account type the refusal
# takes its two names from, with ResumePrompt and ProviderExecutable behind Snapshot as they are for
# every other suite that compiles it. AccountHome.swift joined it when the guard learned to
# recognise a SIGNED-OUT account: such an account publishes no launch home, so the only way back to
# its directory is the id, and that derivation is written down once, there. RenewLoginCommand.swift
# came with the same change: the refusal now prints the login command, and that command is the app's
# own rather than a second spelling of it. The app half of the same feature (the settings.json surgery,
# the row, and the one entry it adds to the auto-follow set) is asserted in the integrations suite,
# which is where the store already compiles.
#
# AccountReserve.swift is the newest of them: with no `artifactAccount` chosen, the guard falls back
# to the account the user marked as their personal one, which is a second key in the same state file
# read by the same normalization this contract already carries (`artifactAccountHome`).
set -euo pipefail
cd "$(dirname "$0")/.."
out=$(mktemp -d)/run
swiftc -o "$out" tests/artifacthook/main.swift \
  TallyCLI/HookArtifact.swift Tally/Core/ArtifactHookContract.swift \
  Tally/Core/RenewLoginCommand.swift \
  TallyCLI/Snapshot.swift TallyCLI/AccountHome.swift \
  TallyCLI/AccountReserveReader.swift Tally/Core/AccountReserve.swift \
  TallyCLI/ResumePrompt.swift TallyCLI/ProviderExecutable.swift
"$out"
