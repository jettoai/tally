import Foundation

// `tally status` for a window whose held-over figure predates a reset that already happened
// (HeldOverReset.swift). The JSON only gains `...ResetPassed` beside each `...ResetsAt`; the
// figure itself stays, because the contract is additive-only. The fixture is the 2026-09-28
// report at the moment it was made.
func resetPassedStatusChecks() {
    let reported = parseISO("2026-09-28T10:20:00Z")!
    let snapshot = decodeSnapshot("""
    { "version": 2, "generatedAt": "2026-09-28T10:19:00Z", "accounts": [
      { "id": "claude:.claude4", "provider": "claude", "label": "Claude 4",
        "launchHome": "/Users/u/.claude4", "isStale": true, "lastRefreshFailed": true,
        "error": "No usage data", "refreshedAt": "2026-09-28T08:56:00Z",
        "sessionRemaining": 0, "sessionResetsAt": "2026-09-28T09:10:00Z",
        "weeklyRemaining": 40, "weeklyResetsAt": "2026-10-01T12:00:00Z",
        "modelWindowName": "Fable", "modelRemaining": 30, "modelResetsAt": "2026-10-01T12:00:00Z" },
      { "id": "claude:.claude5", "provider": "claude", "label": "Claude 5",
        "launchHome": "/Users/u/.claude5", "isStale": false, "lastRefreshFailed": false,
        "refreshedAt": "2026-09-28T09:11:00Z",
        "sessionRemaining": 100, "sessionResetsAt": "2026-09-28T09:10:00Z" },
      { "id": "claude:.claude6", "provider": "claude", "label": "Claude 6",
        "launchHome": "/Users/u/.claude6", "isStale": true, "lastRefreshFailed": true,
        "refreshedAt": "2026-09-28T08:56:00Z",
        "sessionRemaining": 0, "sessionResetsAt": "2026-09-28T12:00:00Z" },
      { "id": "codex:.codex2", "provider": "codex", "label": "Codex 2",
        "launchHome": "/Users/u/.codex2", "isStale": false, "lastRefreshFailed": true,
        "refreshedAt": "2026-09-28T08:00:00Z",
        "weeklyRemaining": 3, "weeklyResetsAt": "2026-09-28T09:00:00Z" },
      { "id": "claude:.old", "provider": "claude", "label": "Old",
        "launchHome": "/Users/u/.old", "isStale": true,
        "sessionRemaining": 0, "sessionResetsAt": "2026-09-28T09:10:00Z" }
    ] }
    """)
    let json = parse(encodeStatusReport(statusReport(snapshot, policies: [:], now: reported)))
    let held = account(json, "claude:.claude4")
    check("reset passed: the reported window is flagged, the others are not",
          held["sessionResetPassed"] as? Bool == true && held["weeklyResetPassed"] as? Bool == false
              && held["modelResetPassed"] as? Bool == false)
    check("reset passed: the held-over figure itself is still published (additive only)",
          (held["sessionRemaining"] as? Double) == 0)
    check("reset passed: a fresh read after the reset is not flagged",
          account(json, "claude:.claude5")["sessionResetPassed"] as? Bool == false)
    check("reset passed: a held-over window whose reset is ahead is not flagged",
          account(json, "claude:.claude6")["sessionResetPassed"] as? Bool == false)
    let codex = account(json, "codex:.codex2")
    check("reset passed: a first failure counts, and a window with no reset has no key",
          codex["weeklyResetPassed"] as? Bool == true && codex["sessionResetPassed"] == nil)
    check("reset passed: an old snapshot with no read time reads as passed",
          account(json, "claude:.old")["sessionResetPassed"] as? Bool == true)
    let current = parse(encodeStatusReport(statusReport(decodeSnapshot(fixture), policies: [:], now: now)))
    check("reset passed: present as false wherever a reset instant is",
          account(current, "claude:.claude")["sessionResetPassed"] as? Bool == false)
    let row = snapshot.accounts.first { $0.id == "claude:.claude4" }!
    check("reset passed: the text line prints the window as unknown",
          row.statusFigure(row.sessionRemaining, resetsAt: row.sessionResetsAt, now: reported)
              == "? (reset passed)"
              && row.statusFigure(row.weeklyRemaining, resetsAt: row.weeklyResetsAt, now: reported) == "40%")
}
