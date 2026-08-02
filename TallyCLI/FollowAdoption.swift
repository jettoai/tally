import Foundation

// Following the launch default: changing "Default model & effort" in Settings re-points a RUNNING
// session at the next quiet moment.
//
// Lifted out of the poll loop (Supervisor.swift is at the repo's file-size cap) in the shape the
// tick's other deferred decisions already use: the state it owns comes in as one `inout` value, the
// plan it may write comes in as another, and everything else it consults is injected, so the whole
// decision is reachable in a test without spawning a child. `applyReloadRequest` (Reload.swift) and
// `applySafeguardRestore` (SafeguardDrift.swift) are the same shape.
//
// One structural gain from being a function rather than a labeled block: the dead-end path leaves
// the adoption with a plain `return`, and the loop-skipping statement that once caused a real defect
// here cannot compile outside a loop at all (2026-07-25: a session waiting on an unservable model
// never even acknowledged a `tally reload`). That invariant used to rest on a label being used
// correctly; a test still asserts it, by a word search that cannot tell prose from code, which is
// why the statement is described rather than named anywhere in this file.

/// Follow debounce: a short floor now that Settings writes the model+effort pair atomically on
/// Apply (it used to arrive as two writes seconds apart, needing a 10s window to coalesce). The
/// floor only guards against adopting a transient mid-write; the atomic write means one Apply is
/// one relaunch regardless.
let followDebounce: TimeInterval = 2

/// Everything the follow adoption remembers between ticks. Held by the supervisor across relaunches
/// (like the fuse and the quarantine), because the question "has the configured default changed
/// since this session adopted one" outlives any single child.
struct FollowState {
    /// The launch-default pair (model, effort) this session currently runs on. A Settings change
    /// is adopted only when the desired pair differs from this one, and this updates on adopt, so
    /// each change fires exactly once and an unchanged policy never churns. The fallback profile
    /// rewrites launchArgs without touching these, so a fallback in effect does not retrigger.
    var followedModel: String?
    var followedEffort: String?
    var pendingModel: String?
    var pendingEffort: String?
    var pendingSince: Date?
    /// True once the "will adopt when idle" note has been shown for the current pending pair, so a
    /// session that is being used does not repeat it every tick.
    var queuedNotice = false
    /// True while a follow adoption has nowhere to land (no account can serve the new model), so
    /// the "waiting" note is shown once, not every tick. Cleared when an account frees up.
    var deadEnd = false

    /// Seeded from the command line this session launched with: a hand-typed `--model` IS the pair
    /// the session runs, so a Settings default that already matches it is not a change to adopt.
    init(launchArgs: [String]) {
        followedModel = flagValue(launchArgs, "--model")?.lowercased()
        followedEffort = flagValue(launchArgs, "--effort")?.lowercased()
    }
}

/// One tick's follow decision. Deliberate, so no fuse. Adoption waits until the desired pair holds
/// steady for `followDebounce` (model and effort are picked one after the other), UNLESS a relaunch
/// is already planned this tick - then it folds in for free (one SIGTERM). In auto mode the session
/// re-picks its account for the NEW model (incumbent-seeded, so a still-serviceable account never
/// churns; the 02:22 storm relaunched onto an account with no room for the new model).
/// Manual/pinned never switches account, and a dead end (no account can serve the new model) waits
/// instead of relaunching onto a wall.
///
/// `following` is false when the user typed their own `--model` or passed `--no-follow`: there is no
/// default to follow then, and the state is left untouched.
/// `snapshot` is injected for the same reason the keyboard is: the auto-mode re-pick is the one
/// branch that reads the fleet, and a test that cannot decide what the fleet looks like cannot reach
/// the dead end deliberately. It defaults to the real read, so the tick calls this unchanged.
func applyFollowAdoption(plan: inout RelaunchPlan?, state: inout FollowState, following: Bool,
                         policy: LaunchPolicy, account: Snapshot.Account, providerID: String,
                         launchArgs: [String],
                         quarantine: [String: (model: String?, until: Date)],
                         watcher: inout TranscriptWatcher,
                         keyboardIdle: (TimeInterval) -> Bool,
                         snapshot loadSnapshotting: () -> (Snapshot?, String?) = loadSnapshot) {
    guard following else { return }
    let desired = (policy.model?.lowercased(), policy.effort?.lowercased())
    // Nothing to adopt: the pair follow last set, or one that another rewrite already
    // put on the command line while leaving this baseline stale (the reasoning lives
    // with `followAlreadySatisfied` in SupervisorRuntime.swift). Re-point the baseline
    // and say nothing - queueing here promises a relaunch that would change nothing.
    if desired == (state.followedModel, state.followedEffort)
        || followAlreadySatisfied(desiredModel: desired.0, desiredEffort: desired.1,
                                  launchArgs: launchArgs) {
        (state.followedModel, state.followedEffort) = desired
        state.pendingSince = nil
        state.queuedNotice = false
    } else if state.pendingSince == nil || desired != (state.pendingModel, state.pendingEffort) {
        (state.pendingModel, state.pendingEffort) = desired
        state.pendingSince = Date()
        state.queuedNotice = false
    } else if let since = state.pendingSince,
              // A relaunch already planned this tick carries the new pair for free, so
              // it never waits: the SIGTERM is happening either way. A follow standing
              // on its own is the only one that interrupts, so it waits for genuine
              // idleness: file AND keyboard, since a typed prompt reaches neither yet.
              plan != nil || (Date().timeIntervalSince(since) >= followDebounce
                              && watcher.isQuiet(followIdleSeconds)
                              && keyboardIdle(followIdleSeconds)) {
        if var existing = plan, !existing.followFolded {
            existing.model = policy.model
            existing.effort = policy.effort
            existing.followFolded = true
            plan = existing
            warn("also adopting launch default \(policy.model ?? "default")/" +
                 "\(policy.effort ?? "default")")
            (state.followedModel, state.followedEffort) = desired
            state.pendingSince = nil
        } else if plan == nil {
            let repick: Snapshot.Account?
            if policy.mode == "manual" {
                repick = account
            } else {
                let (snapshot, problem) = loadSnapshotting()
                let excluded = quarantinedAccounts(forPrimary: policy.model,
                                                   sessionLocal: quarantine)
                // Numbers too old to trust move nobody, the rule the cap handoff and the idle
                // rebalance both follow: a pick made on hours-old quota is how a session lands
                // somewhere worse than it started. Staying is not the same as refusing, though -
                // the adoption still happens, on this account, because a Settings change that
                // silently does nothing is the defect this file exists to have fixed.
                repick = problem == nil
                    ? snapshot.flatMap {
                        incumbentSeededBest(providerID: providerID, in: $0,
                                            incumbentID: account.id, primaryModel: policy.model,
                                            excluding: excluded)
                    }
                    : account
            }
            guard let repick else {
                state.deadEnd = true
                return
            }
            state.deadEnd = false
            warn("launch default changed to \(policy.model ?? "default")/" +
                 "\(policy.effort ?? "default") → adopting it" +
                 (repick.id != account.id ? " on \(repick.label)" : ""))
            plan = RelaunchPlan(target: repick, reason: "follow", countsFuse: false,
                                model: policy.model, effort: policy.effort)
            (state.followedModel, state.followedEffort) = desired
            state.pendingSince = nil
        }
    } else {
        // Queued behind an in-use session: the badge carries it, so the change never
        // looks lost and nothing is printed over the prompt being typed.
        state.queuedNotice = true
    }
}
