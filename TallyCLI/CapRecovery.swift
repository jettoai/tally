import Foundation

// The cap-recovery section of SupervisorRuntime.swift, split out at that file's 500-line cap.

// MARK: - Cap recovery

/// How often a blocked cap recovery re-attempts the handoff. The poll loop already ticks every 2s,
/// but the recovery attempt re-reads the snapshot and re-scores, so it backs off to avoid churn;
/// short enough that a sibling freeing up (snapshots refresh far slower than this) is adopted
/// promptly, which is the whole point of not giving up.
let capRetryBackoff: TimeInterval = 15

/// A cap hit that could not hand off immediately (fuse spent, snapshot stale, or no eligible
/// sibling). The supervisor remembers it and retries at `capRetryBackoff` instead of ending
/// supervision - the old code broke out of the loop and left the session stuck on a 0% account
/// forever (esgnote, 2026-07-24). It is cleared only when the session actually recovers: it hands
/// off, or a real assistant turn appears on the main chain after the cap (the account's window
/// refilled, or the user waited the cooldown out).
struct PendingCapRecovery {
    let cappedAccountID: String
    /// When the cap was noticed. A main-chain assistant event newer than this clears the pending
    /// state (the session came back on its own).
    let cappedAt: Date
    /// The model this session actually runs (a hand-typed `--model` outranks the configured
    /// default), so the handoff target is scored against the right quota window.
    let primaryModel: String?
    /// When the window this cap was hit on refills, fixed at the moment of the cap
    /// (`capRecoveryDeadline`) and never recomputed. Reaching it is the second way the pending
    /// state clears, for a session nobody typed into. nil when the snapshot could not name one.
    let recoveryResetsAt: Date?
    /// Earliest time to re-attempt the handoff (backoff gate).
    var nextRetry: Date
    /// The last waiting-state note shown, so the terminal warns only when the reason changes.
    var reason: String
    /// WHICH WALL this cap was, carried with the record rather than re-read from the watcher, which
    /// holds only the newest event: a second wall can land while the first is still pending, so the
    /// decision needs THIS recovery's own scope. Its one reader is the weekly session-limit reset
    /// (CapLimitReset.swift), which answers a 5-hour wall and refuses every other kind, nil
    /// included - nil being what a record from a build older than this field decodes to.
    var capScope: CapScope?
}

/// The pending cap recovery a relaunch hands to the next child, or nil to start it clean.
///
/// Two reasons carry it, and they are the two that change nothing about the cap: a RELOAD and a
/// SELF-UPDATE. Both restart the same conversation on the same account for reasons of their own, and
/// a capped session with no sibling to take it is by definition quiet, so both always get to restart
/// it - while the new child's watcher filters the original cap event away as history. Dropping the
/// pending state there would leave the session waiting on an account that has stopped serving, with
/// nothing left to notice when a sibling frees up: the automatic handoff would only resume after the
/// user hit the wall a second time (2026-07-25). Every other reason genuinely changes the situation
/// - a cap handoff moved account, a pin or follow re-pointed the session, a fallback changed the
/// model pairing - so the next child starts from scratch, as it always has.
///
/// The self-update is the newer of the two, and its answer here is read twice: the new image gets it
/// through the exec argv (`resupervisePendingCapFlag`, SelfUpdate.swift), and a respawn after an
/// exec that FAILED gets it from this same value in memory. One decision, so the two paths cannot
/// disagree about what the session is still waiting for.
func capCarriedAcrossRelaunch(_ pending: PendingCapRecovery?,
                              reason: String) -> PendingCapRecovery? {
    reason == "reload" || reason == "self-update" ? pending : nil
}

/// When the window this cap was hit on comes back, decided ONCE at the moment of the cap and then
/// carried in the pending state. nil when the snapshot cannot name a boundary, which means this
/// session has only the assistant-turn clear path, exactly as before.
///
/// Fixed at the cap rather than recomputed each tick, and that is the whole design. The app
/// refreshes the snapshot every minute by default (`UsageStore.scheduleTimer`), and that refresh
/// ERASES the evidence: the window that capped goes back to 100% and its `resetsAt` jumps to the
/// next cycle, so from the tick after it the emptiest window is some healthy one whose reset is
/// still ahead and a recomputing check answers "not yet" forever. It would only ever fire inside
/// the gap between the reset and the next refresh, which is to say it would be a coin flip that
/// loses back to the original bug. A boundary captured once cannot be erased by a refresh.
///
/// EVERY window at or below the shared nearly-dry line counts, and the LATEST of their resets wins.
/// Not the emptiest window, and not an exact tie with it: the snapshot lags, so two windows that are
/// both really spent routinely read as different numbers (1% and 2%), and an exact tie would lock
/// onto the 1% window's reset a few hours out while the 2% weekly stays empty for days. The line is
/// `nearlyDryPercent`, the same 5% the launch pick, the cap handoff and the dry-pool alert draw, so
/// "dry" keeps meaning one thing in this repo. Raw remaining, not the comfort gate's effective
/// remaining (`effectiveRemaining` reads a window minutes from resetting as already full, which is
/// right for "can this account take work" and wrong for "which reset ends this drought"). The
/// windows are the ones `ratedWindows` counts for the model this session runs, so a flagship window
/// it does not spend is not one it can have capped on.
///
/// The residual risk, stated plainly because the previous version of this comment claimed there was
/// none: if the snapshot lags so far that a window which is really empty still reads ABOVE the line,
/// it is left out, and the boundary can then be earlier than the end of the real drought. The badge
/// would clear while the account is still capped. Two things make that acceptable. It is self
/// healing: the next thing the user types hits the wall again, and that cap raises a fresh pending
/// state with a fresh boundary. And the opposite bias, never clearing, is the bug this whole path
/// exists to fix, which does not heal on its own at all.
func capRecoveryDeadline(accounts: [Snapshot.Account], cappedAccountID: String,
                         primaryModel: String?, cappedAt: Date) -> Date? {
    guard let account = accounts.first(where: { $0.id == cappedAccountID }) else { return nil }
    let dry = ratedWindows(account, primaryModel: primaryModel, now: cappedAt)
        .filter { $0.remaining <= nearlyDryPercent }
    // EVERY dry window has to name a reset, and every one of those has to be a reset this cap
    // could be waiting for: we set a boundary only when we know, for each dry window, when it
    // comes back. Checking only the latest would let a stale stamp (a window already spent when
    // the session hit the wall, or a snapshot that has not moved since) hide behind a sibling's
    // later reset, and the boundary would then name a window this cap was never about.
    //
    // The alternative, dropping the stale window and taking the max of the rest, is rejected: a
    // reset time in the past can mean "it refilled and the remaining figure has not caught up" or
    // "this whole snapshot is stale and the window is still empty", and we cannot tell which. The
    // wrong guess clears the badge on a recovery that never happened. Answering nil instead puts
    // the session back on the assistant-turn path, which is what every other incomplete picture
    // here does. Nothing dry at all falls out of the same guard: no resets, so no latest.
    let resets = dry.compactMap(\.resetsAt)
    guard resets.count == dry.count, resets.allSatisfy({ $0 > cappedAt }),
          let latest = resets.max() else { return nil }
    return latest
}

/// Whether the reset this cap was waiting for has arrived, so the pending recovery no longer
/// describes anything that is still true.
///
/// The other clear path needs a real assistant turn newer than the cap, which only a user who
/// types can produce, and the handoff's candidate list excludes the account the session is already
/// on. Between them, "the account I am on came back while nobody typed" had no path at all: the
/// badge said "no account with quota to spare" for hours after that account was back at 100% (five
/// sessions in that state at 01:15, 2026-07-31, on a window that had reset at 00:59).
///
/// A reset boundary rather than "the account looks comfortable again", deliberately. The snapshot
/// still reads healthy at the moment of the cap (the lag `capRecoveryDeadline` above describes), so
/// a comfort check would clear the pending state on the very tick that raised it and the recovery
/// would never fire. A reset that has come and gone is not an opinion about the numbers.
func capRecoveredByReset(_ pending: PendingCapRecovery, now: Date = Date()) -> Bool {
    pending.recoveryResetsAt.map { now >= $0 } == true
}

/// What to do about a pending cap this tick, given the live launch policy and account picture.
/// Pure so the priority order (observe-only > pinned > fuse > stale snapshot > no target > handoff)
/// is testable without spawning a child.
///
/// `steering` leads because it is the only answer that is not about this cap: a fleet set to
/// observe only has said Tally may not choose an account, and the cap is a reason to move rather
/// than a licence to (AutoSteering.swift). The session then behaves exactly as `--no-handoff`
/// leaves it - capped, supervised, waiting for the user - which is what "a dashboard, nothing more"
/// promises.
enum CapAction: Equatable {
    case handoff          // fuse has room, a fresh snapshot, and an eligible sibling: move now
    case waitSteeringOff  // the fleet is set to observe only: Tally may not pick an account at all
    case waitPinned       // manual pin on the capped account: staying put is what pinning means
    case waitFuse         // too many recent handoffs: cool down before burning another login
    case waitStale        // snapshot too old to trust a target pick
    case waitNoTarget     // no other account worth moving to right now

    /// The waiting-state note shown to the user (state-change-only); nil for `.handoff`.
    var waitingNote: String? {
        switch self {
        case .handoff: return nil
        // The one wait that will not lift by itself, so the sentence names the two things that end
        // it rather than describing a situation: this is the mode saying Tally never picks an
        // account (AutoSteering.swift), and the session stays exactly where `--no-handoff` would
        // have left it.
        case .waitSteeringOff:
            return "staying put (launches are set to observe only; move it with `tally account`)"
        case .waitPinned: return "staying put (pinned in Tally; unpin to allow handoff)"
        case .waitFuse: return "too many handoffs recently, cooling down before another"
        case .waitStale: return "waiting for a fresh snapshot before handing off"
        // Since the handoff started requiring a comfortable target, the usual reason is not that
        // there is no sibling but that every sibling is nearly dry too, so the note names quota
        // rather than eligibility: "no other account" would read as a lie to someone looking at a
        // second account in the panel, and hide that the wait ends when quota returns.
        case .waitNoTarget: return "no account with quota to spare, waiting for one to free up"
        }
    }
}

func capRecoveryAction(steering: Bool, mode: String, fuseAllows: Bool, snapshotStale: Bool,
                       hasTarget: Bool) -> CapAction {
    if !steering { return .waitSteeringOff }
    if mode == "manual" { return .waitPinned }
    if !fuseAllows { return .waitFuse }
    if snapshotStale { return .waitStale }
    if !hasTarget { return .waitNoTarget }
    return .handoff
}
