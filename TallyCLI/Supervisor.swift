import Darwin
import Foundation

// Auto-handoff supervision (Phase B).
//
// `tally claude` stays resident as a thin parent around the interactive claude child. It tails the
// session transcript for a cap-hit event; on a hit it terminates the child, re-picks the best other
// account, and relaunches `claude --resume <session>` in the same terminal - the conversation
// continues on the fresh account with no manual step. The transcript tailer that detects the cap
// lives in TranscriptWatcher.swift; the value types and pure helpers in SupervisorRuntime.swift.

/// Resident supervision: spawn claude, tail its transcript, hand off on a cap hit.
///
/// `follow`: adopt a later change to the launch-default model at the next quiet moment. The caller
/// sets it false when the user typed their own `--model` or passed `--no-follow`.
///
/// `recoveries`: the recovery fuse this session had already spent, handed over by the supervisor
/// this process replaced in a self-update. Empty for every normal launch.
func runSupervised(_ provider: Provider, account initial: Snapshot.Account, args: [String],
                   follow: Bool = false, recoveries: [Date] = []) -> Never {
    let slug = projectSlug(forCwd: FileManager.default.currentDirectoryPath)

    // The parent must survive Ctrl+C - claude uses SIGINT to interrupt a turn, and the whole
    // foreground process group (which the child shares) receives it.
    signal(SIGINT, SIG_IGN)
    signal(SIGQUIT, SIG_IGN)

    var account = initial
    var launchArgs = args.filter { $0 != "--no-handoff" && $0 != "--no-follow" }
    /// The fallback profile fires at most once per session.
    var fallbackApplied = false
    /// The launch-default pair (model, effort) this session currently runs on. A Settings change
    /// is adopted only when the desired pair differs from this one, and this updates on adopt, so
    /// each change fires exactly once and an unchanged policy never churns. The fallback profile
    /// rewrites launchArgs without touching these, so a fallback in effect does not retrigger.
    var followedModel = flagValue(launchArgs, "--model")?.lowercased()
    var followedEffort = flagValue(launchArgs, "--effort")?.lowercased()
    /// Follow debounce: a short floor now that Settings writes the model+effort pair atomically on
    /// Apply (it used to arrive as two writes seconds apart, needing a 10s window to coalesce). The
    /// floor only guards against adopting a transient mid-write; the atomic write means one Apply is
    /// one relaunch regardless.
    let followDebounce: TimeInterval = 2
    var pendingSince: Date?
    var pendingModel: String?
    var pendingEffort: String?
    /// True once the "will adopt when idle" note has been shown for the current pending pair, so a
    /// session that is being used does not repeat it every tick.
    var followQueuedNotice = false
    /// True while a follow adoption has nowhere to land (no account can serve the new model), so
    /// the "waiting" note is shown once, not every tick. Cleared when an account frees up.
    var followDeadEnd = false
    /// The recovery fuse for THIS session, held across relaunches AND across a self-update exec
    /// (seeded from `recoveries`): at most 3 automatic cross-account recoveries per 10 minutes (a
    /// cap handoff or a degradation rescue). In memory and per session, so a fleet-wide drain never
    /// trips one session on another's account switches, while an app update mid-session cannot
    /// hand this one a fresh budget. Deliberate moves (pin, follow) and same-account relaunches
    /// (fallback) do not count.
    var fuse = RecoveryFuse(recovered: recoveries)
    /// Accounts THIS supervisor saw cap, with the model window that capped, excluded from its own
    /// automatic picks for that model until the TTL passes (union with the cross-supervisor shared
    /// records). Persists across relaunches.
    var quarantine: [String: (model: String?, until: Date)] = [:]
    /// The `tally reload` stamp this supervisor has already served. Captured at startup so an older
    /// request is never replayed - a child spawned now already carries the edited hooks, skills, and
    /// instructions the request was about. Held across relaunches, like the fuse and the quarantine.
    var reloadEpoch = readReloadRequest()?.epoch ?? 0
    /// What has been said about a queued reload: the stamp it was said for, so a session in use
    /// says it once, and when the wait began, so a wait past five minutes says so once more.
    var reloadNotice = ReloadWait()
    /// A pending cap recovery handed from one child to the next (see `capCarriedAcrossRelaunch`).
    var carriedCap: PendingCapRecovery?
    /// Stamped into the child env so the status line can tell whether the supervisor watching this
    /// session is the current build (a session launched before an app update runs stale logic).
    let supervisorVersion = supervisorBuildVersion()
    /// The version a self-update exec was aiming for: read from the environment when this process
    /// IS that exec, and written again when this process attempts one of its own.
    var selfUpdateAttempted = consumeSelfUpdateAttempt()
    let supervisorPID = String(getpid())
    // Reap drift-state files left by dead supervisors (a SIGKILL skips the clear path) before this
    // one starts writing its own; also shrinks the pid-reuse window for a stale badge.
    sweepDeadSupervisorState()
    // Register in the same directory as a live supervisor (an empty file; a drift episode fills it
    // in later): `tally reload` counts these to say how many sessions its request will restart.
    markSupervisorLive(pid: supervisorPID)

    while true {
        let launchedAt = Date()
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: provider.envKey)
        // The status line reads this to show "this session runs under Tally" (✦).
        environment["TALLY_LAUNCHED"] = "1"
        if let supervisorVersion { environment["TALLY_SUPERVISOR_VERSION"] = supervisorVersion }
        environment["TALLY_SUPERVISOR_PID"] = supervisorPID
        if let env = launchEnv(provider, home: account.launchHome!) {
            environment[env.key] = env.value
        }
        guard let childPID = spawnChild([provider.cli] + launchArgs, environment: environment) else {
            warn("cannot launch `\(provider.cli)`")
            exit(127)
        }

        // One-shot reaper around waitpid: WNOHANG polls, blocking waits, and the status is
        // remembered because a reaped pid cannot be waited on twice.
        var childStatus: Int32?
        func pollChild() {
            guard childStatus == nil else { return }
            var status: Int32 = 0
            if waitpid(childPID, &status, WNOHANG) == childPID { childStatus = status }
        }
        func awaitChild() -> Int32 {
            if let childStatus { return childStatus }
            var status: Int32 = 0
            while waitpid(childPID, &status, 0) == -1, errno == EINTR {}
            childStatus = status
            return status
        }

        var watcher = TranscriptWatcher(
            projectDir: URL(fileURLWithPath: account.launchHome!).appendingPathComponent("projects/\(slug)"),
            since: launchedAt,
            resumeID: flagValue(launchArgs, "--resume") ?? flagValue(launchArgs, "-r"))
        var handoff = false

        // Terminate the child and set up the relaunch on `target` - shared by cap-hit handoffs
        // and live UI pin switches. Continues the SAME conversation when one exists; a session
        // with no transcript yet just starts fresh on the target (any --continue/--resume flags
        // are stripped so it can't pull up an unrelated old conversation there).
        // `countingFuse` records against the per-supervisor fuse: true for AUTOMATIC recoveries
        // (cap handoff, degradation rescue), false for deliberate or same-account relaunches (pin
        // switch, follow adoption, fallback profile) - a Settings change must not eat the budget a
        // real cap hit may need minutes later. `reason` is the audit-log tag only.
        func performHandoff(to target: Snapshot.Account, reason: String, countingFuse: Bool = true) {
            let fromLabel = account.label
            // Read before `account` moves: a same-account relaunch (fallback profile, reload) keeps
            // a `--continue` the watcher cannot yet turn into a session id; a real move drops it.
            let sameAccount = target.id == account.id
            kill(childPID, SIGTERM)   // let claude run its SessionEnd cleanup
            _ = awaitChild()
            clearDriftState(pid: supervisorPID)   // a new child gets a fresh drift monitor

            // Forced, because the id this resumes must be the file the conversation is actually in:
            // a child that moved (a `/clear`, a resume that forked) leaves the pinned file dead, and
            // resuming that one orphans every turn written since (twice in one afternoon,
            // 2026-07-26; the rule lives in TranscriptWatcher.swift).
            watcher.locateFile(forceForkCheck: true)
            let sessionFile = watcher.file
            if let sessionFile {
                shareTranscript(sessionFile, toHome: target.launchHome!, slug: slug)
            }

            logHandoff(sessionID: sessionFile?.deletingPathExtension().lastPathComponent,
                       from: fromLabel, to: target.label, reason: reason)
            if countingFuse { fuse.record() }
            account = target
            launchArgs = relaunchArgs(
                launchArgs,
                sessionID: sessionFile?.deletingPathExtension().lastPathComponent,
                sameAccount: sameAccount)
            handoff = true
        }

        // A cap this child could not hand off yet: remembered across poll ticks so a blocked
        // handoff retries instead of stranding the session. Reset per child - a fresh launch is
        // a clean slate; the previous account's cap is not this one's - except for what the last
        // relaunch chose to hand over, which is consumed here so it can never leak further.
        var pendingCap = carriedCap
        carriedCap = nil
        // Per-child drift tracking: the safeguard episode is this session's, and a handoff starts a
        // fresh child (and a fresh monitor). Its state file is cleared on handoff and on exit.
        var drift = DriftMonitor()
        // Per-child keyboard history. Fed once per tick below, because what the non-urgent gates
        // need is whether stamps arrive in RUNS (typing) or alone (terminal chatter), and that is
        // only visible across successive readings (KeyboardIdle.swift).
        var keyboard = KeyboardActivity()

        pollChild()
        while childStatus == nil {
            usleep(2_000_000)
            pollChild()
            guard childStatus == nil else { break }
            // Before any relaunch decision reads it: every gate below asks the same tracker, and it
            // only learns anything by being given each tick's reading.
            keyboard.observe(stamp: lastKeyboardInput())
            let policy = launchPolicy(provider.id)
            // What THIS session is expected to run: a hand-typed --model outranks the configured
            // default (a deliberate haiku session must not be "rescued" back to fable). Read by the
            // drift monitor and the quota-degradation paths alike.
            let effectivePrimary = flagValue(launchArgs, "--model") ?? policy.model
            // The single relaunch this tick will perform, if any. Reasons fire in priority order
            // (pin > cap > degradation > fallback) and the FIRST owns the account move; a follow
            // adoption only folds its model/effort onto that target. Executed once at the tick's
            // end, so a cap and a Settings Apply landing together kill the child exactly once.
            var plan: RelaunchPlan?

            // Cap recovery has top priority: scan for the cap BEFORE any relaunch path (pin,
            // follow, rescue, fallback), because a relaunch resets the watcher's `since` and would
            // filter the cap event as old history and lose it (2026-07-24). The scan also refreshes
            // the model-degradation signal the rescue/fallback blocks below read.
            let sawCap = watcher.sawCapHit()
            // The session came back on its own - a real assistant turn on the main chain, newer
            // than the cap (the account's window refilled, or the user waited the cooldown out) -
            // so a later genuine cap starts fresh.
            if let pending = pendingCap, let recovered = watcher.lastMainChainEventAt,
               recovered > pending.cappedAt {
                warn("\(account.label) resumed on its own - cap recovery cleared")
                pendingCap = nil
            }
            if sawCap, pendingCap == nil {
                let capModel = flagValue(launchArgs, "--model") ?? policy.model
                pendingCap = PendingCapRecovery(
                    cappedAccountID: account.id, cappedAt: Date(),
                    primaryModel: capModel, nextRetry: .distantPast, reason: "")
                // Keep every session (this one and any launching now) off the account for the model
                // window that just capped until its snapshot catches up - a different model the
                // account still serves is not blocked.
                let until = Date().addingTimeInterval(capQuarantineTTL)
                quarantine[account.id] = (model: capModel, until: until)
                quarantineAccount(account.id, model: capModel, until: until)
            }

            // Model-drift observation: surface a Fable safeguard fallback and gate the
            // quota-degradation paths below with `drift.isActive` (DriftMonitor.swift).
            observeDrift(&drift, watcher: &watcher, primary: effectivePrimary, pid: supervisorPID)

            // Live pin switch: pinning another account in the Tally panel moves the RUNNING
            // session there. An explicit human act, so no fuse; the pinned account is used even
            // when capped (that is what pinning means). Waits for a quiet transcript so an
            // in-flight response is never cut mid-stream (the next 2s poll retries) and a quiet
            // keyboard so a prompt being typed survives too; both default to the same 5s bar.
            if policy.mode == "manual", let pinnedID = policy.pinnedAccountID, pinnedID != account.id,
               watcher.isQuiet(), keyboard.idle() {
                let (snapshot, _) = loadSnapshot()
                if let target = snapshot?.accounts.first(where: {
                    $0.id == pinnedID && $0.provider == provider.id && $0.launchHome != nil
                }) {
                    warn("pinned in Tally → switching to \(target.label)")
                    plan = RelaunchPlan(target: target, reason: "pin", countsFuse: false)
                }
            }

            // Cap handoff / wait: a pending cap outranks follow, rescue, and fallback for the
            // account MOVE (the pin switch above still wins). The backoff gate and the "waiting"
            // branch only skip the cap HANDOFF ATTEMPT, never the rest of the tick: a blocked cap
            // (no eligible target) must still let the follow block below run, so a single-account
            // user who caps and then switches Settings to a model with headroom actually adopts it
            // (the main UX complaint from the 2026-07-24 incident). rescue/fallback stay gated by
            // `plan == nil`.
            if plan == nil, var pending = pendingCap, Date() >= pending.nextRetry {
                let (snapshot, snapshotProblem) = loadSnapshot()
                let primary = pending.primaryModel
                let excluded = quarantinedAccounts(forPrimary: primary, sessionLocal: quarantine)
                // The nearly-dry gate, stricter here than on the launch path (AccountComfort.swift):
                // handing a capped session to an account with 1% left just caps it again a few
                // minutes later, and unlike a launch there is a running conversation to reload, so
                // no comfortable sibling means WAIT rather than move. One `now` for the gate and the
                // ordering so they agree.
                let pickedAt = Date()
                let eligibleAccounts = (snapshot?.accounts ?? []).filter {
                    $0.provider == provider.id && eligible($0, primaryModel: primary)
                        && $0.id != account.id && !excluded.contains($0.id)
                }
                let target = capHandoffTarget(eligibleAccounts, primaryModel: primary, now: pickedAt)
                let action = capRecoveryAction(mode: policy.mode, fuseAllows: fuse.allows(),
                                               snapshotStale: snapshotProblem != nil,
                                               hasTarget: target != nil)
                if action == .handoff, let target {
                    warn("cap hit → handing off to \(target.label) " +
                         "(\(pickReason(target, primaryModel: primary)))")
                    // Own the account move; a follow adoption below folds its pair into this plan.
                    plan = RelaunchPlan(target: target, reason: "cap", countsFuse: true)
                } else {
                    if let note = action.waitingNote, note != pending.reason {
                        warn("\(account.label) capped, \(note)")
                        pending.reason = note
                    }
                    pending.nextRetry = Date().addingTimeInterval(capRetryBackoff)
                    pendingCap = pending
                }
            }

            // Follow the launch default: changing "Default model & effort" in Settings re-points a
            // RUNNING session. Deliberate, so no fuse. Adoption waits until the desired pair holds
            // steady for `followDebounce` (model and effort are picked one after the other), UNLESS
            // a relaunch is already planned this tick - then it folds in for free (one SIGTERM). In
            // auto mode the session re-picks its account for the NEW model (incumbent-seeded, so a
            // still-serviceable account never churns; the 02:22 storm relaunched onto an account
            // with no room for the new model). Manual/pinned never switches account, and a dead end
            // (no account can serve the new model) waits instead of relaunching onto a wall.
            // Labeled so a dead end can abandon the ADOPTION without abandoning the tick: it used
            // to `continue`, which also skipped the reload check below, so a reload request against
            // a session waiting on an unservable model was never even acknowledged (2026-07-25).
            followAdoption: if follow {
                let desired = (policy.model?.lowercased(), policy.effort?.lowercased())
                // Nothing to adopt: the pair follow last set, or one that another rewrite already
                // put on the command line while leaving this baseline stale (the reasoning lives
                // with `followAlreadySatisfied` in SupervisorRuntime.swift). Re-point the baseline
                // and say nothing - queueing here promises a relaunch that would change nothing.
                if desired == (followedModel, followedEffort)
                    || followAlreadySatisfied(desiredModel: desired.0, desiredEffort: desired.1,
                                              launchArgs: launchArgs) {
                    (followedModel, followedEffort) = desired
                    pendingSince = nil
                    followQueuedNotice = false
                } else if pendingSince == nil || desired != (pendingModel, pendingEffort) {
                    (pendingModel, pendingEffort) = desired
                    pendingSince = Date()
                    followQueuedNotice = false
                } else if let since = pendingSince,
                          // A relaunch already planned this tick carries the new pair for free, so
                          // it never waits: the SIGTERM is happening either way. A follow standing
                          // on its own is the only one that interrupts, so it waits for genuine
                          // idleness: file AND keyboard, since a typed prompt reaches neither yet.
                          plan != nil || (Date().timeIntervalSince(since) >= followDebounce
                                          && watcher.isQuiet(followIdleSeconds)
                                          && keyboard.idle(followIdleSeconds)) {
                    if var existing = plan, !existing.followFolded {
                        existing.model = policy.model
                        existing.effort = policy.effort
                        existing.followFolded = true
                        plan = existing
                        warn("also adopting launch default \(policy.model ?? "default")/" +
                             "\(policy.effort ?? "default")")
                        (followedModel, followedEffort) = desired
                        pendingSince = nil
                    } else if plan == nil {
                        let repick: Snapshot.Account?
                        if policy.mode == "manual" {
                            repick = account
                        } else {
                            let (snapshot, _) = loadSnapshot()
                            let excluded = quarantinedAccounts(forPrimary: policy.model,
                                                               sessionLocal: quarantine)
                            repick = snapshot.flatMap {
                                incumbentSeededBest(providerID: provider.id, in: $0,
                                                    incumbentID: account.id, primaryModel: policy.model,
                                                    excluding: excluded)
                            }
                        }
                        guard let repick else {
                            if !followDeadEnd {
                                warn("launch default changed to \(policy.model ?? "default"), but no " +
                                     "eligible account can serve it yet - waiting")
                                followDeadEnd = true
                            }
                            break followAdoption
                        }
                        followDeadEnd = false
                        warn("launch default changed to \(policy.model ?? "default")/" +
                             "\(policy.effort ?? "default") → adopting it" +
                             (repick.id != account.id ? " on \(repick.label)" : ""))
                        plan = RelaunchPlan(target: repick, reason: "follow", countsFuse: false,
                                            model: policy.model, effort: policy.effort)
                        (followedModel, followedEffort) = desired
                        pendingSince = nil
                    }
                } else if !followQueuedNotice {
                    // Queued behind an in-use session: say so once, so the change never looks lost.
                    warn("launch default changed to \(policy.model ?? "default")/" +
                         "\(policy.effort ?? "default") - adopting when this session goes idle")
                    followQueuedNotice = true
                }
            }

            // The session's ACTUAL model degraded away from the declared primary (claude fell
            // back server-side - e.g. the flagship weekly ran dry). Flagship-first response:
            // a sibling whose flagship window still has real room takes the conversation and
            // KEEPS the primary model. Not for pinned sessions (a pin means "this account"),
            // and under the same fuse as every automatic handoff.
            // The expectation is what THIS session was launched with (a hand-typed --model
            // outranks the configured default - a deliberate haiku session must not be
            // "rescued" back to fable). Skipped during a safeguard drift: that switch is the
            // API's deliberate fallback, not a quota drain a sibling account would cure.
            if plan == nil, !drift.isActive, let primary = effectivePrimary?.lowercased(),
               let actual = watcher.lastModel?.lowercased(),
               !actual.contains(primary), policy.mode != "manual", fuse.allows(),
               watcher.isQuiet() {
                let (snapshot, _) = loadSnapshot()
                // Account-switching only cures QUOTA degradation. If THIS account's flagship
                // window still has real room, the cause is something a sibling shares too
                // (live case 2026-07-20: the session's context outgrew the flagship's
                // subscription tier - every account hits that same wall), so switching would
                // just churn the fuse. Skip; if quota IS the cause, the next poll's snapshot
                // shows this account dry and the rescue proceeds. Score the target against the
                // EFFECTIVE primary (a hand-typed --model outranks the configured default).
                let currentDry = (snapshot?.accounts
                    .first { $0.id == account.id }?.modelRemaining).map { $0 <= 5 } ?? true
                let excluded = quarantinedAccounts(forPrimary: effectivePrimary,
                                                   sessionLocal: quarantine)
                let rescue = !currentDry ? nil : snapshot?.accounts
                    .filter { $0.provider == provider.id
                        && eligible($0, primaryModel: effectivePrimary)
                        && $0.id != account.id && ($0.modelRemaining ?? 0) > 5
                        && !excluded.contains($0.id) }
                    .max {
                        smartScore($0, primaryModel: effectivePrimary)
                            < smartScore($1, primaryModel: effectivePrimary)
                    }
                if let rescue {
                    warn("\(actual) took over from \(primary) → moving to \(rescue.label) " +
                         "to stay on \(primary) (\(pickReason(rescue, primaryModel: effectivePrimary)))")
                    plan = RelaunchPlan(target: rescue, reason: "degraded", countsFuse: true)
                }
            }

            // Fallback profile: no sibling can serve the primary model, so accept the
            // configured fallback - a weaker model can deserve a different depth and extra
            // flags, so relaunch ONCE with the fallback pairing - same account, same
            // conversation. Deliberate configuration, no fuse.
            if plan == nil, !drift.isActive, !fallbackApplied,
               let fallbackList = policy.fallbackModel,
               policy.fallbackEffort != nil || policy.fallbackArgs != nil,
               let actual = watcher.lastModel?.lowercased(),
               effectivePrimary.map({ !actual.contains($0.lowercased()) }) ?? true,
               let matched = fallbackList.split(separator: ",")
                   .map({ $0.trimmingCharacters(in: .whitespaces).lowercased() })
                   .first(where: { !$0.isEmpty && actual.contains($0) }),
               watcher.isQuiet() {
                warn("model fell back to \(actual) → applying fallback profile")
                let extra = policy.fallbackArgs?.split(separator: " ").map(String.init) ?? []
                plan = RelaunchPlan(target: account, reason: "fallback", countsFuse: false,
                                    model: matched, effort: policy.fallbackEffort, extraArgs: extra)
                fallbackApplied = true
            }

            // Safeguard-fallback restore: the API fell this session onto a fallback model and left
            // it at its own default depth, so put the declared depth back at an idle moment - on
            // the fallback model, never back on the one that tripped it (SafeguardDrift.swift).
            applySafeguardRestore(plan: &plan, drift: &drift, watcher: &watcher, account: account,
                                  policy: policy, launchArgs: launchArgs,
                                  fuseAllows: fuse.allows(), pid: supervisorPID,
                                  keyboardIdle: { keyboard.idle($0) })

            // Idle rebalance: this account has crossed the shared nearly-dry line while a sibling
            // has room, so move the session now, at an idle moment of its own choosing, instead of
            // mid-turn after it hits the wall. Lowest priority
            // of the account moves - every block above is repairing something, this one is only
            // preventing - and gated on the same fuse plus one move per account per window cycle
            // across supervisors, so those five sessions never stampede onto the one healthy
            // sibling. The rules live in Rebalance.swift.
            if plan == nil, let move = rebalanceMove(
                   provider: provider.id, account: account, primaryModel: effectivePrimary,
                   mode: policy.mode,
                   isQuiet: watcher.isQuiet(followIdleSeconds) && keyboard.idle(followIdleSeconds),
                   fuseAllows: fuse.allows(), quarantine: quarantine) {
                warn("\(account.label) nearly dry, moving to \(move.target.label) before the wall " +
                     "(\(pickReason(move.target, primaryModel: effectivePrimary)))")
                recordRebalance(account.id, cycle: move.cycle)
                plan = RelaunchPlan(target: move.target, reason: "rebalance", countsFuse: true)
            }

            // The app updated under this supervisor, so it now runs stale logic and stamps a stale
            // version into its child: replace THIS process with the new build (SelfUpdate.swift).
            // An upgrade on its own is a restart the session was not otherwise paying for, so it
            // waits for a real idle moment; it plans that restart like any other reason and the
            // block below performs the exec, so there is exactly one place the process is replaced.
            // Ahead of the reload check because an upgrade restarts the child too, so a pending
            // reload request is satisfied by the same act instead of costing a second restart.
            let childAge = Date().timeIntervalSince(launchedAt)
            if selfUpdateDue(
                   captured: supervisorVersion, attempted: selfUpdateAttempted,
                   isQuiet: reloadQuiet(transcriptQuiet: watcher.isQuiet(followIdleSeconds),
                                        hasTranscript: watcher.file != nil, childAge: childAge,
                                        bar: followIdleSeconds,
                                        keyboardQuiet: keyboard.idle(followIdleSeconds)),
                   relaunchPlanned: plan != nil, capPending: pendingCap != nil,
                   uptime: childAge, home: account.launchHome) != nil {
                plan = RelaunchPlan(target: account, reason: "self-update", countsFuse: false)
            }

            // `tally reload`: adopt a pending request, or note that it is waiting for this session
            // to go idle. The whole rule, and why it comes last, lives in Reload.swift.
            applyReloadRequest(plan: &plan, epoch: &reloadEpoch, notice: &reloadNotice,
                               account: account, watcher: &watcher,
                               childAge: Date().timeIntervalSince(launchedAt),
                               keyboardIdle: { keyboard.idle($0) })

            // Execute the tick's one relaunch: terminate the child once, then apply any
            // model/effort/extra flags this plan carries on top of the resumed args. A pending app
            // update rides along on THIS restart instead of waiting for an idle moment that only
            // starts counting again after it (a cap handoff at 06:34 and the self-update it
            // deferred at 06:36, session c80ebeb2, 2026-07-26). Decided before anything is
            // terminated, and against the account the plan moves TO, so the new build resumes the
            // conversation where this handoff is about to put it rather than on the old account.
            if let plan {
                carriedCap = capCarriedAcrossRelaunch(pendingCap, reason: plan.reason)
                let upgrade = selfUpdateFold(captured: supervisorVersion,
                                             attempted: selfUpdateAttempted,
                                             home: plan.target.launchHome,
                                             capCarried: carriedCap != nil)
                performHandoff(to: plan.target, reason: plan.reason, countingFuse: plan.countsFuse)
                launchArgs = planLaunchArgs(launchArgs, plan: plan)
                // Last, so an exec that fails falls through to the respawn below with this plan
                // fully applied: a failed upgrade can cost the new build, never the account switch.
                execPlannedSelfUpdate(upgrade, attempted: &selfUpdateAttempted, target: plan.target,
                                      follow: follow, recoveries: fuse.carried(), args: launchArgs)
                break
            }
        }

        if handoff { continue }
        let status = awaitChild()   // no relaunch pending: the child exited on its own, so do we
        removeSupervisorState(pid: supervisorPID)
        let exited = (status & 0x7f) == 0
        exit(exited ? (status >> 8) & 0xff : 128 + (status & 0x7f))
    }
}
