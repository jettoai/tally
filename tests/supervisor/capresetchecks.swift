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
//
// The boundary is therefore captured at the moment of the cap and never recomputed. The app
// refreshes the snapshot every minute, and that refresh erases the evidence a recomputing check
// would need: the window that capped reads 100% again and its reset jumps a cycle ahead.

func runCapResetChecks() {
    // MARK: - 27. The reset this cap is waiting for

    let cappedAt = launch.addingTimeInterval(100)
    /// An account whose SESSION window is the spent one, so its reset is the one being waited on.
    /// The weekly stays healthy and far out, as it is on a five-hour cap.
    func acct(_ id: String = "A", session: Double? = 0,
              sessionResetsAt: Date? = launch.addingTimeInterval(300),
              weekly: Double? = 90, weeklyResetsAt: Date? = launch.addingTimeInterval(100 * 3600),
              model: Double? = nil, modelResetsAt: Date? = nil,
              modelWindowName: String? = nil) -> Snapshot.Account {
        Snapshot.Account(id: id, provider: "claude", label: id, launchHome: "/tmp/\(id)",
                         sessionRemaining: session, weeklyRemaining: weekly, modelRemaining: model,
                         sessionResetsAt: sessionResetsAt, weeklyResetsAt: weeklyResetsAt,
                         modelResetsAt: modelResetsAt, modelWindowName: modelWindowName,
                         resetCreditsAvailable: nil, isStale: false, error: nil)
    }
    /// The boundary this cap will wait for, read off the snapshot as it stood when the cap landed.
    func deadline(_ accounts: [Snapshot.Account], account: String = "A",
                  model: String? = nil) -> Date? {
        capRecoveryDeadline(accounts: accounts, cappedAccountID: account, primaryModel: model,
                            cappedAt: cappedAt)
    }
    /// The pending state a cap on `accounts` produces, exactly as the loop builds it.
    func pending(_ accounts: [Snapshot.Account], account: String = "A",
                 model: String? = nil) -> PendingCapRecovery {
        PendingCapRecovery(cappedAccountID: account, cappedAt: cappedAt, primaryModel: model,
                           recoveryResetsAt: deadline(accounts, account: account, model: model),
                           nextRetry: .distantPast, reason: "")
    }
    func recovered(_ accounts: [Snapshot.Account], at offset: TimeInterval,
                   account: String = "A", model: String? = nil) -> Bool {
        capRecoveredByReset(pending(accounts, account: account, model: model),
                            now: launch.addingTimeInterval(offset))
    }

    // The move this whole path exists for: the reset the session was waiting on has come and gone,
    // so there is nothing left to wait for and the badge goes.
    check("a cap whose window has since reset is over", recovered([acct()], at: 400))
    check("a reset landing exactly now already counts", recovered([acct()], at: 300))

    // Still inside the window: the session is as capped as it was a minute ago.
    check("a cap whose window has not reset yet is still pending", !recovered([acct()], at: 200))

    // THE RACE THIS SHAPE EXISTS FOR: the app refreshes the snapshot every minute, and the refresh
    // puts the window that capped back at 100% with its reset moved a cycle ahead. Anything that
    // re-derived the boundary from the live snapshot would from then on find some healthy window
    // whose reset is still ahead and answer "not yet" forever, so it could only ever fire inside
    // the gap between the reset and the next refresh. The boundary is captured once, so a refresh
    // erasing the evidence changes nothing.
    let refreshed = [acct(session: 100, sessionResetsAt: launch.addingTimeInterval(5 * 3600))]
    let capState = pending([acct()])   // captured while the window still read 0%
    check("a snapshot refresh that erases the evidence does not strand the pending cap",
          capRecoveredByReset(capState, now: launch.addingTimeInterval(400)))
    check("and re-deriving it from the refreshed snapshot is what would have stranded it",
          deadline(refreshed).map { $0 > launch.addingTimeInterval(400) } == true)

    // Two windows equally empty is a real picture (an account holding a spent weekly under a spent
    // session window). The LATER reset is the one that ends the drought: clearing on the earlier
    // would stop the retry while the account is still capped on the other.
    let bothDry = [acct(session: 0, sessionResetsAt: launch.addingTimeInterval(300),
                        weekly: 0, weeklyResetsAt: launch.addingTimeInterval(900))]
    check("two windows equally empty wait for the later reset", !recovered(bothDry, at: 400))
    check("and clear once that one arrives too", recovered(bothDry, at: 900))
    check("the deadline is the later of the tied windows",
          deadline(bothDry) == launch.addingTimeInterval(900))

    // A reset time older than the cap belongs to a window that was already spent when the session
    // hit the wall, or to a snapshot that has not moved since. Neither is a refill.
    check("a reset stamped before the cap is not the refill being waited on",
          !recovered([acct(sessionResetsAt: launch.addingTimeInterval(50))], at: 400))

    // Conservative wherever the picture is incomplete: clearing early stops the retry that hands
    // the session to a sibling, and claims a recovery that has not happened. Each of these leaves
    // the session on the assistant-turn path alone, which is where it was before this existed.
    check("an account missing from the snapshot names no deadline", deadline([acct("B")]) == nil)
    check("and never clears on one", !recovered([acct("B")], at: 400))
    check("an empty snapshot names no deadline", deadline([]) == nil)
    check("an account reporting no windows names no deadline",
          deadline([acct(session: nil, weekly: nil)]) == nil)
    check("a window with no known reset names no deadline",
          deadline([acct(sessionResetsAt: nil)]) == nil)
    check("one tied window without a reset sinks the pair, rather than clearing on the other",
          deadline([acct(session: 0, sessionResetsAt: nil, weekly: 0)]) == nil)
    check("a pending cap with no deadline never clears on one",
          !capRecoveredByReset(pending([acct(sessionResetsAt: nil)]), now: .distantFuture))

    // The judgment is the reset boundary, never how the numbers read. The snapshot lags a real cap
    // by minutes (which is why a capped account is quarantined rather than re-read), so an account
    // that already looks healthy is not evidence of anything: reading it as recovery would clear
    // the pending state on the very tick that raised it.
    check("an account that already reads healthy is not a recovery on its own",
          !recovered([acct(session: 100, sessionResetsAt: launch.addingTimeInterval(4 * 3600))],
                     at: 200))

    // The window waited on is the emptiest by RAW remaining, not by the comfort gate's effective
    // remaining, which reads a window minutes from resetting as already full and would name a
    // window this session never capped on: the weekly at 90%, resetting 100 hours out.
    check("the window that capped decides, not the one the comfort gate would call binding",
          deadline([acct(session: 0, weekly: 90)]) == launch.addingTimeInterval(300))

    // Windows are the ones the running model actually spends (`ratedWindows`): a flagship window
    // this session does not draw on is not what it capped on, so its reset is not the refill.
    let flagshipCapped = [acct(session: 90, sessionResetsAt: launch.addingTimeInterval(4 * 3600),
                               model: 0, modelResetsAt: launch.addingTimeInterval(300),
                               modelWindowName: "fable")]
    check("a flagship cap clears when that window resets",
          recovered(flagshipCapped, at: 400, model: "fable"))
    check("but a flagship window the session does not spend is not what it waits on",
          !recovered(flagshipCapped, at: 400, model: "sonnet"))

    // MARK: - 27b. The loop wiring

    // The decision is reachable in a test; its placement in the tick is not, so the source carries
    // it (the technique the rebalance, the follow dead end and the self-update fold all use).
    let loop = (try? String(contentsOfFile: "TallyCLI/Supervisor.swift", encoding: .utf8)) ?? ""
    check("the supervisor source is readable from the cap reset checks", !loop.isEmpty)
    check("the tick asks whether the reset it was waiting for has arrived",
          loop.contains("capRecoveredByReset(pending)"))
    // OR, not instead of: a session whose user came back mid-window still clears on the turn.
    check("the assistant-turn arm is still there",
          loop.contains("watcher.lastMainChainEventAt.map({ $0 > pending.cappedAt }) == true"))
    check("and the reset arm is an alternative to it, not a replacement",
          loop.contains("|| capRecoveredByReset(pending)"))
    // The boundary is taken where the cap is RECORDED, against the same instant the cap is stamped
    // with. Deriving it anywhere later is the race this shape closes, so the tick must not be
    // handing this function a snapshot at all.
    check("the boundary is fixed where the pending cap is created",
          loop.contains("recoveryResetsAt: capRecoveryDeadline("))
    check("against the moment the cap itself was stamped with",
          loop.contains("primaryModel: capModel, cappedAt: cappedAt)"))
    check("and the clearing tick re-derives nothing from the live snapshot",
          !loop.contains("capRecoveredByReset(pending, accounts:"))
}
