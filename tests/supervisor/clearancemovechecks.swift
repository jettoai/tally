import Foundation

// The clearance lane on the supervisor side (B-1360, TallyCLI/AccountComfort.swift). A window that
// `/clear` reopens is EMPTY, so it may take a clearance account (leftovers about to be lost to a
// weekly reset) the way a launch may, whatever the account it is leaving holds. A live conversation
// never may: the idle rebalance and the turn-boundary move still go through `capHandoffTarget`.
func runClearanceMoveChecks() {
    // Every clearance account below is empty unless a cell says otherwise (A14).
    let savedCounter = clearanceSessionCounter
    defer { clearanceSessionCounter = savedCounter }
    clearanceSessionCounter = { _ in 0 }
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
    clearanceSessionCounter = { $0 == "C" ? 2 : 0 }
    check("A14 a cleared window does not reopen on a full clearance account",
          repick(dying, [healthy, clearance]) == "B")
    check("A14 …nor does a comfortable one leave for it", repick(roomy, [healthy, clearance]) == nil)
    clearanceSessionCounter = { _ in 0 }
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
    func rebalance(_ candidates: [Snapshot.Account], on current: Snapshot.Account = dying)
        -> String? {
        rebalanceTarget(steering: true, mode: "auto", blocked: false, agentsWorking: false,
                        isQuiet: true, carryable: true, fuseAllows: true, current: current,
                        candidates: candidates, primaryModel: nil, now: launch)?.id
    }
    func turnBoundary(_ candidates: [Snapshot.Account], on current: Snapshot.Account = dying,
                      forecast: @escaping (Snapshot.Account) -> Double? = { _ in nil },
                      sessions: Int? = 1) -> String? {
        turnBoundaryTarget(steering: true, mode: "auto", blocked: false, keyboardIdle: true,
                           draftSuspected: false, carryable: true, fuseAllows: true,
                           agentsIdle: true, turnEnded: true, toolCallOpen: false,
                           current: current, candidates: candidates, primaryModel: nil,
                           now: launch, forecast: forecast, sessionsOnCurrent: sessions)?.id
    }
    check("A9 the idle rebalance does not move a conversation onto a clearance account",
          rebalance([clearance]) == nil && rebalance([clearance, healthy]) == "B")
    check("A9 the turn-boundary move does not move a conversation onto a clearance account",
          turnBoundary([clearance]) == nil && turnBoundary([clearance, healthy]) == "B")

    // AND A SESSION ALREADY ON ONE STAYS until its wall: the idle rebalance never takes it off,
    // and the turn-boundary move only once the burn forecast puts the wall within the early line,
    // so its few sessions leave at a turn end rather than walling mid-turn together.
    let wallIn7 = { (account: Snapshot.Account) -> Double? in account.id == "A" ? 7 : nil }
    check("a clearance account's idle session is not rebalanced away",
          rebalance([healthy], on: onClearance) == nil)
    check("a clearance account minutes from its wall moves at a turn boundary",
          turnBoundary([healthy], on: onClearance, forecast: wallIn7, sessions: 2) == "B")
    check("a clearance account far from its wall stays at a turn boundary",
          turnBoundary([healthy], on: onClearance, forecast: { $0.id == "A" ? 30 : nil },
                       sessions: 2) == nil
              && turnBoundary([healthy], on: onClearance, sessions: 2) == nil)
    // Only as many as the lane would have sent it stay: a crowd of five on a clearance account
    // (two of them clearance launches) moves like any other at a turn end, forecast or not.
    check("B1360-R4 five sessions on a clearance account with no forecast move at a turn boundary",
          turnBoundary([healthy], on: onClearance, sessions: 5) == "B")
    check("B1360-R4 …while two stay", turnBoundary([healthy], on: onClearance, sessions: 2) == nil)
    check("B1360-R4 …and a count nobody could read moves like a crowd",
          turnBoundary([healthy], on: onClearance, sessions: nil) == "B")
    // The clearance move ignores the target's own forecast: that filter is for an early move only.
    check("…and takes the cap handoff's target whatever that target's own forecast says",
          turnBoundary([healthy], on: onClearance,
                       forecast: { ["A": 7, "B": 30][$0.id] }, sessions: 2) == "B")

    // The station logs it as an early move on the clearance lane.
    let logDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("tally-clearancemove-\(UUID().uuidString)")
    let log = logDir.appendingPathComponent("handoff.log")
    var plan: RelaunchPlan?
    var state = TurnBoundaryState()
    applyTurnBoundaryMove(plan: &plan, state: &state, event: SessionTurnEnd(at: launch, sessionID: "s"),
                          steering: true, provider: "claude", account: onClearance,
                          primaryModel: nil, mode: "auto", blocked: false, keyboardIdle: true,
                          draftSuspected: false, carryable: true, fuseAllows: true,
                          agents: { _, _ in .idle }, turnEnded: true, toolCallOpen: false,
                          forecast: wallIn7, sessionsOnCurrent: { 2 },
                          log: log, quarantine: [:],
                          loaded: (Snapshot(version: 2, generatedAt: launch,
                                            accounts: [onClearance, healthy]), nil),
                          now: launch, dir: logDir.appendingPathComponent("claims"))
    let logged = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
    check("the station moves a clearance session minutes from its wall", plan?.target.id == "B")
    check("…and its early-move line says lane=clearance",
          logged.contains("early-move account=A minutes=7.0 sessions=2 lane=clearance"))
    try? FileManager.default.removeItem(at: logDir)
    // The exemption is the clearance rule and not "any dry account": 3% resetting in 30 hours is
    // not about to be lost, so both movers still carry it off.
    let dryFar = acct("A", weekly: 3, weeklyIn: 30)
    check("a 3% week resetting in 30 hours is still rebalanced away",
          rebalance([healthy], on: dryFar) == "B")
    check("…and still moved early at a turn boundary",
          turnBoundary([healthy], on: dryFar, forecast: wallIn7, sessions: 2) == "B")

    // THE TWO WIRES THE CHECKS ABOVE CANNOT REACH: every cell sets its own counter, so the entry
    // point that installs the real one and the supervisor's own reading are asserted as source.
    let entry = (try? String(contentsOfFile: "TallyCLI/main.swift", encoding: .utf8)) ?? ""
    let wired = entry.range(of: "\nwireClearanceSessionCounter()\n")
    check("B1360-R4 the CLI entry installs the clearance counter before it reads any argument",
          wired.map { $0.lowerBound < (entry.range(of: "\nlet arguments = ")?.lowerBound
                                         ?? entry.startIndex) } ?? false)
    let savedWire = clearanceSessionCounter
    clearanceSessionCounter = nil
    wireClearanceSessionCounter()
    check("B1360-R4 …and the installed counter reads the supervisors' state",
          clearanceSessionCounter != nil)
    clearanceSessionCounter = savedWire
    let loop = (try? String(contentsOfFile: "TallyCLI/Supervisor.swift", encoding: .utf8)) ?? ""
    check("B1360-R4 the supervisor hands the turn-boundary move the live count of its own account",
          loop.contains("sessionsOnCurrent: { liveSessionCount(onAccount: account.id) }"))
}
