import Foundation

// Standing a planned relaunch down at the execution point, and giving back what planning it cost.
//
// The hold itself is in TranscriptFork.swift: while a transcript newer than the bound one cannot yet
// be told apart from the file the conversation moved to, restarting would resume the id from before
// the move. A planner that decides on its own asks that question through its own quiet gate, and the
// fork scan behind it is unthrottled, so under a live hold it never gets as far as planning. Two
// things still reach here: the `/clear` that lands in the microseconds BETWEEN a planner's gate and
// the moment the tick executes, and the follow adoption, which folds its pair onto a plan somebody
// else made and so asks no gate of its own. The forced scan in front of the execution catches both.
//
// Catching it is not free, and the first version of this check made it worse rather than better.
// Planning is not a pure decision: by the time a plan exists its owner has already written the
// bookkeeping that says "this is handled", so dropping the plan without dropping the bookkeeping
// loses the work outright. A `tally reload` was the case that proved it - `applyReloadRequest`
// records the served epoch as it plans, so a stood-down tick left the epoch consumed and the request
// was never planned again, for the life of the session. Silently: nothing is queued any more, so
// nothing says it is waiting either.
//
// Hence the shape below: capture what the planners may commit BEFORE any of them runs, put it back
// if the tick stands down. Only value state belongs here, and only state a planner writes while
// planning. Deliberately NOT captured:
//
//   - the transcript scan (`watcher.offset`, the cap it consumed): reading is not a commitment and
//     it cannot be un-read. A cap event is drained from the byte stream exactly once, so rolling
//     `pendingCap` back would DELETE a cap hit rather than defer it. Cap plans are exempt from the
//     hold for the same reason and never reach this path.
//   - the idle rebalance's cross-supervisor cycle claim (Rebalance.swift): it is a file another
//     process reads, so handing it back means deleting a claim under other supervisors mid-decision.
//     Left as it is, knowingly: reaching it needs the sub-tick race AND a drought AND a target, and
//     the cost when it happens is one preventive move deferred to the next cycle. Every other entry
//     here is the loss of something a user asked for; this one is a delay in something nobody did.
//
// The safeguard restore's handled-record used to belong on that list and no longer does, which is
// the better answer wherever it is available: it is a FILE, so no value snapshot here could have
// given it back, and a stood-down tick that left it behind burned that flag event for good - the
// session stayed at the wrong depth until the API happened to flag it again, if it ever did. It is
// now carried from the decision to the execution point and written only
// once the relaunch is certain (`PendingSafeguardRecord`, SafeguardDrift.swift). Anything new that
// commits while planning should go the same way: not writing until the act is certain leaves the
// cancel path with nothing to undo, and the next way to cancel a relaunch is safe by construction.
/// Built at the top of a tick, before the first planner runs.
struct TickCommitments {
    let reloadEpoch: Int
    let reloadNotice: ReloadWait
    let followState: FollowState
    let fallbackApplied: Bool

    /// Put every one of them back, so the next tick plans from where this one started.
    ///
    /// Whole-value restores rather than per-field ones: `FollowState` and `ReloadWait` also carry
    /// what has been SAID about a wait (the queued badge, the five-minute reminder), and a tick that
    /// did not happen should not have spoken either. The debounce clocks inside them restart, which
    /// costs one more debounce window and never loses a request.
    func restore(reloadEpoch: inout Int, reloadNotice: inout ReloadWait,
                 followState: inout FollowState, fallbackApplied: inout Bool) {
        reloadEpoch = self.reloadEpoch
        reloadNotice = self.reloadNotice
        followState = self.followState
        fallbackApplied = self.fallbackApplied
    }
}

/// Whether a relaunch this tick has already planned must stand down, asked at the execution point
/// against a FORCED fork scan - the sub-tick residue described above.
///
/// A cap answer is exempt, for the same reason it never waits for quiet: a session with no turn in
/// it cannot have hit a cap, so the conversation the cap belongs to is the bound file, and that is
/// what the relaunch has to resume. Holding it back would strand a capped session on a dry account
/// for as long as somebody leaves a fresh tab open.
///
/// BOTH of the cap's answers, which is what the prefix says: the handoff to a sibling (`cap`) and
/// the fallback pairing that keeps a hand-pinned session where it is (`cap-fallback`,
/// CapDetection.swift). They differ in what they change about the session and not at all in the
/// urgency of changing it.
func relaunchHeldByUnresolvedFork(reason: String, unresolvedFork: Bool) -> Bool {
    unresolvedFork && !reason.hasPrefix("cap")
}

/// The last look, and the tick's ONE answer to "is this child about to be replaced".
///
/// It exists because a second reader appeared for that answer, and the difference between the
/// question it asks and the one it is tempting to ask instead cost a whole feature: a PLANNED
/// relaunch is not a relaunch, because the hold above can stand it down and leave the child running.
/// The input gate (SessionInput.swift) was first wired to `plan != nil`, which reads a stood-down
/// tick as a relaunch and refuses to type - every tick, for as long as the fork stays unresolved.
/// And an unresolved fork is resolved by a TURN, which is the very thing `tally session send` is
/// asked to start: the gate closed the only door out of the state it was waiting on (codex review of
/// 1615990).
///
/// So the forced scan and the hold are asked ONCE, here, before either reader acts. Asking it early
/// costs the relaunch nothing: the two readers are mutually exclusive by construction (a tick that
/// relaunches types nothing, and a tick that types is not relaunching), so the gap this opens
/// between the scan and the tear-down is one file read rather than an injection's worth of seconds.
///
/// `watcher` is inout because the scan is forced: a `/clear` can land in the microseconds since the
/// planners each asked their own gate, and restarting then resumes the id from before it
/// (TranscriptFork.swift). It may also adopt a fork that has just stamped its marker, which is the
/// same insurance seen from the other side.
func relaunchIsHappening(plan: RelaunchPlan?, watcher: inout TranscriptWatcher) -> Bool {
    guard let plan else { return false }
    watcher.locateFile(forceForkCheck: true)
    return !relaunchHeldByUnresolvedFork(reason: plan.reason,
                                         unresolvedFork: watcher.hasUnresolvedFork)
}
