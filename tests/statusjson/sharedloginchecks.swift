import Foundation

// jettoai/tally#6: two homes on one Claude login. The CLI reads the app's `sameAccountAs`, an older
// snapshot reads nil, and the kept row's human status line names the duplicate.
func sharedLoginStatusChecks() {
    let sharedJSON = decodeSnapshot("""
    { "version": 2, "generatedAt": "2026-10-10T12:00:00Z", "accounts": [
      { "id": "claude:.claude-am", "provider": "claude", "label": "AM", "isStale": false,
        "error": "AM and GM are signed into the same Claude account", "sameAccountAs": "claude:.claude-gm" },
      { "id": "claude:.claude-gm", "provider": "claude", "label": "GM", "isStale": false,
        "launchHome": "/tmp/gm", "weeklyRemaining": 98 } ] }
    """)
    check("#6 the CLI decodes sameAccountAs", sharedJSON.accounts.first?.sameAccountAs == "claude:.claude-gm")
    check("#6 …an older snapshot without it decodes nil",
          snapshot.accounts.allSatisfy { $0.sameAccountAs == nil })
    check("#6 the kept row's status line names the duplicate",
          sharedLoginSuffix(sharedJSON.accounts[1], in: sharedJSON.accounts) == " (shared with AM)")
    check("#6 …and the duplicate's own line adds nothing (its error already names both)",
          sharedLoginSuffix(sharedJSON.accounts[0], in: sharedJSON.accounts).isEmpty)
    check("#6 the advisor's live set leaves the duplicate out",
          advisorLiveAccounts(sharedJSON) == ["claude:.claude-gm"])
}
