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
//
// "The window that binds it resets" is a question about a REPORTED reset time, and reported reset
// times move: they are parsed out of `/usage`'s human text, whose finest unit is the minute
// ("resets Aug 2 at 2:39pm"), so the same unbroken window is reported a minute later or earlier as
// the underlying instant rounds one way or the other. That wobble read as a new cycle and re-armed
// the claim mid-drought, which is the connected chain of handoffs the claim exists to prevent:
// Claude 2's session window at 1% moved two sessions ten minutes apart on 2026-08-02 (its claims
// for that one window sit on disk as 06:39:00Z and 06:40:00Z), and Claude's spent weekly did the
// same twenty-four minutes apart the same morning. So a cycle is matched by NEARNESS rather than by
// equality (`rebalanceCycleTolerance`).

/// Per-account rebalance claims (~/.tally/rebalance/<account>.<cycle>), one file per account per
/// cycle so concurrent supervisors never corrupt a shared document, alongside one permanent
/// `<account>.lock` per account that the decision below runs under. Deliberately next door to the
/// cap quarantine (Quarantine.swift): both answer "has something already happened to this account
/// that every supervisor must respect", and one place to look is one thing to reason about.
let rebalanceDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".tally/rebalance")

/// How far a reported reset time may move and still name the SAME drought. The `/usage` text these
/// times are parsed from carries minutes and no finer, so one unbroken window is reported up to a
/// minute apart between polls (every reset time on this machine is minute-aligned, and the two
/// leaked claims above are exactly 60s apart). Five minutes clears that comfortably while staying
/// far below the shortest window a genuine new cycle can arrive on - the 5h session window - so no
/// real reset is ever mistaken for jitter.
///
/// The app keeps its own copy of this rule (`DryPoolLogic.cycleTolerance` and `namesSameCycle`,
/// used by the dry-pool alert and `ResetHintLogic`) because the two live in different targets; they
/// are the same tolerance for the same reason, and should move together.
let rebalanceCycleTolerance: TimeInterval = 5 * 60

/// Whether two cycle keys name the same drought: the same reported reset, or one that has moved no
/// further than the source's own resolution can move it. Keys that are not epochs at all, which
/// nothing writes, match only themselves.
private func namesSameDrought(_ one: String, _ other: String) -> Bool {
    guard let a = Double(one), let b = Double(other) else { return one == other }
    return abs(a - b) <= rebalanceCycleTolerance
}

/// The cycle of the window that BINDS this account: its emptiest counted window, keyed by that
/// window's reset time in whole seconds. Same derivation as the app's per-cycle dedup
/// (`DryPoolLogic.resetKey`, used by `ResetHintLogic`), for the same reason: the record has to
/// survive jitter in a reported reset time without reading as a new cycle, and it has to re-arm by
/// itself when the window actually refills. Whole seconds are only half of the first half - the
/// jitter this source actually produces is a whole minute - so the comparison, not the key, is
/// where the tolerance lives.
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
/// holds it, is deciding right now, or the claim could not be written - and this session stays where
/// it is.
///
/// The whole decision runs under a per-account lock, because matching cycles by NEARNESS made the
/// one-syscall claim this used to be unsound. `O_CREAT | O_EXCL` arbitrates one NAME: while every
/// supervisor that agreed on the drought also agreed on the filename, the create WAS the decision
/// and there was nothing else to protect. Nearness broke that tie between the name and the decision.
/// Two supervisors reading either side of a snapshot refresh hold `t` and `t+60`, each scans and
/// finds no claim near its own key, and each then creates a DIFFERENT file, successfully. Both win,
/// both move, and the drought hands out exactly the second move the tolerance was added to prevent
/// (32 threads alternating the two keys: two winners in every one of 100 rounds, 2026-08-02).
///
/// `flock` is the atomic primitive that puts the check and the write back together: exactly one
/// supervisor at a time reads this account's claims and writes its own. Contention simply LOSES
/// rather than waiting (`LOCK_NB`), the same answer this function gives to every other obstacle: a
/// rebalance repairs nothing, and a supervisor that lost the lock was about to lose the claim to
/// whoever holds it anyway.
///
/// The lock is the KERNEL's to release, which is the property being bought. A lock made of a file
/// the winner creates and deletes has to answer "what if the winner died holding it", and every
/// answer to that is another race: a reaper that deletes a lock it judged stale deletes whatever
/// sits at that path, which by then may be the NEXT holder's lock, and the section is open twice
/// again. `flock` has no such question - the kernel drops the lock when the fd closes, which a
/// process death does unconditionally - so there is no debris, no expiry, and no reaper.
///
/// INVARIANT: the lock file is never unlinked. Two `flock` calls only exclude each other when they
/// hold the same inode, so a path that can be deleted and re-created is a path where two holders
/// can both succeed. It costs one empty file per account, forever, which is the price of the
/// property above.
///
/// The cycle rides in the FILENAME of the claim rather than in its body, because that is what lets
/// the account re-arm by itself: a refilled window is a new name, so nothing has to expire anything,
/// and the lock only has to cover the moment of decision rather than the life of the record.
///
/// Refusing when the claim cannot be written for any other reason is deliberate. A rebalance repairs
/// nothing, it is only ever early, so not moving costs at worst the cap handoff doing it later;
/// moving without a claim costs every session on the account landing on one sibling.
func claimRebalanceCycle(_ accountID: String, cycle: String, dir: URL = rebalanceDir) -> Bool {
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    guard let lock = acquireRebalanceLock(accountID, dir: dir) else { return false }
    defer { close(lock) }   // the kernel releases the flock with the descriptor
    guard legacyRecordAllows(accountID, cycle: cycle, dir: dir),
          !rebalanceCycleHeld(accountID, cycle: cycle, dir: dir) else { return false }
    let fd = open(dir.appendingPathComponent(rebalanceClaimName(accountID, cycle: cycle)).path,
                  O_CREAT | O_EXCL | O_WRONLY, 0o644)
    guard fd >= 0 else { return false }
    close(fd)
    return true
}

/// The descriptor holding this account's decision lock, or nil when another supervisor is inside the
/// section (or the lock file cannot be opened at all, which loses like everything else here). The
/// caller closes it, and closing it IS the release.
///
/// The lock sits beside the claims it guards and is named so the claim scan cannot mistake it for
/// one: `lock` is not an epoch, so `rebalanceCycleHeld` skips it as it skips any other stray file.
/// It is opened, never created-and-removed (the invariant above).
///
/// One thing can sit at that path and refuse to be opened forever: a DIRECTORY, which is the shape
/// the lock had while this was a `mkdir` claim, left behind by a supervisor killed while holding it.
/// `open` answers EISDIR to that every time, and the reaper that used to clear it is gone with the
/// shape, so the account would never rebalance again. One `rmdir` and one retry cost nothing and
/// clear it.
///
/// That `rmdir` cannot break the invariant above, and this is why the debris is cleared with `rmdir`
/// rather than with anything more general: it removes empty directories and nothing else, answering
/// ENOTDIR to a regular file, so the one path that must never be unlinked is one it CANNOT unlink.
/// Nor can the retry double-open the section: two supervisors that both find the directory both call
/// `rmdir`, only one of them removes it, and both then open the same newly created inode, where
/// `flock` arbitrates exactly as it does on every other tick. A directory that is not empty is
/// somebody else's data, `rmdir` refuses it, the retry fails too, and the account stays put.
private func acquireRebalanceLock(_ accountID: String, dir: URL) -> Int32? {
    let path = dir.appendingPathComponent("\(rebalanceRecordName(accountID)).lock").path
    var fd = open(path, O_CREAT | O_WRONLY, 0o644)
    if fd < 0 {
        rmdir(path)
        fd = open(path, O_CREAT | O_WRONLY, 0o644)
    }
    guard fd >= 0 else { return nil }
    guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); return nil }
    return fd
}

/// Whether a record written by the pre-claim shape (one bare per-account file whose BODY is the
/// cycle) leaves this cycle open. Those files sit in `~/.tally/rebalance` on every machine that has
/// run this feature, so one is honoured for the cycle it names, which is what stops an upgrade in
/// the middle of a drought from handing out a second move. Nothing writes this shape any more, and a
/// record naming any other cycle is dead weight and goes.
private func legacyRecordAllows(_ accountID: String, cycle: String, dir: URL) -> Bool {
    let file = dir.appendingPathComponent(rebalanceRecordName(accountID))
    guard let raw = try? String(contentsOf: file, encoding: .utf8) else { return true }
    if namesSameDrought(raw.trimmingCharacters(in: .whitespacesAndNewlines), cycle) { return false }
    try? FileManager.default.removeItem(at: file)
    return true
}

/// Whether one of this account's claims already names this drought, dropping the ones from droughts
/// that are over while it looks so the directory does not grow one file per window cycle forever.
///
/// Both halves are the same walk over the same files and they answer with the same rule, so they are
/// one pass rather than two: a claim is either this drought's, in which case it is held and must
/// never be swept, or it is another one's, in which case it is dead the moment its reset is behind
/// us. Expiring records while reading them is what the quarantine next door does, for the reason
/// this shares - the only moment anyone cares about a stale record is the moment they read past it.
///
/// A claim within the tolerance is kept even when its reset is behind us, because that is the case
/// the tolerance is FOR: a reset time the snapshot has not caught up with is in the past and still
/// the drought we are in. The real re-arm is the next window, which is hours away and nowhere near.
///
/// A directory that cannot be listed answers HELD, not "no claims". Reading the failure as an empty
/// directory is the one way this can hand out a move it has no evidence for, and every other
/// obstacle here already answers "stay put": the cost of a wrong refusal is the cap handoff doing
/// the same move later, the cost of a wrong grant is the whole account's sessions on one sibling.
private func rebalanceCycleHeld(_ accountID: String, cycle: String, dir: URL,
                                now: Date = Date()) -> Bool {
    let prefix = rebalanceRecordName(accountID)
    guard let files = try? FileManager.default.contentsOfDirectory(at: dir,
        includingPropertiesForKeys: nil) else { return true }
    var held = false
    for file in files {
        let name = file.lastPathComponent
        guard let dot = name.lastIndex(of: "."), String(name[..<dot]) == prefix else { continue }
        let stored = String(name[name.index(after: dot)...])
        guard let epoch = Double(stored) else { continue }
        if namesSameDrought(stored, cycle) {
            held = true
        } else if Date(timeIntervalSince1970: epoch) < now {
            try? FileManager.default.removeItem(at: file)
        }
    }
    return held
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

/// The gates that need nothing but what the caller already holds - no snapshot, no account, no
/// filesystem - in the order they bite. They are the first four of the list documented under
/// `rebalanceTarget` below, and one definition answers both readers: that decision asks them, and
/// `rebalanceMove` asks them again BEFORE its snapshot read, so a tick that could not move this
/// session anyway never pays for the read. Two copies of this list would be free to disagree, and
/// the copy that fell behind would silently refuse moves the real gate allows.
func rebalanceAllowedForSession(mode: String, isQuiet: Bool, carryable: Bool,
                                fuseAllows: Bool) -> Bool {
    mode != "manual" && isQuiet && carryable && fuseAllows
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
///  - `carryable`: whether moving this session can lose a conversation (`carryableSession`,
///    SupervisorRuntime.swift). Crossing accounts costs a resume id: `performHandoff` strips
///    `--continue` on a move by design, because on the target account that flag names a different
///    conversation entirely, so a session that was told to resume something, and whose transcript
///    is not bound yet, would come back blank. A session that never asked to resume anything is
///    carried by definition - there is nothing to bring - and gating it too would strand brand new
///    sessions on a dying account for nothing. The cap handoff never needed any of this stated: its
///    evidence is a line IN the transcript, so it cannot run before the session is locatable. That
///    is exactly why this reads like a gate nobody wrote - every OTHER mover was protected by an
///    accident of what triggers it, and this one is triggered by quota, which knows nothing about
///    conversations. (2026-08-02: the reload restart, then this, then the fresh-session half.)
///  - `fuseAllows`: automatic moves share one budget with cap recoveries.
///  - the account is not comfortable: the same gate the pick uses, so "dying" means one thing in
///    this repo. It already exempts a window about to refill, so 9% resetting in five minutes is
///    correctly read as a full window rather than as a reason to move.
///  - `claim`: the cross-supervisor per-cycle claim above, and deliberately LAST. It is the only
///    gate with a side effect, so asking it earlier would spend this account's one move of the cycle
///    on a tick that then declines to move (a pinned session, a session mid-turn, nowhere better to
///    go), and the account would sit un-rebalanceable until its window reset.
///
/// `carryable` is declared AFTER `isQuiet` on purpose, and every caller passes it after too: Swift
/// evaluates an argument list in source order, so the expression that runs the transcript locate
/// (`watcher.isQuiet(...)`) is guaranteed to have run before the one that reads its result
/// (`watcher.file != nil`). Reversed, the caller would be reading a binding that had not been
/// attempted yet, and the gate would refuse every first tick for no reason. There is no default:
/// a mover that has not thought about whether it can carry the conversation is the bug itself.
func rebalanceTarget(mode: String, isQuiet: Bool, carryable: Bool, fuseAllows: Bool,
                     current: Snapshot.Account, candidates: [Snapshot.Account],
                     primaryModel: String?, now: Date = Date(),
                     claim: () -> Bool = { true }) -> Snapshot.Account? {
    guard rebalanceAllowedForSession(mode: mode, isQuiet: isQuiet, carryable: carryable,
                                     fuseAllows: fuseAllows),
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
///
/// `loaded` is that snapshot read, injectable so the whole decision is testable without a home
/// directory, and `@autoclosure` so a tick that will not use it does not pay for it: a plain default
/// argument is evaluated at the CALL SITE, before this function is entered, and this one is called on
/// every tick that has no other relaunch planned - which is nearly all of them. Reading and decoding
/// `~/.tally/snapshot.json` every 2 seconds per supervised session, for a branch whose own gates
/// (`mode == "manual"`, a session in use, a comfortable account) throw the answer away moments later,
/// is a cost nobody asked for. Same fix, same reason, as `applyCapHandoff` (CapDetection.swift);
/// `observeCapHit` reaches it a third way, with a plain closure it calls only on the tick a cap
/// lands, which is the same property spelled differently and deliberately left alone.
func rebalanceMove(provider: String, account: Snapshot.Account, primaryModel: String?,
                   mode: String, isQuiet: Bool, carryable: Bool, fuseAllows: Bool,
                   quarantine: [String: (model: String?, until: Date)] = [:],
                   loaded: @autoclosure () -> (Snapshot?, String?) = loadSnapshot(),
                   now: Date = Date(),
                   dir: URL = rebalanceDir) -> Snapshot.Account? {
    // The gates that cost nothing come first, so the read below is only paid for by a tick that
    // could actually move this session. `mode` is the one that bites most: a pinned session (the
    // app's pin, this project's profile, or a `tally switch` of its own) never rebalances, and it
    // asks nothing of the filesystem to know that. Asked through the shared predicate, never
    // re-spelled: `rebalanceTarget` asks the same four again with the same answer, so this can only
    // ever be an early exit, never a second opinion.
    guard rebalanceAllowedForSession(mode: mode, isQuiet: isQuiet, carryable: carryable,
                                     fuseAllows: fuseAllows) else { return nil }
    let (snapshot, problem) = loaded()
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
        mode: mode, isQuiet: isQuiet, carryable: carryable, fuseAllows: fuseAllows,
        current: live, candidates: candidates, primaryModel: primaryModel, now: now,
        claim: { claimRebalanceCycle(account.id, cycle: cycle, dir: dir) })
}
