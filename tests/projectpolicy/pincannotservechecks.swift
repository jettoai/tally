import Foundation

// A pin that cannot be read steps aside, but only on evidence that lasts (jettoai/tally#23).
//
// The invariant that keeps the launch and the pin switch from fighting: whatever `pinnedCannotServe`
// calls unservable, `eligible` refuses, so the pin switch never carries a session back to the
// account the launch just stepped away from. Asked over every combination of the five fields the
// predicate reads, plus the two snapshot generations that carry them.

func runPinCannotServeChecks() {
    var cells = 0, implied = 0, debounced = 0, debounceCells = 0
    for failed in [nil, false, true] as [Bool?] {
        for stale in [false, true] {
            for error in [nil, "x"] as [String?] {
                for keeps in [nil, false, true] as [Bool?] {
                    for rejected in [nil, false, true] as [Bool?] {
                        let row = Snapshot.Account(
                            id: "claude:P", provider: "claude", label: "P", launchHome: "/tmp/P",
                            sessionRemaining: 90, weeklyRemaining: 90, modelRemaining: nil,
                            sessionResetsAt: nil, weeklyResetsAt: nil, modelResetsAt: nil,
                            modelWindowName: nil, resetCreditsAvailable: nil, isStale: stale,
                            error: error, lastRefreshFailed: failed, pollsKeepFailing: keeps,
                            usageLoginRejected: rejected)
                        cells += 1
                        if !pinnedCannotServe(row) || !eligible(row) { implied += 1 }
                        // The debounce cell: this round failed and nothing says it has lasted.
                        if failed == true && !stale && error == nil && keeps != true && rejected != true {
                            debounceCells += 1
                            if !pinnedCannotServe(row) { debounced += 1 }
                        }
                    }
                }
            }
        }
    }
    check("every one of the 108 field combinations that cannot serve is also refused by `eligible` "
          + "(\(implied)/\(cells))", cells == 108 && implied == cells)
    check("a single failed round never reads as unable to serve (\(debounced)/\(debounceCells))",
          debounceCells > 0 && debounced == debounceCells)

    // The two snapshot generations. An app that predates the fields writes neither key and a CLI
    // reads nil; a new app writes both, false included, and an old CLI ignores them (it decodes by
    // key, so an extra one is not a failure: the schema only ever gains fields).
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    func decode(_ extra: String, stale: Bool = false) -> Snapshot.Account? {
        let json = """
        {"version":2,"generatedAt":"2026-11-15T00:00:00Z","accounts":[{"id":"claude:A","provider":"claude",
        "label":"A","isStale":\(stale)\(extra)}]}
        """
        return (try? decoder.decode(Snapshot.self, from: Data(json.utf8)))?.accounts.first
    }
    let old = decode("")
    check("a snapshot from an app without the fields still decodes, both read nil",
          old != nil && old?.pollsKeepFailing == nil && old?.usageLoginRejected == nil)
    let new = decode(#","pollsKeepFailing":true,"usageLoginRejected":false"#)
    check("a snapshot with the fields decodes them, false kept as false",
          new?.pollsKeepFailing == true && new?.usageLoginRejected == false)
    check("an old app's row that failed once is not unable to serve",
          decode(#","lastRefreshFailed":true"#).map { !pinnedCannotServe($0) } == true)
    check("an old app's row with only an error and no stale badge is not unable to serve",
          decode(#","error":"x""#).map { !pinnedCannotServe($0) } == true)
    check("an old app's stale, errored row is unable to serve, through the badge it does carry",
          decode(#","error":"x""#, stale: true).map(pinnedCannotServe) == true)
}
