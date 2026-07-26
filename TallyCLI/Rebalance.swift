import Foundation

// Idle rebalance: a running session leaves a dying account BEFORE it hits the wall.
//
// The smart pick used to apply at two moments only, launch and cap handoff, so a session that was
// placed well an hour ago rode its account all the way down. Measured on 2026-07-26: five sessions
// sat on an account whose flagship window was at 9% while a sibling held 77%, and every one of them
// was going to slam the wall mid-turn and only THEN be handed off. The cap handoff is a repair; this
// is the same move made early, while it is still free.
//
// WHERE THE LINE IS: "dying" is `isComfortable` (AccountComfort.swift), which draws the same
// nearly-dry line at 5% that the launch pick, the cap handoff, and the dry-pool alert all draw. One
// line across the product is the point, so this deliberately does NOT introduce a second, earlier
// threshold of its own. The consequence is worth being explicit about: the 9% session above is not
// moved at 9%, it is moved once that window crosses 5%, which is still minutes of runway before the
// wall rather than none. Moving earlier than that is a one-constant change (a rebalance-only floor),
// and it belongs to whoever owns the policy, not to this file.
//
// What makes it safe to do proactively is that it is never urgent. A cap handoff interrupts because
// the session is already stuck; a rebalance has nothing to repair yet, so it waits for the full
// "left alone" bar (transcript, subagents, open tool call, keyboard) and simply does not happen on a
// session in use. If the account dies before an idle moment arrives, the cap path catches it exactly
// as it does today. Nothing here is a new safety net; it is the old one, moved earlier.
//
// Two guardrails, both required, because "move a running session" is the expensive verb:
//
//  - The recovery fuse, shared with cap recoveries (at most 3 automatic moves per 10 minutes per
//    session, carried across a self-update exec). A rebalance is automatic, so it counts: a session
//    that has already been moved three times has a systemic problem no fourth move will cure.
//  - One rebalance per account per window cycle, ACROSS supervisors. Without it the five sessions
//    above all read the same picture on the same tick and stampede onto the one healthy sibling,
//    which is how the 02:22 storm started. The first session to notice moves; the rest read the
//    record and stay, and the account re-arms when the window that binds it resets.

/// Per-account rebalance records (~/.tally/rebalance/<account>), one file per account so concurrent
/// supervisors never corrupt a shared document, written atomically. Deliberately the same shape as
/// the cap quarantine next door (Quarantine.swift): both answer "has something already happened to
/// this account that every supervisor must respect", and one shape is one thing to reason about.
let rebalanceDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".tally/rebalance")

/// The cycle of the window that BINDS this account: its emptiest counted window, keyed by that
/// window's reset time in whole seconds. Same derivation as the app's per-cycle dedup
/// (`DryPoolLogic.resetKey`, used by `ResetHintLogic`), for the same reason: the record has to
/// survive sub-second jitter in a reported reset time without reading as a new cycle, and it has to
/// re-arm by itself when the window actually refills.
///
/// The BINDING window rather than any particular one, because that is what makes the account dry:
/// a spent weekly under a fresh session window is a spent account, and it is the weekly's reset that
/// ends the drought. Windows are the ones `ratedWindows` counts for the declared primary model, so
/// this never disagrees with the comfort gate about which windows the account actually spends.
///
/// nil when the account reports no windows, or its binding window has no known reset time. With no
/// cycle to name there is nothing to dedup against, and callers treat that as "do not move": an
/// un-deduped rebalance is exactly the stampede the record exists to prevent.
func rebalanceCycleKey(_ account: Snapshot.Account, primaryModel: String?,
                       now: Date = Date()) -> String? {
    guard let binding = ratedWindows(account, primaryModel: primaryModel, now: now)
        .min(by: { $0.remaining < $1.remaining }), let resetsAt = binding.resetsAt else { return nil }
    return String(Int(resetsAt.timeIntervalSince1970.rounded()))
}

/// Whether this account has already been rebalanced away from during `cycle`. Any other stored key
/// (an older cycle, or nothing at all) is a fresh opportunity - the record identifies WHICH window
/// the move was made in, so a refilled window re-arms without anyone having to expire the file.
func rebalancedThisCycle(_ accountID: String, cycle: String, dir: URL = rebalanceDir) -> Bool {
    let file = dir.appendingPathComponent(rebalanceRecordName(accountID))
    guard let raw = try? String(contentsOf: file, encoding: .utf8) else { return false }
    return raw.trimmingCharacters(in: .whitespacesAndNewlines) == cycle
}

/// Record that this account has been rebalanced away from in `cycle`, so every other supervisor
/// leaves it alone until the binding window resets. Best-effort: a record that cannot be written
/// costs an extra move at worst, never a stuck session.
func recordRebalance(_ accountID: String, cycle: String, dir: URL = rebalanceDir) {
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try? cycle.write(to: dir.appendingPathComponent(rebalanceRecordName(accountID)),
                     atomically: true, encoding: .utf8)
}

/// The filename an account's record lives under: a filesystem-safe derivative, as in the quarantine.
/// Both halves go through it so a slash in an id can never make the writer and the reader disagree.
func rebalanceRecordName(_ accountID: String) -> String {
    accountID.replacingOccurrences(of: "/", with: "_")
}

/// The account a running session should move to before its own account runs out, or nil to stay put.
/// Pure, so every gate is testable without a snapshot, a child, or a filesystem.
///
/// `candidates` is the field the caller has already narrowed exactly as the cap handoff does (right
/// provider, eligible for the running model, not this account, not quarantined), and the target is
/// chosen by the same `capHandoffTarget`: comfortable only, then the best burn rate. Sharing that
/// function is the point - a proactive move and a repair move must never disagree about where a
/// session belongs, and an empty field means the same thing in both (nothing is comfortable, so
/// there is nowhere better to be and the session stays where it is).
///
/// The gates, in the order they bite:
///  - `mode`: manual means the user pinned this account. Pinning is a statement about where the
///    session runs, so a pinned session is never moved by quota reasoning, dying account or not.
///  - `isQuiet`: the full non-urgent bar. This is a convenience, so it may never cost a keystroke.
///  - `fuseAllows`: automatic moves share one budget with cap recoveries.
///  - `alreadyThisCycle`: the cross-supervisor per-cycle record above.
///  - the account is not comfortable: the same gate the pick uses, so "dying" means one thing in
///    this repo. It already exempts a window about to refill, so 9% resetting in five minutes is
///    correctly read as a full window rather than as a reason to move.
func rebalanceTarget(mode: String, isQuiet: Bool, fuseAllows: Bool, alreadyThisCycle: Bool,
                     current: Snapshot.Account, candidates: [Snapshot.Account],
                     primaryModel: String?, now: Date = Date()) -> Snapshot.Account? {
    guard mode != "manual", isQuiet, fuseAllows, !alreadyThisCycle,
          !accountIsComfortable(current, primaryModel: primaryModel, now: now)
    else { return nil }
    return capHandoffTarget(candidates, primaryModel: primaryModel, now: now)
}

/// One poll tick's proactive move, with the live picture the gate above needs: the target to move to
/// and the cycle key the caller records once the plan is made. nil on almost every tick, for any of
/// the reasons above.
///
/// The snapshot is read rather than trusted from the loop's own `account`, which was fixed at launch
/// and, after a self-update exec, carries no quota fields at all: "is the account I am ON dying" is
/// a question only the live snapshot can answer. A snapshot too old to trust answers nothing, the
/// same rule the cap handoff applies (`CapAction.waitStale`) and for the same reason - moving a
/// session on hours-old numbers is how a session lands somewhere worse than it started.
///
/// The field is narrowed exactly as the cap handoff narrows it: this provider, eligible for the
/// model actually running, not the account we are on, and nothing quarantined.
func rebalanceMove(provider: String, account: Snapshot.Account, primaryModel: String?,
                   mode: String, isQuiet: Bool, fuseAllows: Bool,
                   quarantine: [String: (model: String?, until: Date)] = [:],
                   loaded: (Snapshot?, String?) = loadSnapshot(), now: Date = Date(),
                   dir: URL = rebalanceDir) -> (target: Snapshot.Account, cycle: String)? {
    let (snapshot, problem) = loaded
    guard problem == nil, let snapshot,
          let live = snapshot.accounts.first(where: { $0.id == account.id }),
          let cycle = rebalanceCycleKey(live, primaryModel: primaryModel, now: now)
    else { return nil }
    let excluded = quarantinedAccounts(forPrimary: primaryModel, sessionLocal: quarantine, now: now)
    let candidates = snapshot.accounts.filter {
        $0.provider == provider && eligible($0, primaryModel: primaryModel)
            && $0.id != account.id && !excluded.contains($0.id)
    }
    guard let target = rebalanceTarget(
        mode: mode, isQuiet: isQuiet, fuseAllows: fuseAllows,
        alreadyThisCycle: rebalancedThisCycle(account.id, cycle: cycle, dir: dir),
        current: live, candidates: candidates, primaryModel: primaryModel, now: now)
    else { return nil }
    return (target, cycle)
}
