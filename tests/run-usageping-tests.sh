#!/bin/bash
# UsagePing against a local 204 stand-in (tests/usageping/server.py): one request with the switch on,
# none with it off. Checks the wire shape the stand-in saw: POST /api/v1/ping, JSON content type, no
# Authorization header, exactly product/device/version, device a lowercase UUID v4. Built twice, the
# second time with TALLY_OVERLAY, which is how the private build reports tally-pro. No real network.
set -euo pipefail
cd "$(dirname "$0")/.."
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failed=0
for variant in "tally" "tally-pro -D TALLY_OVERLAY"; do
    set -- $variant
    product=$1; shift
    swiftc "$@" -o "$work/$product" \
        tests/usageping/main.swift Tally/Core/UsagePing.swift Tally/Core/BuildVariant.swift
    echo "== $product"
    python3 tests/usageping/server.py "$work/$product" "$product" || failed=1
done
exit $failed
