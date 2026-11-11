import Foundation

// `tally status --json` passes a Claude account's limit-reset inventory through as the app
// published it (`limitResets*`, UsageSnapshot.swift). Additive only: an account the app never read,
// and every row of an older snapshot, carries none of the keys rather than an empty answer.
func limitResetStatusChecks() {
    let snapshot = decodeSnapshot("""
    { "version": 2, "generatedAt": "2026-07-23T11:55:00Z", "accounts": [
      { "id": "claude:.claude", "provider": "claude", "label": "Claude", "isStale": false,
        "limitResets": [
          { "kind": "full", "left": 1, "total": 1, "endsAt": "2026-12-10T22:00:00Z" },
          { "kind": "fable", "left": 1, "total": 1, "endsAt": "2027-03-09T07:59:00Z" } ],
        "limitResetsEligible": true, "limitResetsSource": "oauth",
        "limitResetsCheckedAt": "2026-07-23T11:50:00Z", "limitResetsStale": false },
      { "id": "claude:.claude2", "provider": "claude", "label": "Claude 2", "isStale": false,
        "limitResets": [], "limitResetsEligible": false, "limitResetsSource": "oauth",
        "limitResetsCheckedAt": "2026-07-23T11:40:00Z", "limitResetsStale": true },
      { "id": "claude:.claude3", "provider": "claude", "label": "Claude 3", "isStale": false }
    ] }
    """)
    let json = parse(encodeStatusReport(statusReport(snapshot, policies: [:], now: now)))
    let held = account(json, "claude:.claude")
    let resets = held["limitResets"] as? [[String: Any]] ?? []
    check("limit resets: each grant passes through with kind, counts and end",
          resets.count == 2 && resets[0]["kind"] as? String == "full" && resets[0]["left"] as? Int == 1
              && resets[0]["total"] as? Int == 1 && resets[0]["endsAt"] as? String == "2026-12-10T22:00:00Z"
              && resets[1]["kind"] as? String == "fable")
    check("limit resets: a grant carries exactly those four keys (no grant id)",
          resets.allSatisfy { Set($0.keys) == ["kind", "left", "total", "endsAt"] })
    check("limit resets: eligibility, source and read time pass through",
          held["limitResetsEligible"] as? Bool == true && held["limitResetsSource"] as? String == "oauth"
              && held["limitResetsCheckedAt"] as? String == "2026-07-23T11:50:00Z"
              && held["limitResetsStale"] as? Bool == false)
    let outside = account(json, "claude:.claude2")
    check("limit resets: an ineligible login publishes an empty list, held over when stale",
          (outside["limitResets"] as? [Any])?.isEmpty == true && outside["limitResetsEligible"] as? Bool == false
              && outside["limitResetsStale"] as? Bool == true)
    let unread = account(json, "claude:.claude3")
    check("limit resets: an account never read carries no limit-reset key at all",
          !unread.keys.contains { $0.hasPrefix("limitResets") })
    let old = parse(encodeStatusReport(statusReport(decodeSnapshot(fixture), policies: [:], now: now)))
    check("limit resets: an older snapshot adds no key to any row",
          accounts(old).allSatisfy { !$0.keys.contains { $0.hasPrefix("limitResets") } })
}
