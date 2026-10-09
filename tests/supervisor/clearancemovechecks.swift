import Foundation

// The clearance lane on the supervisor side (B-1360, TallyCLI/AccountComfort.swift). A window that
// `/clear` reopens is EMPTY, so it may take a clearance account (leftovers about to be lost to a
// weekly reset) the way a launch may, whatever the account it is leaving holds. A live conversation
// never may: the idle rebalance and the turn-boundary move still go through `capHandoffTarget`.
func runClearanceMoveChecks() {
    func acct(_ id: String, session: Double = 90, weekly: Double, weeklyIn hours: Double = 100)
        -> Snapshot.Account {
        Snapshot.Account(id: id, provider: "claude", label: id, launchHome: "/tmp/\(id)",
                         sessionRemaining: session, weeklyRemaining: weekly, modelRemaining: nil,
                         sessionResetsAt: launch.addingTimeInterval(4 * 3600),
                         weeklyResetsAt: launch.addingTimeInterval(hours * 3600),
                         modelResetsAt: nil, modelWindowName: nil, resetCreditsAvailable: nil,
                         isStale: false, error: nil)
    }
    let dying = acct("A", weekly: 3)                           // dry, but its reset is days away
    let roomy = acct("A", weekly: 60)                          // comfortable
    let healthy = acct("B", weekly: 77)
    let clearance = acct("C", weekly: 3, weeklyIn: 18)
    let clearance2 = acct("D", weekly: 4, weeklyIn: 20)
    let onClearance = acct("A", weekly: 3, weeklyIn: 18)

    func repick(_ current: Snapshot.Account, _ siblings: [Snapshot.Account]) -> String? {
        windowRepickMove(provider: "claude", account: current, primaryModel: nil, mode: "auto",
                         steering: true, carryable: true, fuseAllows: true,
                         loaded: (Snapshot(version: 2, generatedAt: launch,
                                           accounts: [current] + siblings), nil),
                         now: launch)?.id
    }
    check("A10 a cleared window on a dying account reopens on the clearance account",
          repick(dying, [healthy, clearance]) == "C")
    check("A11 a cleared window on a comfortable account still takes a clearance account",
          repick(roomy, [healthy, clearance]) == "C")
    check("A11 with no clearance account a comfortable account stays put",
          repick(roomy, [healthy]) == nil)
    check("the old path is intact: a dying account with no clearance sibling moves to a healthy one",
          repick(dying, [healthy]) == "B")
    check("a session already on a clearance account stays to spend it",
          repick(onClearance, [healthy, clearance2]) == nil)
    check("a pinned session is not repicked onto a clearance account either",
          windowRepickMove(provider: "claude", account: roomy, primaryModel: nil, mode: "manual",
                           steering: true, carryable: true, fuseAllows: true,
                           loaded: (Snapshot(version: 2, generatedAt: launch,
                                             accounts: [roomy, clearance]), nil),
                           now: launch) == nil)

    // A9: the movers of a LIVE conversation never take it.
    func rebalance(_ candidates: [Snapshot.Account]) -> String? {
        rebalanceTarget(steering: true, mode: "auto", blocked: false, agentsWorking: false,
                        isQuiet: true, carryable: true, fuseAllows: true, current: dying,
                        candidates: candidates, primaryModel: nil, now: launch)?.id
    }
    func turnBoundary(_ candidates: [Snapshot.Account]) -> String? {
        turnBoundaryTarget(steering: true, mode: "auto", blocked: false, keyboardIdle: true,
                           draftSuspected: false, carryable: true, fuseAllows: true,
                           agentsIdle: true, turnEnded: true, toolCallOpen: false, current: dying,
                           candidates: candidates, primaryModel: nil, now: launch)?.id
    }
    check("A9 the idle rebalance does not move a conversation onto a clearance account",
          rebalance([clearance]) == nil && rebalance([clearance, healthy]) == "B")
    check("A9 the turn-boundary move does not move a conversation onto a clearance account",
          turnBoundary([clearance]) == nil && turnBoundary([clearance, healthy]) == "B")
}
