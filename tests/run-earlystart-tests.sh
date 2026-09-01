#!/bin/bash
# Compiles the early-start decision layer (Tally/Core/EarlyStart.swift, its persisted shapes in
# EarlyStartState.swift and its silence window in EarlyStartQuietHours.swift) and the shape of the
# spawn it produces (Tally/Core/EarlyStartCommand.swift) together with a small assertion harness,
# and runs it. The command builder shares the default-home rule with the renewal path, and it reads
# the normalized account types, so those two files come along; no Xcode target is needed. Exits
# non-zero on failure.
set -euo pipefail
cd "$(dirname "$0")/.."
out=$(mktemp -d)/run
# AND THE STORE ITSELF (Tally/Stores/EarlyStartStore.swift), which no suite compiled until now: its
# rules were held by reading its source as text, and a text lock cannot tell a rule from a sentence
# about one. Typechecked against the rest of the feature the store needs exactly one symbol this
# suite does not carry - `UsageStore`, on the line that asks for a refresh - and that one is stood in
# for (tests/earlystart/storeharness.swift). Everything else on the line below is the app's own
# source: the settings the plan is filtered by, the CLI resolution the spawn gate asks, the build
# variant that decides whether this process may send at all, and the demo fixtures that gate reads.
# The file list is longer for it, and what it buys is the difference between asserting the store and
# asserting a paragraph about the store.
swiftc -o "$out" tests/earlystart/main.swift tests/earlystart/quiethourschecks.swift \
    tests/earlystart/relaychecks.swift tests/earlystart/statechecks.swift \
    tests/earlystart/spawnchecks.swift tests/earlystart/storechecks.swift \
    tests/earlystart/storeharness.swift Tally/Core/EarlyStart.swift \
    Tally/Core/EarlyStartState.swift Tally/Core/EarlyStartQuietHours.swift \
    Tally/Core/EarlyStartCommand.swift Tally/Core/RenewLoginCommand.swift \
    Tally/Providers/ProviderModels.swift Tally/Stores/EarlyStartStore.swift \
    Tally/Core/BuildVariant.swift Tally/Core/CLIRunner.swift Tally/Core/ProviderCLI.swift
"$out"
