import Foundation

// What a hard cap does to a session its user pinned BY HAND, which is the one crossing between the
// account axis and the model axis: `tally switch` says where this conversation belongs, a cap says
// this account cannot answer right now, and the two have to be resolved into one relaunch.
//
// Split out of sessionpinchecks.swift at that file's size cap. The seam is the one the sections
// already had: everything here is about the CAP reading a pin (31k, 31k2, 31k3), and everything
// left there is about the pin itself - how a `tally switch` creates one, what stops honouring
// quota reasoning while it stands, and how it survives a self-update.

func runCapSessionPinChecks() {
    // The fixtures the moved sections were written against, in the shapes sessionpinchecks.swift
    // builds them: a fleet with no opinion about where sessions run, and accounts differing only in
    // how much of the flagship window is left.
    var auto0 = LaunchPolicy()
    auto0.mode = "auto"
    let dyingNow = Date(timeIntervalSince1970: 1_800_000_000)
    /// `refreshedAt` defaults to one second AFTER the cap these sections are written around, which
    /// is the ordinary case: the app fetched, then the session hit the wall, then a tick read it.
    /// The cases that turn on the stamp hand in their own.
    func account(_ id: String, model: Double,
                 refreshedAt: Date? = dyingNow.addingTimeInterval(1)) -> Snapshot.Account {
        Snapshot.Account(id: id, provider: "claude", label: id, launchHome: "/tmp/\(id)",
                         sessionRemaining: 90, weeklyRemaining: 90, modelRemaining: model,
                         sessionResetsAt: dyingNow.addingTimeInterval(4 * 3600),
                         weeklyResetsAt: dyingNow.addingTimeInterval(100 * 3600),
                         modelResetsAt: dyingNow.addingTimeInterval(100 * 3600),
                         modelWindowName: "fable", resetCreditsAvailable: nil, isStale: false,
                         error: nil, refreshedAt: refreshedAt)
    }

    // MARK: - 31k. The cap is the one way out that nobody asked for

    var capped = ManualMoveState(sessionKey: "cap", servedEpoch: 0, sessionPin: "D")
    check("a reload restart never reaches the pin", !capped.pinCleared(by: "reload"))
    check("nor does the pairing a cap answers in place", !capped.pinCleared(by: "cap-fallback"))
    check("nor a self-update, a safeguard restore or a fallback profile",
          !capped.pinCleared(by: "self-update") && !capped.pinCleared(by: "safeguard")
              && !capped.pinCleared(by: "fallback"))
    check("and neither does the move the user asked for by hand",
          !capped.pinCleared(by: "switch") && !capped.pinCleared(by: "pin"))
    check("and the pin is still there afterwards", capped.sessionPin == "D")
    check("a cap handoff clears it", capped.pinCleared(by: "cap"))
    check("…so the session is not dragged back to a capped account", capped.sessionPin == nil)
    check("and it is only news once", !capped.pinCleared(by: "cap"))
    var unpinned = ManualMoveState(sessionKey: "cap", servedEpoch: 0)
    check("an unpinned session's cap handoff is not a pin clearance",
          !unpinned.pinCleared(by: "cap"))
    check("the user is told how to get the pin back",
          sessionPinClearedByCapNotice.contains("tally account")
              && sessionPinClearedByCapNotice.contains("cap"))

    // AND THE PREVENTIVE MOVERS REACH IT TOO, since 2026-08-21: they are released onto an account
    // with nothing left (DroughtWatch.swift), and a move that happens has to end the pin for the
    // same reason a cap's does - otherwise the pin switch drags the session straight back onto the
    // account it was just carried off.
    for reason in ["rebalance", "window-repick", turnBoundaryReason, "degraded"] {
        var pinned = ManualMoveState(sessionKey: "cap", servedEpoch: 0, sessionPin: "D")
        check("a \(reason) that got past the pin ends it",
              pinned.pinCleared(by: reason) && pinned.sessionPin == nil)
        check("…and says which kind of move took it",
              handoffReason(reason, pinCleared: true) == "pin-cleared-\(reason)")
    }
    check("what a drought clears is not described as a cap", {
        let said = sessionPinClearedNotice(reason: "rebalance")
        return said.contains("out of quota") && !said.contains("cap hit")
            && said.contains("tally account")
    }())

    // …and the cap has to be able to REACH that clearance, which is the hole this section is really
    // about: with a project or panel pin already in force, asking `capRecoveryAction` about the
    // session's own policy answers `.waitPinned` for ever, no plan is ever built, `pinCleared(by:)`
    // is never called, and the session sits on a dry account it cannot work on (review, 2026-08-06).
    let capNow = Date(timeIntervalSince1970: 1_800_000_000)
    let capped0 = account("D", model: 0.5)      // where the session is, and where it just capped
    let fleetPinned = account("P", model: 60)   // what the project/panel pin names
    let sibling = account("S", model: 80)       // what a pick of its own would choose
    var pinnedToP = LaunchPolicy()
    pinnedToP.mode = "manual"
    pinnedToP.pinnedAccountID = "P"

    /// The defaulted arguments are the case this section opened with; 31k2 below varies them (the
    /// session's model pin, what it runs, the account it capped on, a snapshot that says it is too
    /// old to judge by) rather than keeping a second tick of its own.
    func capTick(fleet: LaunchPolicy, sessionPin: String?, modelPinned: Bool = false,
                 steering: Bool = true,
                 primary: String? = "fable", on: Snapshot.Account = capped0,
                 accounts: [Snapshot.Account] = [capped0, fleetPinned, sibling],
                 problem: String? = nil, generatedAt: Date = capNow, now: Date = capNow)
        -> (plan: RelaunchPlan?, pending: PendingCapRecovery?) {
        var plan: RelaunchPlan?
        var pending: PendingCapRecovery? = PendingCapRecovery(
            cappedAccountID: on.id, cappedAt: capNow, primaryModel: primary,
            recoveryResetsAt: nil, nextRetry: .distantPast, reason: "")
        applyCapHandoff(plan: &plan, pendingCap: &pending, account: on, providerID: "claude",
                        fleet: fleet, steering: steering, sessionPin: sessionPin,
                        modelPinned: modelPinned,
                        quarantine: [:], fuseAllows: true, now: now,
                        loaded: (Snapshot(version: 2, generatedAt: generatedAt, accounts: accounts),
                                 problem))
        return (plan, pending)
    }

    // Before any of that: the tick that has nothing to do must not pay for the decision. A plain
    // default argument is evaluated at the CALL, so the snapshot was being read and JSON-decoded on
    // every 2s tick of every supervised session for a branch that almost never runs (review,
    // 2026-08-06); `@autoclosure` moves that read behind the guard.
    var snapshotReads = 0
    func countedSnapshot() -> (Snapshot?, String?) {
        snapshotReads += 1
        return (Snapshot(version: 2, generatedAt: capNow, accounts: [capped0, sibling]), nil)
    }
    var idlePlan: RelaunchPlan?
    var noCap: PendingCapRecovery?
    applyCapHandoff(plan: &idlePlan, pendingCap: &noCap, account: capped0, providerID: "claude",
                    fleet: auto0, steering: true, sessionPin: nil, quarantine: [:],
                    fuseAllows: true, now: capNow,
                    loaded: countedSnapshot())
    check("a tick with no pending cap reads no snapshot at all", snapshotReads == 0)
    var pendingNow: PendingCapRecovery? = PendingCapRecovery(
        cappedAccountID: "D", cappedAt: capNow, primaryModel: "fable", recoveryResetsAt: nil,
        nextRetry: .distantPast, reason: "")
    applyCapHandoff(plan: &idlePlan, pendingCap: &pendingNow, account: capped0,
                    providerID: "claude", fleet: auto0, steering: true, sessionPin: nil,
                    quarantine: [:],
                    fuseAllows: true, now: capNow, loaded: countedSnapshot())
    check("and the tick that has a cap to answer reads it exactly once", snapshotReads == 1)

    // The bug, end to end: both pins in force, and the session gets out.
    let bothPins = capTick(fleet: pinnedToP, sessionPin: "D")
    check("a cap moves a session pinned over a fleet pin", bothPins.plan != nil)
    check("…to the account the fleet pin names, which is where the pin says it belongs",
          bothPins.plan?.target.id == "P")
    check("…tagged as a cap, so the clearance and the audit line follow from it",
          bothPins.plan?.reason == "cap")
    var pinnedSession = ManualMoveState(sessionKey: "capped", servedEpoch: 0, sessionPin: "D")
    check("and that plan is what ends the session pin",
          pinnedSession.pinCleared(by: bothPins.plan?.reason ?? "")
              && pinnedSession.sessionPin == nil)
    check("which the log then names for what it was",
          handoffReason(bothPins.plan?.reason ?? "", pinCleared: true) == "pin-cleared-cap")

    // A session pin with nothing under it picks for itself, as it did before.
    let onlySession = capTick(fleet: auto0, sessionPin: "D")
    check("with no fleet pin under it, the cap picks the best sibling",
          onlySession.plan?.target.id == "S")

    // Untouched: a FLEET-pinned session with no pin of its own still waits, because nothing is
    // clearing that pin and staying put is what pinning means.
    let fleetOnly = capTick(fleet: pinnedToP, sessionPin: nil)
    check("a fleet-pinned session with no session pin still stays put", fleetOnly.plan == nil)
    check("…and says why", fleetOnly.pending?.reason.contains("pinned in Tally") == true)

    // The fleet pin cannot be honoured (drained, so not a candidate at all): waiting again, and
    // deliberately. Moving anywhere else would be undone within seconds - the pin switch asks only
    // whether an account is launchable, not whether it has quota, so it would drag the session
    // straight back onto the pinned account and the cap would fire again there.
    let deadEnd = capTick(fleet: pinnedToP, sessionPin: "D",
                          accounts: [capped0, account("P", model: 0), sibling])
    check("a fleet pin that cannot take the session keeps it where it is", deadEnd.plan == nil)
    check("…rather than moving it somewhere the pin would undo",
          deadEnd.pending?.reason.contains("pinned in Tally") == true)

    // The rule those four cases come from, on its own.
    let candidates = [fleetPinned, sibling]
    check("no session pin leaves the fleet's own mode alone",
          capReading(fleet: pinnedToP, sessionPin: nil, candidates: candidates).mode == "manual")
    check("a session pin alone lets the cap decide",
          capReading(fleet: auto0, sessionPin: "D", candidates: candidates).mode == "auto")
    check("a session pin over a fleet pin lands on the fleet's account", {
        let reading = capReading(fleet: pinnedToP, sessionPin: "D", candidates: candidates)
        return reading.mode == "auto" && reading.preferred?.id == "P"
    }())
    check("a fleet pin outside the candidates is a wait, not a free pick", {
        let reading = capReading(fleet: pinnedToP, sessionPin: "D", candidates: [sibling])
        return reading.mode == "manual" && reading.preferred == nil
    }())

    // MARK: - 31k2. A cap on a hand-pinned session tries to stay before it moves

    // The owner report this section is about (2026-08-07): a session moved onto an account by hand
    // capped there, and the handoff above cleared the pin and moved it away. Pinning the account IS
    // the instruction, so the first thing a cap asks now is whether it can be answered inside that
    // decision - same account, the fleet's declared fallback pairing - and only a fleet that
    // declares nothing this account can serve gets the move (and the pin clearance) it always had.
    var fallbackFleet = LaunchPolicy()
    fallbackFleet.model = "fable"
    // First entry names the model the session is already on, so this asserts the list is split AND
    // that an entry naming the running pair is skipped rather than relaunched onto.
    fallbackFleet.fallbackModel = "fable,opus"
    fallbackFleet.fallbackEffort = "ultracode"

    /// The account the session capped on with EVERY window spent, not just the flagship one: what a
    /// cap looks like when no pairing can be run here, because session and weekly are windows every
    /// model draws on.
    var allWindowsDry = capped0
    allWindowsDry.sessionRemaining = 0.5
    allWindowsDry.weeklyRemaining = 0.5

    let stayed = capTick(fleet: fallbackFleet, sessionPin: "D")
    check("a cap on a hand-pinned session keeps the account the user pinned",
          stayed.plan?.target.id == "D")
    check("…running the first declared fallback the account can still serve",
          stayed.plan?.model == "opus" && stayed.plan?.effort == "ultracode")
    check("…under a reason of its own, so nothing reads it as the move that spends the pin",
          stayed.plan?.reason == "cap-fallback")
    var keptPin = ManualMoveState(sessionKey: "capped", servedEpoch: 0, sessionPin: "D")
    check("and the pin is still there afterwards, which is the whole point",
          !keptPin.pinCleared(by: stayed.plan?.reason ?? "") && keptPin.sessionPin == "D")
    // Same account, so nothing here can burn through logins - the rule the fallback profile already
    // follows (ModelDegradation.swift).
    check("a stay-put relaunch never spends the recovery fuse", stayed.plan?.countsFuse == false)
    // As urgent as the handoff, and held by exactly as little: a session with no turn in it cannot
    // have capped, so the conversation this belongs to is the bound file (StandDown.swift).
    check("an unresolved fork does not hold it either",
          !relaunchHeldByUnresolvedFork(reason: "cap-fallback", unresolvedFork: true))
    // The relaunch IS the answer to the cap, so the next child starts clean rather than waiting out
    // a wall it is no longer behind.
    check("and the cap is not carried into the child it starts",
          capCarriedAcrossRelaunch(stayed.pending, reason: "cap-fallback") == nil)
    check("the user is told where the session stayed, what it runs, and how to undo it", {
        let said = capFallbackKeptPinNotice(account: "Claude 4", capped: "fable", to: "opus")
        return said.contains("Claude 4") && said.contains("opus")
            && said.contains("fable capped") && said.contains("tally model auto")
    }())

    // The other three ways out, all of them the behaviour that was already there.
    let noDeclaration = capTick(fleet: auto0, sessionPin: "D")
    check("a fleet declaring no fallback moves the session as it always did",
          noDeclaration.plan?.target.id == "S" && noDeclaration.plan?.reason == "cap")
    // BOTH WALLS IN ONE TURN, on numbers fetched after the cap: the model window and the windows
    // every model shares are all spent, so there is nothing here to fall back to. The account really
    // is out of answers, so this hands on rather than waiting for a reading that could only say the
    // same thing.
    let noRoomForIt = capTick(fleet: fallbackFleet, sessionPin: "D", on: allWindowsDry,
                              accounts: [allWindowsDry, sibling])
    check("a fallback whose windows are dry on this account too is no way to stay",
          noRoomForIt.plan?.target.id == "S")
    check("…so the pin is spent on the move, exactly as before",
          noRoomForIt.plan?.reason == "cap")
    // The user pinned the PAIR by hand as well: fleet configuration may not overwrite that, so this
    // session takes the move, which keeps the model it was told to run. Same precedence the follow
    // adoption obeys one axis over.
    let handPinnedPair = capTick(fleet: fallbackFleet, sessionPin: "D", modelPinned: true)
    check("a `tally model` pin stands the re-pairing down",
          handPinnedPair.plan?.target.id == "S" && handPinnedPair.plan?.reason == "cap")

    // THE HARD CONSTRAINT: a session nobody pinned is untouched by any of this.
    let neverPinned = capTick(fleet: fallbackFleet, sessionPin: nil)
    check("an unpinned session is handed to a sibling, fallback declared or not",
          neverPinned.plan?.target.id == "S" && neverPinned.plan?.reason == "cap")
    // Everything the stay-put branch asks is a quota reading, so a snapshot it has already declared
    // untrustworthy decides nothing: it waits, which is what the move does with the same snapshot.
    let stale = capTick(fleet: fallbackFleet, sessionPin: "D", problem: "snapshot is 9m old")
    check("numbers too stale to trust re-pair nothing", stale.plan == nil)
    check("…and the session waits for a fresh snapshot",
          stale.pending?.reason.contains("fresh snapshot") == true)

    // MARK: - 31k2b. Staying put is only allowed on numbers fetched AFTER the cap

    // THE FILE'S OWN STAMP PROVES NOTHING. A republish rebuilds the document from the app's cached
    // accounts and stamps `generatedAt` with the moment of the rewrite, so a display toggle after
    // the cap produces a brand-new file in which every reading still predates it (Sol review,
    // 2026-08-07). Judged on those numbers the shared windows look healthy, the session stays, and
    // it walks into the same wall once per declared model.
    let staleNumbers = account("D", model: 80, refreshedAt: capNow.addingTimeInterval(-60))
    let republished = capTick(fleet: fallbackFleet, sessionPin: "D", on: staleNumbers,
                              accounts: [staleNumbers, sibling],
                              generatedAt: capNow.addingTimeInterval(30))
    check("a file rewritten after the cap does not make its readings post-cap",
          republished.plan?.reason != "cap-fallback")
    // …and it does not hand the session on either, which is the third answer: the numbers cannot
    // say yet, so it waits for ones that can rather than spending the pin on a guess.
    check("…so the tick decides nothing at all", republished.plan == nil)
    check("…and says what it is waiting for",
          republished.pending?.reason == capStayEvidenceNote)
    check("…while asking again shortly, not on every 2s tick",
          republished.pending?.nextRetry == capNow.addingTimeInterval(capRetryBackoff))

    // The writer encodes dates without fractional seconds, so a fetch inside the same second as the
    // cap arrives floored to it. Equal is not after: the reading MIGHT predate the cap, so it is
    // treated as one that does.
    let sameSecond = account("D", model: 80, refreshedAt: capNow)
    let tied = capTick(fleet: fallbackFleet, sessionPin: "D", on: sameSecond,
                       accounts: [sameSecond, sibling])
    check("a reading stamped in the same second as the cap is not evidence", tied.plan == nil)
    check("…so that tick waits too", tied.pending?.reason == capStayEvidenceNote)

    // THE CONTROL, so the refusals above are the evidence gate and not something else in the tick:
    // the same account, one second later on the fetch clock.
    let freshNumbers = account("D", model: 80, refreshedAt: capNow.addingTimeInterval(1))
    let evidenced = capTick(fleet: fallbackFleet, sessionPin: "D", on: freshNumbers,
                            accounts: [freshNumbers, sibling])
    check("a reading fetched after the cap is what lets the session keep its account",
          evidenced.plan?.target.id == "D" && evidenced.plan?.reason == "cap-fallback")

    // The wait has an end. Past it the session is handed on, which is exactly what this code did
    // before the stay-put branch existed - the wait can only ever be a bonus.
    let waitedTooLong = capTick(fleet: fallbackFleet, sessionPin: "D", on: staleNumbers,
                                accounts: [staleNumbers, sibling],
                                now: capNow.addingTimeInterval(capStayEvidenceGrace + 1))
    check("a session cannot wait for evidence for ever",
          waitedTooLong.plan?.target.id == "S" && waitedTooLong.plan?.reason == "cap")
    // …and nothing waits when there is nothing to wait FOR: whether a fallback is declared is a
    // question about configuration, which no refresh can change.
    let nothingDeclared = capTick(fleet: auto0, sessionPin: "D", on: staleNumbers,
                                  accounts: [staleNumbers, sibling])
    check("a fleet declaring nothing hands the session on at once, evidence or not",
          nothingDeclared.plan?.target.id == "S" && nothingDeclared.plan?.reason == "cap")

    // The two rules on their own.
    check("an account's own fetch stamp is what decides whether a reading is about the cap",
          accountReadingPostdatesCap(freshNumbers, cappedAt: capNow)
              && !accountReadingPostdatesCap(staleNumbers, cappedAt: capNow)
              && !accountReadingPostdatesCap(sameSecond, cappedAt: capNow))
    check("a reading from an app too old to publish one is not evidence either",
          !accountReadingPostdatesCap(account("D", model: 80, refreshedAt: nil), cappedAt: capNow))
    // Last-good numbers kept while the fetch keeps failing describe an earlier world by
    // construction, whatever stamp rides with them.
    check("nor are last-good numbers, however they are stamped", {
        var outdated = freshNumbers
        outdated.isStale = true
        return !accountReadingPostdatesCap(outdated, cappedAt: capNow)
    }())
    check("the declared list is read from configuration alone, so a refresh cannot change it",
          declaredCapFallbacks(fallbackFleet, primaryModel: "fable") == ["opus"]
              && declaredCapFallbacks(fallbackFleet, primaryModel: "claude-opus-4-8") == ["fable"]
              && declaredCapFallbacks(auto0, primaryModel: "fable").isEmpty)

    // The rule the four cases come from, on its own.
    check("the first declared fallback this account can serve is the one it stays on",
          capFallbackInPlace(policy: fallbackFleet, account: capped0, primaryModel: "fable",
                             now: capNow)?.model == "opus")
    // A cap on the fallback itself: relaunching onto the pair the session is already running
    // answers nothing and would ask the same question again at the next cap.
    check("a list naming only the model already running is no fallback at all",
          capFallbackInPlace(policy: fallbackFleet, account: capped0,
                             primaryModel: "claude-opus-4-8", now: capNow) == nil)
    // The double wall the evidence gate exists for: the model window AND the windows every model
    // shares, all spent, on numbers fetched after the cap. There is nothing here to fall back to,
    // and no later reading could say otherwise.
    check("nor is one this account cannot serve, which is the double wall in one turn",
          capFallbackInPlace(policy: fallbackFleet, account: allWindowsDry, primaryModel: "fable",
                             now: capNow) == nil
              && accountReadingPostdatesCap(allWindowsDry, cappedAt: capNow))
    check("and a fleet that declares none has none",
          capFallbackInPlace(policy: auto0, account: capped0, primaryModel: "fable",
                             now: capNow) == nil)
    // A model alone is a complete declaration here, unlike the fallback profile's: there the model
    // has already changed server-side, so a relaunch adding nothing is an interruption for nothing;
    // here the model change IS the answer.
    var modelOnlyFleet = LaunchPolicy()
    modelOnlyFleet.fallbackModel = "opus"
    check("a declared model with no depth beside it is still a way to stay", {
        let stay = capFallbackInPlace(policy: modelOnlyFleet, account: capped0,
                                      primaryModel: "fable", now: capNow)
        return stay?.model == "opus" && stay?.effort == nil && stay?.args.isEmpty == true
    }())

    // MARK: - 31k3. Pinning the MODEL first is what stops the cap arising at all

    // The order this feature does not change, asserted because it is the existing promise the new
    // branch stands next to: a session told to run opus is judged by the opus windows, so the
    // flagship window the fleet default would have spent cannot cap it and none of the machinery
    // above ever runs.
    check("a model pin outranks the command line for what the session runs",
          sessionPrimaryModel(pin: SessionModelPin(model: "opus"),
                              launchArgs: ["--model", "fable"], providerID: "claude",
                              policy: fallbackFleet) == "opus")
    check("so a drained flagship window leaves the account serviceable for that session",
          eligible(capped0, primaryModel: "opus")
              && accountIsComfortable(capped0, primaryModel: "opus", now: capNow))
    check("…while the same account reads as spent for the session running the flagship",
          !accountIsComfortable(capped0, primaryModel: "fable", now: capNow))
    check("and a cap quarantines the account for the window that capped, not for the account",
          !quarantineBlocks(quarantineModel: "fable", pickModel: "opus")
              && quarantineBlocks(quarantineModel: "fable", pickModel: "fable"))
}
