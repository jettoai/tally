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
//    which is how the 02:22 storm started. The first session to CLAIM the cycle moves; the rest
//    lose the claim and stay, and the account re-arms when the window that binds it resets.

/// Per-account rebalance claims (~/.tally/rebalance/<account>.<cycle>), one file per account per
/// cycle so concurrent supervisors never corrupt a shared document. Deliberately next door to the
/// cap quarantine (Quarantine.swift): both answer "has something already happened to this account
/// that every supervisor must respect", and one place to look is one thing to reason about.
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
/// Emptiest by the EFFECTIVE remaining the comfort gate weighs (`effectiveRemaining`), not the raw
/// percentage, for the same reason: the key has to name the window the gate is reacting to. A
/// session window at 3% resetting in five minutes IS a full window to the gate, so keying off its
/// reset would expire the claim five minutes later and let one unbroken weekly drought move the
/// same session twice.
///
/// nil when the account reports no windows, or its binding window has no known reset time. With no
/// cycle to name there is nothing to claim, and callers treat that as "do not move": an unclaimed
/// rebalance is exactly the stampede the claim exists to prevent.
func rebalanceCycleKey(_ account: Snapshot.Account, primaryModel: String?,
                       now: Date = Date()) -> String? {
    guard let binding = ratedWindows(account, primaryModel: primaryModel, now: now)
        .min(by: { effectiveRemaining(comfortWindow($0), now: now)
                     < effectiveRemaining(comfortWindow($1), now: now) }),
          let resetsAt = binding.resetsAt else { return nil }
    return String(Int(resetsAt.timeIntervalSince1970.rounded()))
}

/// Claim the one rebalance this account gets in `cycle`, across every supervisor on the machine.
/// True means this process won the claim and may move its session; false means another supervisor
/// holds it (or the claim could not be written), and this session stays where it is.
///
/// Claiming and recording are ONE act, in one syscall: `O_CREAT | O_EXCL` either creates the file or
/// fails because it is already there. Reading a record and writing it after the plan was made left
/// a window in which N supervisors whose 2s ticks land together all read "not yet moved" and all
/// moved, which is the stampede this whole record exists to prevent (the 02:22 storm above).
/// An atomic WRITE does not help with that: it protects the file's contents, not the decision.
///
/// The cycle rides in the FILENAME rather than in the body, because that is what makes the check and
/// the write inseparable: a claim that is already there belongs to someone else, and a refilled
/// window is a new name, so the account re-arms by itself without anyone having to expire anything.
///
/// Refusing when the claim cannot be written for any other reason is deliberate. A rebalance repairs
/// nothing, it is only ever early, so not moving costs at worst the cap handoff doing it later;
/// moving without a claim costs every session on the account landing on one sibling.
func claimRebalanceCycle(_ accountID: String, cycle: String, dir: URL = rebalanceDir) -> Bool {
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    guard legacyRecordAllows(accountID, cycle: cycle, dir: dir) else { return false }
    sweepRebalanceClaims(accountID, keeping: cycle, dir: dir)
    let fd = open(dir.appendingPathComponent(rebalanceClaimName(accountID, cycle: cycle)).path,
                  O_CREAT | O_EXCL | O_WRONLY, 0o644)
    guard fd >= 0 else { return false }
    close(fd)
    return true
}

/// Whether a record written by the pre-claim shape (one bare per-account file whose BODY is the
/// cycle) leaves this cycle open. Those files sit in `~/.tally/rebalance` on every machine that has
/// run this feature, so one is honoured for the cycle it names, which is what stops an upgrade in
/// the middle of a drought from handing out a second move. Nothing writes this shape any more, and a
/// record naming any other cycle is dead weight and goes.
private func legacyRecordAllows(_ accountID: String, cycle: String, dir: URL) -> Bool {
    let file = dir.appendingPathComponent(rebalanceRecordName(accountID))
    guard let raw = try? String(contentsOf: file, encoding: .utf8) else { return true }
    if raw.trimmingCharacters(in: .whitespacesAndNewlines) == cycle { return false }
    try? FileManager.default.removeItem(at: file)
    return true
}

/// Drop this account's claims from cycles that are over, so the directory does not grow one file per
/// window cycle forever. The cycle being claimed is never swept: a reset time the snapshot has not
/// caught up with is in the past and still the cycle we are in. Opportunistic, exactly as the
/// quarantine expires its own records while reading them.
private func sweepRebalanceClaims(_ accountID: String, keeping cycle: String, dir: URL,
                                  now: Date = Date()) {
    let prefix = rebalanceRecordName(accountID)
    let files = (try? FileManager.default.contentsOfDirectory(at: dir,
        includingPropertiesForKeys: nil)) ?? []
    for file in files {
        let name = file.lastPathComponent
        guard let dot = name.lastIndex(of: "."), String(name[..<dot]) == prefix else { continue }
        let stored = String(name[name.index(after: dot)...])
        guard stored != cycle, let epoch = Double(stored),
              Date(timeIntervalSince1970: epoch) < now else { continue }
        try? FileManager.default.removeItem(at: file)
    }
}

/// The file one claim lives under. The cycle is whole seconds, so it never contains a dot and the
/// account half is always everything before the last one, however many dots an id carries
/// (`claude:.claude3` is a real id on this machine).
func rebalanceClaimName(_ accountID: String, cycle: String) -> String {
    "\(rebalanceRecordName(accountID)).\(cycle)"
}

/// The filesystem-safe derivative of an account id, as in the quarantine. Every path built here goes
/// through it, so a slash in an id can never make the writer and the reader disagree.
func rebalanceRecordName(_ accountID: String) -> String {
    accountID.replacingOccurrences(of: "/", with: "_")
}

/// The account a running session should move to before its own account runs out, or nil to stay put.
/// Every gate but the claim is pure, and the claim arrives as a closure, so the whole decision is
/// testable without a snapshot, a child, or a filesystem.
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
///  - the account is not comfortable: the same gate the pick uses, so "dying" means one thing in
///    this repo. It already exempts a window about to refill, so 9% resetting in five minutes is
///    correctly read as a full window rather than as a reason to move.
///  - `claim`: the cross-supervisor per-cycle claim above, and deliberately LAST. It is the only
///    gate with a side effect, so asking it earlier would spend this account's one move of the cycle
///    on a tick that then declines to move (a pinned session, a session mid-turn, nowhere better to
///    go), and the account would sit un-rebalanceable until its window reset.
func rebalanceTarget(mode: String, isQuiet: Bool, fuseAllows: Bool,
                     current: Snapshot.Account, candidates: [Snapshot.Account],
                     primaryModel: String?, now: Date = Date(),
                     claim: () -> Bool = { true }) -> Snapshot.Account? {
    guard mode != "manual", isQuiet, fuseAllows,
          !accountIsComfortable(current, primaryModel: primaryModel, now: now),
          let target = capHandoffTarget(candidates, primaryModel: primaryModel, now: now),
          claim()
    else { return nil }
    return target
}

/// One poll tick's proactive move, with the live picture the gate above needs. nil on almost every
/// tick, for any of the reasons above.
///
/// A target comes back only once this supervisor HOLDS the cycle's claim, so there is no moment
/// between deciding to move and recording it for a sibling supervisor to decide the same thing. The
/// caller cannot forget to record it either, because there is nothing left to record.
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
                   dir: URL = rebalanceDir) -> Snapshot.Account? {
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
    return rebalanceTarget(
        mode: mode, isQuiet: isQuiet, fuseAllows: fuseAllows,
        current: live, candidates: candidates, primaryModel: primaryModel, now: now,
        claim: { claimRebalanceCycle(account.id, cycle: cycle, dir: dir) })
}
