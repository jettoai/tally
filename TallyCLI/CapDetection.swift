import Foundation

// Noticing that this session has hit a cap, noticing that it has stopped being capped, and the
// account move that follows.
//
// Split from Supervisor.swift for file size, and it is the right seam: what the loop needs back from
// this is one value (`pendingCap`), and the pieces the decision is assembled from live next door
// (SupervisorRuntime.swift). The two halves are kept apart inside this file for the reason the
// original comment gave: noticing is about the TRANSCRIPT and runs on every tick, while the move is
// about ACCOUNTS and runs behind a backoff.
//
// Everything here runs BEFORE any relaunch path in the tick, and the order is load-bearing: a
// relaunch resets the watcher's `since`, so a cap event read after one would be filtered as old
// history and lost (2026-07-24).

/// Fold this tick's transcript evidence into the pending cap recovery: clear one the session has
/// recovered from, raise one for a cap it has just hit, and quarantine the account for the model
/// window that capped.
///
/// `quarantine` is the supervisor's own session-local record; the shared per-account file is written
/// alongside it so a session launching right now avoids the same wall.
///
/// `snapshotAccounts` is a closure because it is only paid for on the tick a cap actually lands: it
/// is the one snapshot read this path costs, and it has to happen while the evidence still exists
/// (the next refresh puts the window that capped back at 100%).
func observeCapHit(pendingCap: inout PendingCapRecovery?,
                   quarantine: inout [String: (model: String?, until: Date)],
                   watcher: inout TranscriptWatcher, account: Snapshot.Account,
                   primaryModel: String?, now: Date = Date(),
                   snapshotAccounts: () -> [Snapshot.Account] = { loadSnapshot().0?.accounts ?? [] }) {
    // The scan also refreshes the model-degradation signal the rescue and fallback blocks read, so
    // it runs on every tick rather than only while a cap is possible.
    let sawCap = watcher.sawCapHit()
    // The session came back on its own - a real assistant turn on the main chain, newer than the cap
    // (the account's window refilled, or the user waited the cooldown out) - so a later genuine cap
    // starts fresh. Unannounced: the cap badge disappearing is the news, and the turn that just
    // succeeded already told them.
    //
    // Or nobody typed and the window simply reset underneath the session, which that first arm can
    // never see: it needs an assistant turn, and an idle session produces none, so the badge hung
    // there naming an account that was back at 100%. The boundary it compares against was fixed when
    // the cap happened, so this reads no files at all (SupervisorRuntime.swift explains why it
    // cannot be recomputed here).
    //
    // Or the session simply IS NOT THERE ANY MORE. A pending cap is about one account - it names it
    // (`cappedAccountID`), the badge it raises describes waiting for a sibling to take the session
    // OFF it - so the moment this conversation is running somewhere else, there is nothing left for
    // it to describe. Every way that can happen ends here rather than at each mover, because the
    // list of movers keeps growing (a hand-typed `tally switch` is the one that exposed it: the
    // session moved from Claude 5 to Claude 2 and the status line went on saying "no account with
    // quota to spare", 2026-08-06) and a clear that has to be remembered at each of them is a clear
    // that will be forgotten at the next one.
    if let pending = pendingCap,
       pending.cappedAccountID != account.id
           || watcher.lastMainChainEventAt.map({ $0 > pending.cappedAt }) == true
           || capRecoveredByReset(pending, now: now) {
        pendingCap = nil
    }
    guard sawCap, pendingCap == nil else { return }
    // The cap's own instant, not the moment this 2s poll noticed it. The recovery boundary is
    // measured against this once and never recomputed, so the poll delay would otherwise be enough
    // to read a reset landing inside it as a stale stamp and strand the session with no reset path
    // at all (00:59:59 cap, 01:00:00 tick, 01:00:00 reset). Falls back to now for a cap event
    // carrying no timestamp.
    let cappedAt = watcher.capHitAt ?? now
    pendingCap = PendingCapRecovery(
        cappedAccountID: account.id, cappedAt: cappedAt, primaryModel: primaryModel,
        recoveryResetsAt: capRecoveryDeadline(accounts: snapshotAccounts(),
                                              cappedAccountID: account.id,
                                              primaryModel: primaryModel, cappedAt: cappedAt),
        nextRetry: .distantPast, reason: "")
    // Keep every session (this one and any launching now) off the account for the model window that
    // just capped until its snapshot catches up - a different model the account still serves is not
    // blocked.
    let until = now.addingTimeInterval(capQuarantineTTL)
    quarantine[account.id] = (model: primaryModel, until: until)
    quarantineAccount(account.id, model: primaryModel, until: until)
}

// MARK: - Answering a cap without leaving the account

/// What the user is told when a cap is answered on the spot: the account they pinned by hand is
/// kept, and the conversation runs the configured fallback pairing from here on.
///
/// A function rather than a constant because the account and the model ARE the news, and the way
/// back is not obvious from either: the pairing arrives on the relaunch's command line, so the
/// release is the model axis's own (`tally model auto`) rather than anything to do with the pin
/// that was just kept. The sentence lives here, next to the branch that says it, so a test can
/// assert what it promises instead of a copy of the words.
func capFallbackKeptPinNotice(account: String, capped: String?, to: String) -> String {
    let wall = capped.map { "\($0) capped" } ?? "cap hit"
    return "\(wall) → staying on \(account), falling back to \(to) " +
        "(release with `tally model auto` once quota is back)"
}

/// What the status line says while a cap on a hand-pinned session waits to find out whether it can
/// be answered without leaving that account. A wait with an end (`capStayEvidenceGrace`), so the
/// badge describes a question being settled rather than a session parked.
let capStayEvidenceNote = "waiting for a fresh reading before deciding whether to stay put"

/// How long a cap on a hand-pinned session waits for a reading taken after it, before giving up on
/// staying and handing the session on.
///
/// Two of the app's default refresh cycles (`refreshIntervalMinutes`, one minute). One is not
/// enough: a refresh landing moments BEFORE the cap consumes the cycle the cap falls in, so the
/// first reading that can answer is the one after that. Beyond two, the wait stops being a bonus
/// and starts being the capped session sitting still while a sibling has room.
///
/// The wait can only ever be a bonus, which is what makes a fixed number safe on a fleet whose
/// refresh interval the user can raise: when it expires, this does exactly what the code did before
/// the stay-put branch existed - hand the session on and clear the pin. A user on a ten-minute
/// refresh loses the chance to keep their account, not the session.
let capStayEvidenceGrace: TimeInterval = 2 * 60

/// Whether this account's numbers were FETCHED after the cap, and are therefore about the situation
/// the cap left behind.
///
/// The file's own `generatedAt` cannot answer this, which is the defect this replaced (review,
/// 2026-08-07): the app rewrites the whole document from its cached accounts whenever a setting
/// changes (`republishSnapshot`), so a display toggle produces a file stamped seconds ago whose
/// every reading predates the cap. `refreshedAt` is carried per account from the fetch itself, and a
/// republish copies it along with the numbers it belongs to, so nothing can forge it.
///
/// A stale account is refused whatever its stamp says: those numbers are the last-good copy kept
/// while the fetch is failing (`applyLastGood`, UsageStore.swift), so they describe an earlier state
/// of the world by construction.
///
/// STRICTLY AFTER, on a stamp floored to the second by the writer's encoding while the cap keeps its
/// milliseconds (`Snapshot.Account.refreshedAt` states why the writer is left alone). Within one
/// second of each other the answer is therefore no, and the caller waits - a reading that MIGHT
/// predate the cap is treated as one that does.
func accountReadingPostdatesCap(_ account: Snapshot.Account, cappedAt: Date) -> Bool {
    !account.isStale && account.refreshedAt.map { $0 > cappedAt } == true
}

/// The models this fleet declares for a session whose model has just hit a wall, in the order the
/// user wrote them.
///
/// CONFIGURATION ONLY: no quota is read here, so the answer is the same before and after a refresh.
/// That is what lets the caller tell "there is nothing to stay for" (answer empty, hand the session
/// on now) apart from "there might be, but this reading cannot say" (answer non-empty, wait for one
/// that can) without pretending the second is the first.
///
/// The list is the same comma-separated `fallbackModel` the quota fallback profile and the safeguard
/// restore read. An entry naming the model the session already runs is dropped: relaunching onto the
/// pair it is already on answers nothing, and the next cap would ask the identical question.
func declaredCapFallbacks(_ policy: LaunchPolicy, primaryModel: String?) -> [String] {
    (policy.fallbackModel ?? "").split(separator: ",")
        .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        .filter { !$0.isEmpty && !modelsAgree($0, primaryModel) }
}

/// The fallback pairing that lets a capped session keep the account it is on, or nil when this
/// account can serve none of the declared models.
///
/// The first declared model this account can still serve wins, by exactly the gates every account
/// pick applies: `eligible` for the windows that model spends, and comfortably above the nearly-dry
/// line rather than merely non-zero (AccountComfort.swift). A cap answered by dropping onto a window
/// with 1% left is a second cap minutes later, and the restart was spent for nothing.
///
/// The window that just capped does not veto anything here, and that is the point rather than an
/// oversight: `eligible` and the comfort gate count only the windows the model being judged actually
/// spends (`ratedWindows`), so a drained fable window says nothing about an opus fallback, while a
/// drained SESSION or WEEKLY window - which every model spends, the fallback included - correctly
/// leaves this account with nothing to stay for and sends the caller to the move. That last case is
/// the whole reason the caller must hand these gates a reading taken AFTER the cap: judged on older
/// numbers, a shared window emptied in the same turn still reads healthy and the session is walked
/// into the same wall once per declared model.
///
/// NO ONE-SHOT LATCH, unlike the fallback profile's (`applied`, ModelDegradation.swift), and the
/// difference is what triggers each. That one fires off a transcript condition which persists, so
/// without a latch it would re-fire on every tick; this one fires off a CAP EVENT, which takes a
/// user turn that actually hits a wall. Each stay-put therefore costs a fresh wall, and each is
/// allowed only by a post-cap reading showing the chosen model's windows comfortable - so a chain of
/// them is bounded by the declared models whose windows are genuinely healthy at that moment, and a
/// model already spent cannot be chosen twice. The refutable form: if a session ever falls back onto
/// a model whose window was already dry, then a reading fetched after that cap called it
/// comfortable, and `refreshedAt` in the snapshot at that moment says which reading it was.
///
/// Unlike the fallback profile this does not insist that a depth or extra flags are declared too.
/// There, the model has ALREADY changed server-side and a relaunch that changed nothing else would
/// be an interruption for nothing; here the model change is the whole answer, and a fleet that
/// declares only `fallbackModel` has still said what to run.
///
/// THE RESERVE IS WEIGHED HERE TOO, and it is not an account decision sneaking in through the back
/// door: what this asks is whether the account this session is ON can serve a weaker model, and an
/// account under the line its owner drew cannot serve anything Tally is entitled to spend. Answering
/// nil hands the session to the move below, which is exactly where a session on a reserved account
/// that just hit a wall belongs.
func capFallbackInPlace(policy: LaunchPolicy, account: Snapshot.Account, primaryModel: String?,
                        reserves: AccountReserves = .none,
                        now: Date = Date()) -> (model: String, effort: String?, args: [String])? {
    guard let model = declaredCapFallbacks(policy, primaryModel: primaryModel).first(where: {
        eligible(account, primaryModel: $0)
            && accountIsComfortable(account, primaryModel: $0, reserves: reserves, now: now)
    }) else { return nil }
    return (model, policy.fallbackEffort, declaredFallbackArgs(policy.fallbackArgs))
}

// MARK: - The move a cap leads to

/// How a CAP handoff reads a session that carries a pin of its own: the mode the decision is judged
/// by (`capRecoveryAction`), and the account it should land on when it is allowed.
///
/// Both answers come from one rule: a cap may pass the SESSION pin, because it is about to clear it,
/// and it may never pass the FLEET pin, because nothing clears that. Asking `capRecoveryAction` with
/// the session policy would answer `.waitPinned` on a pin the cap is entitled to end, and the
/// session would sit on a capped account forever with `pinClearedByCap` unreachable - which is the
/// hole this closes (found in review, 2026-08-06).
///
/// The three answers, in the order they are decided:
///
///  - No session pin: nothing here applies, and the fleet's own mode decides exactly as it always
///    has (a fleet-pinned session waits; staying put is what pinning means).
///  - A session pin, and no fleet pin under it: the cap goes ahead and picks for itself, which is
///    what would have decided for this session if it had never been pinned.
///  - A session pin over a FLEET pin: the cap goes ahead only if the fleet's account is one of the
///    candidates this cap already judged usable, and lands THERE rather than on a pick of its own -
///    that account is where the underlying instruction says this session belongs, and it is checked
///    against the candidates because a pin naming a dead end (signed out, drained, quarantined, or
///    the account that just capped) would strand the session this handoff exists to keep working.
///    When it cannot be honoured the answer is `waitPinned` again, deliberately: the pin switch
///    would drag the session back onto that account on the next quiet tick regardless of quota
///    (`applyPinSwitch` asks only whether it is launchable), so a handoff the fleet pin does not
///    sanction is a restart the session pays for twice and keeps nothing from.
///
/// A preferred account skips the comfort bar the cap normally insists on, and that is the pin being
/// honoured rather than an oversight: `tally claude` launches a pinned account that is nearly out
/// too. It is still `eligible`, so it has SOME headroom.
func capReading(fleet: LaunchPolicy, sessionPin: String?, candidates: [Snapshot.Account])
    -> (mode: String, preferred: Snapshot.Account?) {
    guard sessionPin != nil else { return (fleet.mode, nil) }
    guard fleet.mode == "manual", let pin = fleet.pinnedAccountID else { return ("auto", nil) }
    guard let pinned = candidates.first(where: { $0.id == pin }) else { return (fleet.mode, nil) }
    return ("auto", pinned)
}

/// One poll tick's cap handoff: move the session to a sibling that can still serve it, or record why
/// it is waiting. Nothing happens on the vast majority of ticks - there is no pending cap, or the
/// backoff has not elapsed.
///
/// Lifted out of the poll loop when the session pin gave the decision a second input (`capReading`,
/// SessionSwitch.swift): the block had grown three questions deep inside a file at its size cap, and
/// the questions are all answerable without a child, which makes the seam pay for itself twice.
///
/// The backoff gate and the waiting branch skip only the HANDOFF ATTEMPT, never the rest of the
/// tick: a blocked cap (no eligible target) must still let the follow block below it run, so a
/// single-account user who caps and then switches Settings to a model with headroom actually adopts
/// it (the main UX complaint from the 2026-07-24 incident).
///
/// `fleet` is the policy WITHOUT this session's own pin over it, and `sessionPin` arrives beside it
/// rather than folded in, because the cap is the one reader that treats the two differently
/// (`capReading` states the whole rule). `loaded` is the tick's snapshot read, injectable like the
/// rebalance's so the decision is testable without a home directory, and deferred so that ticks with
/// nothing to do do not pay for it (see the guard).
///
/// `modelPinned` is whether a `tally model` pin stands on this session, and it is asked for one
/// branch only: the stay-put fallback below may not overwrite a pair the user chose by hand.
///
/// `steering` is whether Tally may pick an account for this session at all (AutoSteering.swift),
/// and it reaches the MOVE only. The stay-put branch above it is a same-account relaunch onto a
/// declared fallback pairing, which is not an account decision and is left alone under every mode -
/// the same line `off` draws everywhere else, between choosing an account and everything else the
/// supervisor does.
func applyCapHandoff(plan: inout RelaunchPlan?, pendingCap: inout PendingCapRecovery?,
                     account: Snapshot.Account, providerID: String, fleet: LaunchPolicy,
                     steering: Bool, sessionPin: String?, modelPinned: Bool = false,
                     quarantine: [String: (model: String?, until: Date)],
                     fuseAllows: Bool, reserves: AccountReserves = .none, now: Date = Date(),
                     loaded: @autoclosure () -> (Snapshot?, String?) = loadSnapshot()) {
    guard plan == nil, var pending = pendingCap, now >= pending.nextRetry else { return }
    // Read INSIDE the guard, and `@autoclosure` is what makes that possible: a plain default
    // argument is evaluated at the call site, before this function is entered, so the snapshot was
    // being read and JSON-decoded on every 2s tick of every supervised session for a branch that
    // almost never runs (review, 2026-08-06). The injection seam is unchanged - a caller still
    // passes a value, and the compiler wraps it.
    let (snapshot, snapshotProblem) = loaded()
    let primary = pending.primaryModel
    // A HAND-PINNED SESSION IS ASKED A DIFFERENT QUESTION FIRST. `tally switch` is the user saying
    // which ACCOUNT this conversation belongs on, so a cap that can be answered without leaving it
    // must be: relaunch on the fleet's declared fallback pairing, same account, pin untouched. Only
    // when this account can serve none of those does the move below happen, and that one costs the
    // pin (`pinClearedByCap`). The rule the handoff was written under - a cap means the user wants
    // the MODEL kept and will accept another account - is exactly the wrong way round for a session
    // they pinned by hand minutes earlier (owner report, 2026-08-07).
    //
    // NOT WHILE A `tally model` PIN STANDS, which is the precedence the follow adoption already
    // obeys one axis over (SessionDirectives.swift): the pairing here is fleet CONFIGURATION and
    // the pin is an INSTRUCTION, and a relaunch carrying this pairing would put a `--model` on the
    // command line that the session's own pin contradicts for the rest of its life. Such a session
    // takes the move below instead, which keeps the model it was told to run.
    //
    // The account comes from the snapshot rather than from the launch, because everything asked of
    // it is a quota reading and the launch's copy is as old as the session; a snapshot too stale to
    // trust is left to the wait the action below already answers with.
    //
    // A same-account relaunch, so no fuse: it cannot burn through logins, exactly as the fallback
    // profile cannot (ModelDegradation.swift). The pending cap is left standing rather than cleared
    // here - the relaunch drops it (`capCarriedAcrossRelaunch`), and a tick that stands the
    // relaunch down must still be waiting for it.
    //
    // AND THE NUMBERS HAVE TO BE ABOUT THIS CAP, which is why there are THREE answers here and not
    // two. Staying put is a bet that the wall was the model window; if it was a SHARED one (session,
    // weekly - every model spends those, the fallback included) then nothing can be run here at all,
    // and older numbers showing them healthy would send the session round the same wall again, once
    // per declared model, while the sibling handoff it needed never ran (review, 2026-08-07). The
    // evidence is the ACCOUNT's own fetch stamp, never the file's - a republish stamps a fresh
    // `generatedAt` on cached readings, so the file can be seconds old and every number in it
    // minutes old (`accountReadingPostdatesCap`).
    //
    //   - reading taken after the cap, and something declared this account can serve: stay.
    //   - reading taken after the cap, and nothing it can serve: hand on, which costs the pin. The
    //     account really is out of answers, so waiting would only delay the move.
    //   - cannot tell yet: WAIT for a reading that can, up to `capStayEvidenceGrace`. Handing on
    //     here is the failure this whole branch exists to stop, and the wait costs a capped session
    //     a couple of minutes it was not working anyway. Past the grace it hands on regardless,
    //     which is exactly what this code did before the branch existed.
    //
    // The wait is entered only when there is something to wait FOR: `declaredCapFallbacks` asks the
    // configuration, not the numbers, so a fleet declaring nothing (or nothing but the model that
    // just capped) hands the session on immediately, as it always did.
    let current = snapshot?.accounts.first { $0.id == account.id } ?? account
    if sessionPin != nil, !modelPinned, snapshotProblem == nil,
       !declaredCapFallbacks(fleet, primaryModel: primary).isEmpty {
        if accountReadingPostdatesCap(current, cappedAt: pending.cappedAt) {
            if let stay = capFallbackInPlace(policy: fleet, account: current, primaryModel: primary,
                                             reserves: reserves,
                                             now: now) {
                warn(capFallbackKeptPinNotice(account: current.label, capped: primary,
                                              to: stay.model))
                plan = RelaunchPlan(target: current, reason: "cap-fallback", countsFuse: false,
                                    model: stay.model, effort: stay.effort, extraArgs: stay.args)
                return
            }
        } else if now < pending.cappedAt.addingTimeInterval(capStayEvidenceGrace) {
            pending.reason = capStayEvidenceNote
            pending.nextRetry = now.addingTimeInterval(capRetryBackoff)
            pendingCap = pending
            return
        }
    }
    let excluded = quarantinedAccounts(forPrimary: primary, sessionLocal: quarantine, now: now)
    // The candidates this cap considers usable at all: signed in, able to serve the model, not the
    // account that just capped, and not one quarantined for capping on it recently.
    let candidates = (snapshot?.accounts ?? []).filter {
        $0.provider == providerID && eligible($0, primaryModel: primary)
            && $0.id != account.id && !excluded.contains($0.id)
    }
    // The nearly-dry gate, stricter here than on the launch path (AccountComfort.swift): handing a
    // capped session to an account with 1% left just caps it again a few minutes later, and unlike a
    // launch there is a running conversation to reload, so no comfortable sibling means WAIT rather
    // than move. A fleet pin the session pin is being cleared in favour of overrides that, because a
    // pin is an instruction rather than a quota opinion.
    let reading = capReading(fleet: fleet, sessionPin: sessionPin, candidates: candidates)
    let target = reading.preferred
        ?? capHandoffTarget(candidates, primaryModel: primary, reserves: reserves, now: now)
    let action = capRecoveryAction(steering: steering, mode: reading.mode, fuseAllows: fuseAllows,
                                   snapshotStale: snapshotProblem != nil, hasTarget: target != nil)
    guard action == .handoff, let target else {
        // The reason rides in the badge (the child keeps running, so nothing may be printed over
        // it); it is held here so the badge only changes when it changes.
        if let note = action.waitingNote { pending.reason = note }
        pending.nextRetry = now.addingTimeInterval(capRetryBackoff)
        pendingCap = pending
        return
    }
    warn("cap hit → handing off to \(target.label) (\(pickReason(target, primaryModel: primary)))")
    // Own the account move; a follow adoption later in the tick folds its pair into this plan.
    plan = RelaunchPlan(target: target, reason: "cap", countsFuse: true)
}
