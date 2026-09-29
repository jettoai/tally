import Foundation

// `tally status --json` passes the plan-weighted fields through untouched, and a snapshot from an
// app that predates them publishes no such keys (the contract is additive-only).
func capWeightStatusChecks() {
    let at = parseISO("2026-09-29T12:00:00Z")!
    let weighted = decodeSnapshot("""
    { "version": 2, "generatedAt": "2026-09-29T11:59:00Z", "accounts": [
      { "id": "codex:.codex", "provider": "codex", "label": "Codex", "plan": "Pro",
        "launchHome": "/Users/u/.codex", "isStale": false, "weeklyRemaining": 43 },
      { "id": "codex:.codex2", "provider": "codex", "label": "Codex 2", "plan": "Team",
        "launchHome": "/Users/u/.codex2", "isStale": false, "weeklyRemaining": 2 } ],
      "fleetPools": { "codex": [
        { "remaining": 43, "capacity": 100, "sustainable": true, "plan": "Pro",
          "capacityWeight": 5, "weightSource": "assumed" },
        { "remaining": 2, "capacity": 100, "sustainable": true, "plan": "Team",
          "capacityWeight": 1, "weightSource": "detected" } ] },
      "fleetWeighted": {
        "codex": { "remainingPercent": 36, "weightSource": "assumed" },
        "claude": { "remainingPercent": 70, "weightSource": "detected" } } }
    """)
    let top = parse(encodeStatusReport(statusReport(weighted, policies: [:], now: at)))
    let figures = top["fleetWeighted"] as? [String: [String: Any]]
    check("fleetWeighted: codex figure passes through",
          figures?["codex"]?["remainingPercent"] as? Double == 36
              && figures?["codex"]?["weightSource"] as? String == "assumed")
    check("fleetWeighted: a single-account provider is published too",
          figures?["claude"]?["remainingPercent"] as? Double == 70)
    let pools = (top["fleetPools"] as? [String: [[String: Any]]])?["codex"]
    check("fleetPools: each pool carries its plan weight",
          pools?.first?["capacityWeight"] as? Double == 5
              && pools?.first?["weightSource"] as? String == "assumed"
              && pools?.last?["capacityWeight"] as? Double == 1)

    let older = decodeSnapshot("""
    { "version": 2, "generatedAt": "2026-09-29T11:59:00Z", "accounts": [],
      "fleetPools": { "codex": [ { "remaining": 43, "capacity": 100, "sustainable": true } ] } }
    """)
    let old = parse(encodeStatusReport(statusReport(older, policies: [:], now: at)))
    check("older snapshot: no fleetWeighted key", old["fleetWeighted"] == nil)
    check("older snapshot: pools carry no capacityWeight",
          (old["fleetPools"] as? [String: [[String: Any]]])?["codex"]?.first?["capacityWeight"]
              == nil)
}
