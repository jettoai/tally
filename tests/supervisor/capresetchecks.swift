import Foundation

// Clearing a pending cap when the window that capped has reset, split out of main.swift for file
// size. Top-level statements can only live in main.swift, so these run as one function it calls;
// the harness (`check`, `failures`) and the fixed `launch` date are shared from there.
//
// The defect under test: the only clear path used to be an assistant turn on the main chain newer
// than the cap, which needs a user who types. A session left open while its account refilled had
// nothing to produce one, so the status line kept painting "no account with quota to spare" for
// hours (five sessions at 01:15, 2026-07-31, on an account whose window had reset at 00:59). The
// handoff's candidate list cannot notice it either: it excludes the account the session is on.

func runCapResetChecks() {
    // MARK: - 27. The window that capped has reset

    let cappedAt = launch.addingTimeInterval(100)
    /// The cap this session is waiting out. Only `cappedAccountID` and `primaryModel` steer the
    /// decision; the backoff and the note belong to the handoff attempt.
    func pending(account: String = "A", model: String? = nil) -> PendingCapRecovery {
        PendingCapRecovery(cappedAccountID: account, cappedAt: cappedAt, primaryModel: model,
                           nextRetry: .distantPast, reason: "")
    }
    /// An account whose SESSION window is the spent one, so its reset is the one being waited on.
    /// The weekly stays healthy and far out, as it is on a five-hour cap.
    func acct(_ id: String = "A", session: Double? = 0,
              sessionResetsAt: Date? = launch.addingTimeInterval(300),
              weekly: Double? = 90, model: Double? = nil,
              modelResetsAt: Date? = nil, modelWindowName: String? = nil) -> Snapshot.Account {
        Snapshot.Account(id: id, provider: "claude", label: id, launchHome: "/tmp/\(id)",
                         sessionRemaining: session, weeklyRemaining: weekly, modelRemaining: model,
                         sessionResetsAt: sessionResetsAt,
                         weeklyResetsAt: launch.addingTimeInterval(100 * 3600),
                         modelResetsAt: modelResetsAt, modelWindowName: modelWindowName,
                         resetCreditsAvailable: nil, isStale: false, error: nil)
    }
    func recovered(_ accounts: [Snapshot.Account], at offset: TimeInterval,
                   pending waiting: PendingCapRecovery = pending()) -> Bool {
        capRecoveredByReset(waiting, accounts: accounts, now: launch.addingTimeInterval(offset))
    }

    // The move this whole path exists for: the reset the session was waiting on has come and gone,
    // so there is nothing left to wait for and the badge goes.
    check("a cap whose window has since reset is over", recovered([acct()], at: 400))
    check("a reset landing exactly now already counts", recovered([acct()], at: 300))

    // Still inside the window: the session is as capped as it was a minute ago.
    check("a cap whose window has not reset yet is still pending", !recovered([acct()], at: 200))

    // A reset time older than the cap belongs to a window that was already spent when the session
    // hit the wall, or to a snapshot that has not moved since. Neither is a refill.
    check("a reset stamped before the cap is not the refill being waited on",
          !recovered([acct(sessionResetsAt: launch.addingTimeInterval(50))], at: 400))

    // Conservative wherever the picture is incomplete: clearing early stops the retry that hands
    // the session to a sibling, and claims a recovery that has not happened.
    check("an account missing from the snapshot clears nothing", !recovered([acct("B")], at: 400))
    check("an empty snapshot clears nothing", !recovered([], at: 400))
    check("an account reporting no windows clears nothing",
          !recovered([acct(session: nil, weekly: nil)], at: 400))
    check("a binding window with no known reset clears nothing",
          !recovered([acct(sessionResetsAt: nil)], at: 400))

    // The judgment is the reset boundary, never how the numbers read. The snapshot lags a real cap
    // by minutes (which is why a capped account is quarantined rather than re-read), so an account
    // that already looks healthy is not evidence of anything: reading it as recovery would clear
    // the pending state on the very tick that raised it.
    check("an account that already reads healthy is not a recovery on its own",
          !recovered([acct(session: 100, sessionResetsAt: launch.addingTimeInterval(4 * 3600))],
                     at: 200))

    // The window waited on is the emptiest by RAW remaining, not by the comfort gate's effective
    // remaining. Past its reset the spent window reads as fully refilled to that gate, so the
    // weekly at 90% would become the "binding" one and this would sit waiting on a reset 100 hours
    // out while the session window it actually capped on had already come back.
    check("the window that capped decides, not the one the comfort gate would call binding",
          recovered([acct(session: 0, weekly: 90)], at: 400))

    // Windows are the ones the running model actually spends (`ratedWindows`): a flagship window
    // this session does not draw on is not what it capped on, so its reset is not the refill.
    let flagshipCapped = acct(session: 90, sessionResetsAt: launch.addingTimeInterval(4 * 3600),
                              model: 0, modelResetsAt: launch.addingTimeInterval(300),
                              modelWindowName: "fable")
    check("a flagship cap clears when that window resets",
          recovered([flagshipCapped], at: 400, pending: pending(model: "fable")))
    check("but a flagship window the session does not spend is not what it waits on",
          !recovered([flagshipCapped], at: 400, pending: pending(model: "sonnet")))

    // MARK: - 27b. The loop wiring

    // The decision is reachable in a test; its placement in the tick is not, so the source carries
    // it (the technique the rebalance, the follow dead end and the self-update fold all use).
    let loop = (try? String(contentsOfFile: "TallyCLI/Supervisor.swift", encoding: .utf8)) ?? ""
    check("the supervisor source is readable from the cap reset checks", !loop.isEmpty)
    check("the tick asks whether the capped window has reset",
          loop.contains("capRecoveredByReset("))
    // OR, not instead of: a session whose user came back mid-window still clears on the turn.
    check("the assistant-turn arm is still there",
          loop.contains("watcher.lastMainChainEventAt.map({ $0 > pending.cappedAt }) == true"))
    check("and the reset arm is an alternative to it, not a replacement",
          loop.contains("|| capRecoveredByReset(pending, accounts:"))
    // Read inline in the guarded condition, and second: an ordinary tick has no pending cap, and a
    // tick whose session just answered short-circuits before the file is touched.
    check("the snapshot is only read while a cap is actually pending",
          loop.contains("capRecoveredByReset(pending, accounts: loadSnapshot().0?.accounts ?? [])"))
}
