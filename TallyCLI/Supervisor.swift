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
///
/// `resumed`: this process took over a session that was ALREADY running (the self-update exec), so
/// even its first spawn is a relaunch. It decides one thing only, the resume-prompt suppression in
/// ResumePrompt.swift: nobody is at the keyboard for a restart Tally performed on its own.
func runSupervised(_ provider: Provider, account initial: Snapshot.Account, args: [String],
                   follow: Bool = false, recoveries: [Date] = [], resumed: Bool = false) -> Never {
    let slug = projectSlug(forCwd: FileManager.default.currentDirectoryPath)

    // The parent must survive Ctrl+C - claude uses SIGINT to interrupt a turn, and the whole
    // foreground process group (which the child shares) receives it.
    signal(SIGINT, SIG_IGN)
    signal(SIGQUIT, SIG_IGN)

    var account = initial
    // Tally's own flags, dropped from the OPTIONS only: past a `--` the same word is the user's
    // prompt, and filtering the whole vector edited what they said (Snapshot.swift).
    var launchArgs = removingOption(removingOption(args, "--no-handoff"), "--no-follow")
    /// The fallback profile fires at most once per session.
    var fallbackApplied = false
    /// Everything the launch-default follow remembers between ticks, seeded from this session's own
    /// command line (FollowAdoption.swift). Held across relaunches, like the fuse and the quarantine.
    var followState = FollowState(launchArgs: launchArgs)
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
    /// The status line's view of what this supervisor is waiting to do (PendingNotice.swift).
    var pendingNotice = PendingNoticeWriter()   // cleared when it exits, swept if it is killed
    /// How big this session's conversation has grown, published on the same track for `tally status`
    /// (SessionContext.swift). Outside the loop, like the notice: the session survives its children.
    var sessionContext = SessionContextWriter()
    /// Whether the next child is a RELAUNCH rather than the launch the user typed: every spawn
    /// after the first, and all of them when this process is a self-update taking a running session
    /// over. Read only by the resume-prompt suppression (ResumePrompt.swift).
    var relaunching = resumed
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
        // A relaunch resumes by id with nobody at the keyboard, so it must not stop at Claude Code's
        // "resume the whole conversation?" prompt; the user's own first launch keeps it
        // (ResumePrompt.swift).
        for (key, value) in resumePromptSuppression(environment, relaunch: relaunching) {
            environment[key] = value
        }
        if let env = launchEnv(provider, home: account.launchHome!) {
            environment[env.key] = env.value
        }
        guard let childPID = spawnChild([provider.cli] + launchArgs, environment: environment) else {
            warn("cannot launch `\(provider.cli)`")
            exit(127)
        }
        // Every child from here on is one this supervisor decided to start.
        relaunching = true

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
            // so a later genuine cap starts fresh. Unannounced: the cap badge disappearing is the
            // news, and the turn that just succeeded already told them.
            //
            // Or nobody typed and the window simply reset underneath the session, which that first
            // arm can never see: it needs an assistant turn, and an idle session produces none, so
            // the badge hung there naming an account that was back at 100%. The boundary it
            // compares against was fixed when the cap happened, so this reads no files at all
            // (SupervisorRuntime.swift explains why it cannot be recomputed here).
            if let pending = pendingCap,
               watcher.lastMainChainEventAt.map({ $0 > pending.cappedAt }) == true
                   || capRecoveredByReset(pending) {
                pendingCap = nil
            }
            if sawCap, pendingCap == nil {
                let capModel = flagValue(launchArgs, "--model") ?? policy.model
                // The cap's own instant, not the moment this 2s poll noticed it. The recovery
                // boundary is measured against this once and never recomputed, so the poll delay
                // would otherwise be enough to read a reset landing inside it as a stale stamp and
                // strand the session with no reset path at all (00:59:59 cap, 01:00:00 tick,
                // 01:00:00 reset). Falls back to now for a cap event carrying no timestamp.
                let cappedAt = watcher.capHitAt ?? Date()
                // The one snapshot read this path costs, taken while the evidence still exists: a
                // cap is rare, and the next refresh puts the window that capped back at 100%.
                pendingCap = PendingCapRecovery(
                    cappedAccountID: account.id, cappedAt: cappedAt, primaryModel: capModel,
                    recoveryResetsAt: capRecoveryDeadline(
                        accounts: loadSnapshot().0?.accounts ?? [], cappedAccountID: account.id,
                        primaryModel: capModel, cappedAt: cappedAt),
                    nextRetry: .distantPast, reason: "")
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
                    // The reason rides in the badge (the child keeps running, so nothing may be
                    // printed over it); it is held here so the badge only changes when it changes.
                    if let note = action.waitingNote { pending.reason = note }
                    pending.nextRetry = Date().addingTimeInterval(capRetryBackoff)
                    pendingCap = pending
                }
            }

            // Follow the launch default: a Settings change to "Default model & effort" re-points
            // this RUNNING session at the next quiet moment. The whole rule lives in
            // FollowAdoption.swift; what the tick supplies is the state, the plan it may fold into,
            // and the two things it has to ask about idleness.
            applyFollowAdoption(plan: &plan, state: &followState, following: follow, policy: policy,
                                account: account, providerID: provider.id, launchArgs: launchArgs,
                                quarantine: quarantine, watcher: &watcher,
                                keyboardIdle: { keyboard.idle($0) })

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
            // sibling. A target comes back only once this supervisor has CLAIMED that cycle, so
            // there is nothing to record here. The rules live in Rebalance.swift.
            // `carryable` sits after `isQuiet` because Swift evaluates an argument list in source
            // order: the locate happens inside `watcher.isQuiet`, and reading `watcher.file` before
            // it would ask about a binding nobody had attempted yet.
            if plan == nil, let moveTo = rebalanceMove(
                   provider: provider.id, account: account, primaryModel: effectivePrimary,
                   mode: policy.mode,
                   isQuiet: watcher.isQuiet(followIdleSeconds) && keyboard.idle(followIdleSeconds),
                   carryable: carryableSession(launchArgs: launchArgs,
                                               sessionLocated: watcher.file != nil),
                   fuseAllows: fuse.allows(), quarantine: quarantine) {
                warn("\(account.label) nearly dry, moving to \(moveTo.label) before the wall " +
                     "(\(pickReason(moveTo, primaryModel: effectivePrimary)))")
                plan = RelaunchPlan(target: moveTo, reason: "rebalance", countsFuse: true)
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
            // `repick`: a reload restart is a free ride off a nearly-dry account, so it offers the
            // same move the block above would make later. Asked lazily, inside the branch that
            // actually restarts, because answering takes this account's one claim for the drought.
            // `isQuiet: true` is not a bypass: the only caller of this closure is the branch reload
            // reaches when its OWN idle gate has already said yes.
            //
            // `carryable` is read HERE and captured, never inside the closure. `watcher` is passed
            // inout to the call the closure belongs to, so `watcher.file` read from within it is a
            // simultaneous access: measured 2026-08-02, that compiles without a word and traps at
            // runtime ("Simultaneous accesses ... modification requires exclusive access"). The
            // locate this reads is the tick's own, run unconditionally by `watcher.sawCapHit()` at
            // the top; reload can locate again inside, so the two can only disagree in the safe
            // direction (this says no, the session stays, the rebalance moves it later).
            let carryable = carryableSession(launchArgs: launchArgs,
                                             sessionLocated: watcher.file != nil)
            applyReloadRequest(plan: &plan, epoch: &reloadEpoch, notice: &reloadNotice,
                               account: account, watcher: &watcher,
                               childAge: Date().timeIntervalSince(launchedAt),
                               keyboardIdle: { keyboard.idle($0) }, carryable: carryable,
                               repick: {
                                   rebalanceMove(provider: provider.id, account: account,
                                                 primaryModel: effectivePrimary, mode: policy.mode,
                                                 isQuiet: true, carryable: carryable,
                                                 fuseAllows: fuse.allows(),
                                                 quarantine: quarantine)
                               })
            // How much context a resume of this conversation would reload, for the surfaces outside
            // this terminal (SessionContext.swift). Read off the scan the tick already ran.
            sessionContext.sync(tokens: watcher.lastContextTokens, accountID: account.id,
                                pid: supervisorPID)
            // The one thing this session is WAITING to do, for the status line: a deferral must
            // not be printed onto the terminal the child draws into (PendingNotice.swift).
            syncPendingNotice(&pendingNotice, pid: supervisorPID, reload: reloadNotice.pending,
                              followDeadEnd: followState.deadEnd, followQueued: followState.queuedNotice,
                              policy: policy, capReason: pendingCap?.reason)

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
        clearPendingNotice(pid: supervisorPID)
        clearSessionContext(pid: supervisorPID)
        let exited = (status & 0x7f) == 0
        exit(exited ? (status >> 8) & 0xff : 128 + (status & 0x7f))
    }
}
