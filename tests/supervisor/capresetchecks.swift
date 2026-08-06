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
          !capRecoveredByReset(pending(refreshed), now: launch.addingTimeInterval(400)))

    // Two windows equally empty is a real picture (an account holding a spent weekly under a spent
    // session window). The LATER reset is the one that ends the drought: clearing on the earlier
    // would stop the retry while the account is still capped on the other.
    let bothDry = [acct(session: 0, sessionResetsAt: launch.addingTimeInterval(300),
                        weekly: 0, weeklyResetsAt: launch.addingTimeInterval(900))]
    check("two windows equally empty wait for the later reset", !recovered(bothDry, at: 400))
    check("and clear once that one arrives too", recovered(bothDry, at: 900))
    check("the deadline is the later of the dry windows",
          deadline(bothDry) == launch.addingTimeInterval(900))

    // And they do not have to read as EQUALLY empty, which is the point of using the nearly-dry
    // line rather than an exact tie with the emptiest. The snapshot lags, so two windows that are
    // both really spent routinely come back as different numbers: locking onto the 1% window's
    // reset a few hours out would clear the badge while the 2% weekly stays empty for days.
    let laggedPair = [acct(session: 1, sessionResetsAt: launch.addingTimeInterval(300),
                           weekly: 2, weeklyResetsAt: launch.addingTimeInterval(50 * 3600))]
    check("two windows dry at different readings still wait for the later reset",
          deadline(laggedPair) == launch.addingTimeInterval(50 * 3600))
    check("so the near reset arriving does not clear it", !recovered(laggedPair, at: 400))
    check("and it clears only once the far one does", recovered(laggedPair, at: 50 * 3600 + 10))
    // The line is the shared one, not a new constant, and it is inclusive at the boundary. The
    // window ON the line holds the LATER reset here on purpose: dropping it has to change the
    // answer, or this asserts nothing about where the line falls.
    check("a window exactly on the nearly-dry line counts as dry",
          deadline([acct(session: nearlyDryPercent,
                         sessionResetsAt: launch.addingTimeInterval(900), weekly: 0,
                         weeklyResetsAt: launch.addingTimeInterval(300))])
          == launch.addingTimeInterval(900))
    check("and one above it is not part of the drought",
          deadline([acct(session: nearlyDryPercent + 0.1,
                         sessionResetsAt: launch.addingTimeInterval(900), weekly: 0,
                         weeklyResetsAt: launch.addingTimeInterval(300))])
          == launch.addingTimeInterval(300))
    check("an account with nothing dry at all names no deadline",
          deadline([acct(session: 50, weekly: 90)]) == nil)

    // A reset time older than the cap belongs to a window that was already spent when the session
    // hit the wall, or to a snapshot that has not moved since. Neither is a refill.
    check("a reset stamped hours before the cap is not the refill being waited on",
          deadline([acct(sessionResetsAt: launch.addingTimeInterval(-3 * 3600))]) == nil)
    // The bar is the cap's own instant (`TranscriptWatcher.capHitAt`), not the tick that noticed
    // it, so a reset landing a second later is a real refill rather than a stale stamp. Measuring
    // from the tick would put a whole poll interval of resets on the wrong side of this line, and
    // since the boundary is fixed once, being wrong here strands the session for good.
    check("a reset a second after the cap is still the refill being waited on",
          deadline([acct(sessionResetsAt: cappedAt.addingTimeInterval(1))])
          == cappedAt.addingTimeInterval(1))

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
    check("one dry window without a reset sinks the pair, rather than clearing on the other",
          deadline([acct(session: 0, sessionResetsAt: nil, weekly: 0)]) == nil)
    // Same rule, one step further in: a stale stamp must not be able to hide behind a sibling's
    // later reset. Taking the max alone would answer with the weekly's reset here, and the badge
    // would clear on a window this cap was never about while the session's own stays empty.
    check("a dry window with a stale reset sinks the pair too, however late its sibling resets",
          deadline([acct(session: 0, sessionResetsAt: launch.addingTimeInterval(-3 * 3600),
                         weekly: 0, weeklyResetsAt: launch.addingTimeInterval(900))]) == nil)
    check("a pending cap with no deadline never clears on one",
          !capRecoveredByReset(pending([acct(sessionResetsAt: nil)]), now: .distantFuture))

    // The judgment is the reset boundary, never how the numbers read. The snapshot lags a real cap
    // by minutes (which is why a capped account is quarantined rather than re-read), so an account
    // that already looks healthy is not evidence of anything: reading it as recovery would clear
    // the pending state on the very tick that raised it.
    check("an account that already reads healthy is not a recovery on its own",
          !recovered([acct(session: 100, sessionResetsAt: launch.addingTimeInterval(4 * 3600))],
                     at: 200))

    // Dryness is RAW remaining, not the comfort gate's effective remaining, which reads a window
    // minutes from resetting as already full: a session window at 0% five minutes from its reset
    // is exactly what this waits for, and the gate would have called it comfortable.
    check("the window that capped decides, not the one the comfort gate would call binding",
          deadline([acct(session: 0, sessionResetsAt: cappedAt.addingTimeInterval(60),
                         weekly: 90)]) == cappedAt.addingTimeInterval(60))

    // Windows are the ones the running model actually spends (`ratedWindows`): a flagship window
    // this session does not draw on is not what it capped on, so its reset is not the refill.
    let flagshipCapped = [acct(session: 90, sessionResetsAt: launch.addingTimeInterval(4 * 3600),
                               model: 0, modelResetsAt: launch.addingTimeInterval(300),
                               modelWindowName: "fable")]
    check("a flagship cap clears when that window resets",
          recovered(flagshipCapped, at: 400, model: "fable"))
    check("but a flagship window the session does not spend is not what it waits on",
          !recovered(flagshipCapped, at: 400, model: "sonnet"))

    // MARK: - 27b. The instant the cap is measured from

    // Real cap events carry their own timestamp (checked against this machine's transcripts,
    // 2026-07-31: every shape has one, from the full `apiErrorStatus`/`errorDetails` form down to
    // the bare one). None of them carries a machine-readable reset time, so the boundary still
    // comes from the snapshot; what the event gives is the moment the cap actually happened.
    func capLine(_ offset: TimeInterval, stamped: Bool = true) -> String {
        let ts = stamped ? #""timestamp":"\#(stamp(offset))","# : ""
        let body = #""message":{"content":"You've hit your session limit"}"#
        return #"{\#(ts)"isApiErrorMessage":true,\#(body)}"#
    }
    check("the cap's own timestamp is what the recovery is measured from",
          watcherAfterScanning([capLine(60)]).capHitAt == launch.addingTimeInterval(60))
    check("a cap event carrying no timestamp leaves the instant to the caller",
          watcherAfterScanning([capLine(60, stamped: false)]).capHitAt == nil)
    check("and a transcript with no cap at all names no instant",
          watcherAfterScanning([]).capHitAt == nil)

    // MARK: - 27c. The loop wiring

    // The decision is reachable in a test; its placement in the tick is not, so the source carries
    // it (the technique the rebalance, the follow dead end and the self-update fold all use). The
    // observation itself moved to CapDetection.swift when Supervisor.swift hit its size cap, so the
    // assertions follow the code rather than the file it used to live in; the tick's own half is
    // that it still runs BEFORE any planner, which is the part only the loop can show.
    let loop = (try? String(contentsOfFile: "TallyCLI/Supervisor.swift", encoding: .utf8)) ?? ""
    let capSource = (try? String(contentsOfFile: "TallyCLI/CapDetection.swift",
                                 encoding: .utf8)) ?? ""
    check("the supervisor and cap sources are readable from the cap reset checks",
          !loop.isEmpty && !capSource.isEmpty)
    check("the tick asks whether the reset it was waiting for has arrived",
          capSource.contains("capRecoveredByReset(pending, now: now)"))
    // OR, not instead of: a session whose user came back mid-window still clears on the turn.
    check("the assistant-turn arm is still there",
          capSource.contains("watcher.lastMainChainEventAt.map({ $0 > pending.cappedAt }) == true"))
    check("and the reset arm is an alternative to it, not a replacement",
          capSource.contains("|| capRecoveredByReset(pending, now: now)"))
    // The boundary is taken where the cap is RECORDED, against the same instant the cap is stamped
    // with. Deriving it anywhere later is the race this shape closes, so the tick must not be
    // handing this function a snapshot at all.
    check("the boundary is fixed where the pending cap is created",
          capSource.contains("recoveryResetsAt: capRecoveryDeadline("))
    check("against the moment the cap itself was stamped with",
          capSource.contains("primaryModel: primaryModel, cappedAt: cappedAt)"))
    check("and the clearing tick re-derives nothing from the live snapshot",
          !capSource.contains("capRecoveredByReset(pending, accounts:"))
    // Measured from the cap event, not from the tick that noticed it: one poll interval of resets
    // sits between those two answers, and the boundary is only ever decided once.
    check("the cap is stamped with its own instant, not the poll's",
          capSource.contains("let cappedAt = watcher.capHitAt ?? now"))
    // The placement that made all of it work: the scan happens before anything can plan a relaunch,
    // because a relaunch resets the watcher's `since` and the cap event would be read as history.
    if let observe = loop.range(of: "observeCapHit("),
       let firstPlanner = loop.range(of: "applyManualMoves(") {
        check("the cap scan runs before the first planner in the tick",
              observe.lowerBound < firstPlanner.lowerBound)
    } else {
        check("the cap scan and the first planner are both in the tick", false)
    }
}
