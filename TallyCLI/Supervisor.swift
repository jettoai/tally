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
/// even its first spawn is a relaunch. Two things read it: the resume-prompt suppression in
/// ResumePrompt.swift (nobody is at the keyboard for a restart Tally performed on its own), and the
/// switch request's served stamp, which must not be seeded from a request this same session made.
///
/// `sessionPin`: the account a `tally switch` pinned this session to, handed over by the supervisor
/// this process replaced (SessionSwitch.swift). `pinOverride`: the pin a switch took a session off
/// under an older build, which had no session pin. Both nil for every normal launch.
///
/// `pendingCap`: the cap recovery that supervisor was still waiting out, handed over the same way
/// (SelfUpdate.swift) - without it an upgrade would hand a capped session back with nothing left to
/// notice a sibling freeing up. `sessionModel`: the pair a `tally model` pinned, on the same terms
/// and for the same reason as the account pin (SessionModel.swift). Both nil for a normal launch.
func runSupervised(_ provider: Provider, account initial: Snapshot.Account, args: [String],
                   follow: Bool = false, recoveries: [Date] = [], resumed: Bool = false,
                   sessionPin: String? = nil, pinOverride: String? = nil,
                   pendingCap: PendingCapRecovery? = nil,
                   sessionModel: SessionModelPin? = nil) -> Never {
    let cwd = FileManager.default.currentDirectoryPath
    let slug = projectSlug(forCwd: cwd)
    /// This session's project launch profile (ProjectPolicy.swift), read ONCE: the cwd cannot change
    /// under a running supervisor, and the git probe behind the key must not run on every 2s tick.
    let project = projectPolicy(provider.id)

    // The parent must survive Ctrl+C - claude uses SIGINT to interrupt a turn, and the whole
    // foreground process group (which the child shares) receives it.
    signal(SIGINT, SIG_IGN)
    signal(SIGQUIT, SIG_IGN)

    var account = initial
    // Tally's own flags, dropped from the OPTIONS only: past a `--` the same word is the user's
    // prompt, and filtering the whole vector edited what they said (Snapshot.swift).
    //
    // A RESUMED process (the self-update exec) drops the positionals as well, and that is the
    // existing-damage half of the fossil fix (`withoutPositionals`, LaunchFlags.swift): the argv it
    // inherited was written by the OLD build, which copied the prompt forward, so a session already
    // carrying terminal noise cleans itself at its next upgrade instead of needing a human. Never on
    // a first launch: there the positional is the prompt the user just typed, and this process is
    // about to hand it to their first child.
    var launchArgs = removingOption(removingOption(args, "--no-handoff"), "--no-follow")
    if resumed { launchArgs = withoutPositionals(launchArgs) }
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
    /// How big this session's conversation has grown, published on the same track for `tally status`
    /// (SessionContext.swift). Outside the loop, like the notice: the session survives its children.
    var sessionContext = SessionContextWriter()
    /// Whether the next child is a RELAUNCH rather than the launch the user typed: every spawn
    /// after the first, and all of them when this process is a self-update taking a running session
    /// over. Read only by the resume-prompt suppression (ResumePrompt.swift).
    var relaunching = resumed
    /// A pending cap recovery handed from one child to the next (see `capCarriedAcrossRelaunch`),
    /// seeded from the supervisor this process replaced in a self-update: that exec is one of the
    /// relaunches which carry it, and the argv is how it arrived (SelfUpdate.swift).
    var carriedCap = pendingCap
    /// Stamped into the child env so the status line can tell whether the supervisor watching this
    /// session is the current build (a session launched before an app update runs stale logic).
    let supervisorVersion = supervisorBuildVersion()
    /// The version a self-update exec was aiming for: read from the environment when this process
    /// IS that exec, and written again when this process attempts one of its own.
    var selfUpdateAttempted = consumeSelfUpdateAttempt()
    let supervisorPID = String(getpid())
    /// The status line's view of what this supervisor is waiting to do, SEEDED from this pid's own
    /// notice file: a self-update exec keeps the pid and leaves its badge behind for the image it
    /// hands over to, which then has to be the one that takes it down (PendingNotice.swift).
    var pendingNotice = PendingNoticeWriter(pid: supervisorPID)   // cleared when it exits
    /// What this session is DOING, for the status board outside this terminal (SessionState.swift).
    /// Seeded from this pid's own file for the same reason the notice above is: a self-update keeps
    /// the pid, and the image it hands over to has to be the one that decides what stands there.
    var sessionState = SessionStateWriter(pid: supervisorPID)
    /// Which project this session is in, resolved ONCE: a supervisor's cwd cannot change under it
    /// (`writeSupervisorCwd` rests on the same fact), and the answer costs two git subprocesses.
    /// Asked here rather than in the app so a panel that lists ten sessions is ten file reads
    /// rather than twenty git spawns, and so the board and the pickers name a project by the one
    /// rule (`pickProject`).
    let boardProject = pickProjectForCwd(cwd)
    /// What the user has asked for by hand about the account this session runs on, held across
    /// relaunches and across a self-update exec like the fuse (SessionSwitch.swift owns the rules;
    /// `resumed` is what stops a request this same session just made from being seeded away).
    var manualMoves = ManualMoveState(sessionKey: supervisorPID, servedEpoch: resumed ? 0 : nil,
                                      sessionPin: sessionPin, overriddenPin: pinOverride)
    /// What the user has asked this session to RUN, on the same terms as the account pin above
    /// (SessionModel.swift owns the rules; `resumed` stops a request this session just made from
    /// being seeded away as served).
    var sessionModelState = SessionModelState(sessionKey: supervisorPID,
                                              servedEpoch: resumed ? 0 : nil,
                                              pin: sessionModel ?? SessionModelPin())
    /// What this session has been asked to TYPE on its own behalf (SessionInput.swift owns the
    /// rules). `resumed` carries the same meaning it does above: a self-update exec keeps the pid
    /// and is the same session, so a request written moments before it must not be seeded away.
    var sessionInput = SessionInputState(sessionKey: supervisorPID, servedEpoch: resumed ? 0 : nil)
    // A self-update keeps the pid and gives this state a fresh start, so a cancellation notice the
    // replaced image had just raised lives only in its file - where the seeded writer above would
    // take it down on the first tick, as the honest answer to "this session has nothing pending".
    // Adopted back only on that path (`resumed`): on a normal launch the pid is this process's own
    // and any notice under it belongs to a dead session, which the sweep below removes.
    // Both axes are offered the same file, and each takes it only if the kind is its own: the
    // notice track holds one badge at a time, so at most one of these adopts anything.
    if resumed {
        let carried = readPendingNotice(pid: supervisorPID)
        manualMoves.adoptCancellation(carried)
        sessionModelState.adoptAdoption(carried)
    }
    // Reap drift-state files left by dead supervisors (a SIGKILL skips the clear path) before this
    // one starts writing its own; also shrinks the pid-reuse window for a stale badge.
    sweepDeadSupervisorState()
    // Register in the same directory as a live supervisor (an empty file; a drift episode fills it
    // in later): `tally reload` counts these to say how many sessions its request will restart.
    markSupervisorLive(pid: supervisorPID)
    // Where this session runs, for a `tally switch` typed in a shell with no session marker; written
    // once, because a supervisor's cwd cannot change under it (SwitchRequest.swift).
    writeSupervisorCwd(cwd, pid: supervisorPID)

    while true {
        let launchedAt = Date()
        // What the child is launched with: the account's config home and the markers every Tally
        // surface reads back out of it (SupervisorRuntime.swift).
        let environment = supervisedChildEnvironment(
            provider: provider, home: account.launchHome!, supervisorVersion: supervisorVersion,
            supervisorPID: supervisorPID)
        // A relaunch inherits a terminal whose reader was just killed, and everything queued on it
        // since - the answer to a query the dead child never collected, a keystroke typed into the
        // gap - would arrive as the first thing the new child reads and land in its prompt box
        // (TerminalHandover.swift). Not on the user's own first launch: they typed the command a
        // moment ago, nothing has died here, and anything they type next is theirs.
        if relaunching { drainTerminalInput() }
        // Void the last child's report before a new pid can inherit it (TranscriptIdentity.swift).
        clearTranscriptIdentity(pid: supervisorPID)
        guard let childPID = spawnChild([provider.cli] + launchArgs, environment: environment) else {
            warn("cannot launch `\(provider.cli)`")
            exit(127)
        }
        // Every child from here on is one this supervisor decided to start.
        relaunching = true
        // WHICH CLAUDE CODE THIS SESSION IS, published now rather than with the first reading: it
        // is what a prompt hook matches its own parent against, and the commonest way to reach the
        // pickers at all is a bare `/tally-model` typed before the conversation has had a single
        // turn (SwitchRequest.swift states the whole rule). Written here rather than at start-up so
        // a relaunch replaces the pid of the child it just ended.
        writeSupervisorChild(childPID, pid: supervisorPID)
        // AND WHICH ACCOUNT IT IS ON, published on the same terms and for the same reason: the
        // inventory `tally status --json` answers with is a roster of live supervisors, and the
        // reading next door cannot attribute one until the conversation has had a turn
        // (SwitchRequest.swift). Written beside the pid rather than derived from it so a handoff
        // names the account this child is really running on.
        writeSupervisorAccount(account.id, pid: supervisorPID)

        // What became of this child, remembered because a reaped pid cannot be waited on twice
        // and three places here ask (ChildReaper.swift).
        var child = ChildReaper(pid: childPID)

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
            _ = child.wait()
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

            // A hard cap is the one mover allowed past a session pin, and it ends it: said here,
            // after the child is gone, because the terminal is only ours between a tear-down and
            // the next spawn (PendingNotice.swift), and recorded here so a stood-down relaunch
            // never clears a pin it did not act on.
            let pinCleared = manualMoves.pinClearedByCap(reason)
            if pinCleared { warn(sessionPinClearedByCapNotice) }
            logHandoff(sessionID: sessionFile?.deletingPathExtension().lastPathComponent,
                       from: fromLabel, to: target.label,
                       reason: handoffReason(reason, pinCleared: pinCleared),
                       pid: supervisorPID, cwd: cwd)
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
        /// Said once per child rather than on every 2s tick a plan is stood down: the planners keep
        /// re-planning while they wait, and the child is drawing on this terminal. Never reset -
        /// the only way out of the hold is a relaunch, and that child gets a fresh one of these.
        var unresolvedHoldWarned = false

        child.poll()
        while child.isRunning {
            usleep(2_000_000)
            child.poll()
            guard child.isRunning else { break }
            // Before any relaunch decision reads it: every gate below asks the same tracker, and it
            // only learns anything by being given each tick's reading.
            keyboard.observe(stamp: lastKeyboardInput())
            // Two readings of the same policy, and the difference is one account pin. `fleetPolicy`
            // is what the app and this project declare; `policy` becomes that with this SESSION's
            // own pin over it - a pinned session is not rebalanced, not rescued, and not re-picked
            // (`sessionPolicy`, SessionSwitch.swift). It is derived inside `applyManualMoves` below
            // rather than here, because that call can create or release the pin, and every mover
            // after it must read the pin the session has once it returns. The cap handoff is the
            // one reader that gets the fleet reading, because it is the one move a session pin may
            // not stop (`capReading`).
            let fleetPolicy = effectivePolicy(launchPolicy(provider.id), project: project)
            var policy = fleetPolicy
            // What THIS session is expected to run: its own pin first, then its command line, then
            // the configured default (`sessionPrimaryModel`, SessionModel.swift). Read by the drift
            // monitor and the degradation paths. Safe to take before the ACCOUNT pin is folded in
            // above: that one never touches the model, so both readings answer this identically.
            var effectivePrimary = sessionPrimaryModel(pin: sessionModelState.pin,
                                                       launchArgs: launchArgs,
                                                       providerID: provider.id, policy: policy)
            // The single relaunch this tick will perform, if any. Reasons fire in priority order
            // (pin > cap > degradation > fallback) and the FIRST owns the account move; a follow
            // adoption only folds its model/effort onto that target. Executed once at the tick's
            // end, so a cap and a Settings Apply landing together kill the child exactly once.
            var plan: RelaunchPlan?
            // What the planners below may commit while they plan, read before the first of them
            // runs. A tick that ends up standing its relaunch down (the unresolved-fork hold at the
            // bottom) has to hand all of it back, or the work is not deferred but lost: the reload's
            // served epoch is the case that proved it (StandDown.swift).
            let committed = TickCommitments(reloadEpoch: reloadEpoch, reloadNotice: reloadNotice,
                                            followState: followState,
                                            fallbackApplied: fallbackApplied)
            // The safeguard restore's handled-record is a FILE, so no value snapshot can give it
            // back. It is carried from the decision to the execution point instead and written only
            // if the relaunch happens (SafeguardDrift.swift). Tick-local like the plan it belongs
            // to: a stand-down drops it by going out of scope, with nothing to undo.
            var safeguardRecord: PendingSafeguardRecord?
            /// A served `tally switch`, on the same terms: written only if the relaunch happens, so
            /// a stand-down leaves the request pending (SessionSwitch.swift).
            var switchRecord: PendingSwitchConsumption?
            /// A served `tally model`, on those same terms (SessionModel.swift).
            var modelRecord: PendingModelConsumption?

            // Where this conversation is, FIRST, so no gate below has to fall back on the mtime
            // guess to find out (TranscriptIdentity.swift owns the whole rule).
            adoptReportedTranscript(watcher: &watcher, sessionKey: supervisorPID,
                                    child: processStamp(childPID))
            // Cap recovery has top priority: the transcript is scanned BEFORE any relaunch path
            // (pin, switch, follow, rescue, fallback), because a relaunch resets the watcher's
            // `since` and would filter the cap event as old history and lose it (2026-07-24). The
            // whole rule lives in CapDetection.swift; the window that capped is the one this session
            // runs, which `effectivePrimary` above already answered.
            observeCapHit(pendingCap: &pendingCap, quarantine: &quarantine, watcher: &watcher,
                          account: account, primaryModel: effectivePrimary)

            // Model-drift observation: surface a Fable safeguard fallback and gate the
            // quota-degradation paths below with `drift.isActive` (DriftMonitor.swift).
            observeDrift(&drift, watcher: &watcher, primary: effectivePrimary, pid: supervisorPID)

            // Where this session runs and what it runs there: a `tally switch` or a panel pin, a
            // `tally model`, and the launch default it follows when told neither. All three
            // together because the ORDER between them is a rule, and it lives with them in
            // SessionDirectives.swift. Everything below yields to them by being gated on
            // `plan == nil`; the two records are committed at the execution point like the
            // safeguard's.
            applySessionDirectives(plan: &plan, moves: &manualMoves, switchRecord: &switchRecord,
                                   model: &sessionModelState, modelRecord: &modelRecord,
                                   follow: &followState, following: follow, policy: &policy,
                                   account: account, providerID: provider.id,
                                   launchArgs: launchArgs, primaryModel: &effectivePrimary,
                                   quarantine: quarantine, watcher: &watcher,
                                   childAge: Date().timeIntervalSince(launchedAt),
                                   keyboardIdle: { keyboard.idle($0) })

            // Cap handoff / wait: a pending cap outranks follow, rescue and fallback for the account
            // MOVE (the pin switch above still wins), and it is the only mover a session pin does
            // not stop - though a hand-pinned session is first offered the fallback pairing on the
            // account it is on. CapDetection.swift; rescue/fallback stay gated by `plan == nil`.
            applyCapHandoff(plan: &plan, pendingCap: &pendingCap, account: account,
                            providerID: provider.id, fleet: fleetPolicy,
                            sessionPin: manualMoves.sessionPin,
                            modelPinned: sessionModelState.isPinned, quarantine: quarantine,
                            fuseAllows: fuse.allows())

            // The session's ACTUAL model is no longer the one it was launched for (claude fell back
            // server-side - e.g. the flagship weekly ran dry). Two ordered answers, at most one per
            // tick: move to a sibling that can still serve the model, else accept the configured
            // fallback pairing here. Both rules, and why they skip a safeguard drift, live in
            // ModelDegradation.swift.
            applyDegradationRescue(plan: &plan, watcher: &watcher, driftActive: drift.isActive,
                                   policy: policy, account: account, providerID: provider.id,
                                   primaryModel: effectivePrimary, quarantine: quarantine,
                                   fuseAllows: fuse.allows())
            applyFallbackProfile(plan: &plan, applied: &fallbackApplied, watcher: &watcher,
                                 driftActive: drift.isActive, policy: policy, account: account,
                                 primaryModel: effectivePrimary)

            // Safeguard-fallback restore: the API fell this session onto a fallback model and left
            // it at its own default depth, so put the declared depth back at an idle moment - on
            // the fallback model, never back on the one that tripped it (SafeguardDrift.swift).
            applySafeguardRestore(plan: &plan, drift: &drift, record: &safeguardRecord,
                                  watcher: &watcher, account: account,
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
            // A pending cap does NOT hold it back: that wait lasts as long as the sibling accounts
            // stay dry, so deferring to it never ended, and the capped session was the one session
            // on the machine that could not take a fix (2026-08-06, SelfUpdate.swift). The state
            // rides across the exec instead - `carriedCap` below is what the argv carries.
            let childAge = Date().timeIntervalSince(launchedAt)
            if selfUpdateDue(
                   captured: supervisorVersion, attempted: selfUpdateAttempted,
                   isQuiet: reloadQuiet(transcriptQuiet: watcher.isQuiet(followIdleSeconds),
                                        hasTranscript: watcher.file != nil, childAge: childAge,
                                        bar: followIdleSeconds,
                                        keyboardQuiet: keyboard.idle(followIdleSeconds)),
                   relaunchPlanned: plan != nil,
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
            // `lastModel` is the tick's own scan (the cap check above ran it), so this costs
            // nothing extra: the model that actually answered the newest turn, beside the one the
            // command line asked for.
            let axes = publishedSessionAxes(pin: sessionModelState.pin, launchArgs: launchArgs,
                                            observed: watcher.lastModel)
            // The conversation this supervisor is watching, from the file the tick just tailed:
            // the witness that lets a prompt hook tell this session from another one running in
            // the same directory (SessionContext.swift). Read here rather than remembered, so a
            // `/clear` or a fork republishes the new transcript with everything else.
            sessionContext.sync(tokens: watcher.lastContextTokens, accountID: account.id,
                                pin: manualMoves.sessionPin, axes: axes,
                                transcript: watcher.transcriptSessionID, pid: supervisorPID)
            // The one thing this session is WAITING to do, for the status line: a deferral must
            // not be printed onto the terminal the child draws into (PendingNotice.swift).
            syncPendingNotice(&pendingNotice, pid: supervisorPID,
                              manualMove: manualMoves.badge, sessionModel: sessionModelState.badge,
                              reload: reloadNotice.pending,
                              followDeadEnd: followState.deadEnd, followQueued: followState.queuedNotice,
                              policy: policy, capReason: pendingCap?.reason)
            // And what it is DOING, for the panel and `tally status --json`: working, waiting on
            // the user, idle, or nothing-to-say. The rules are in SessionStateSync.swift; the model
            // published is the one that ANSWERED the last turn where there is one, falling back to
            // what the child was launched with (SessionContext.swift states why those differ).
            let boardState = syncSessionState(
                &sessionState, pid: supervisorPID, project: boardProject,
                accountID: account.id, childPid: Int(childPID),
                model: (axes.observedModel ?? axes.runningModel ?? axes.pinnedModel)
                    .map(shortModelName),
                watcher: &watcher, keyboardBurstAt: keyboard.lastBurstAt)
            // `tally session type`: type a pending request into this terminal, if the state just
            // decided allows it. NOT a relaunch reason - it plans nothing, terminates nothing, and
            // is gated on this tick's own reading rather than on the published file
            // (SessionInput.swift owns every rule, the stall it costs included).
            applySessionInput(&sessionInput, session: boardState,
                              keyboardIdle: keyboard.idle(sessionInputKeyboardQuietSeconds))

            // Execute the tick's one relaunch: terminate the child once, then apply any
            // model/effort/extra flags this plan carries on top of the resumed args. A pending app
            // update rides along on THIS restart instead of waiting for an idle moment that only
            // starts counting again after it (a cap handoff at 06:34 and the self-update it
            // deferred at 06:36, session c80ebeb2, 2026-07-26). Decided before anything is
            // terminated, and against the account the plan moves TO, so the new build resumes the
            // conversation where this handoff is about to put it rather than on the old account.
            if let plan {
                // Last look before anything is terminated, and a FORCED one: the planners each
                // asked their own gate, but a `/clear` can land in the microseconds since, and
                // restarting then resumes the id from before it (TranscriptFork.swift). This may
                // also adopt a fork that has just stamped its marker, the same insurance seen from
                // the other side: the relaunch then resumes the file the conversation is in.
                watcher.locateFile(forceForkCheck: true)
                if relaunchHeldByUnresolvedFork(reason: plan.reason,
                                                unresolvedFork: watcher.hasUnresolvedFork) {
                    // Hand back what planning committed, so the next tick plans it again rather
                    // than believing it is already done (StandDown.swift).
                    committed.restore(reloadEpoch: &reloadEpoch, reloadNotice: &reloadNotice,
                                      followState: &followState, fallbackApplied: &fallbackApplied)
                    if !unresolvedHoldWarned {
                        // To the log, never the terminal: this tick relaunches NOTHING (it
                        // `continue`s), so the child is drawing over whatever is written here
                        // (PendingNotice.swift states the rule).
                        appendHandoffLine(unresolvedForkHoldLine(pid: supervisorPID, cwd: cwd),
                                          to: handoffLog)
                        unresolvedHoldWarned = true
                    }
                    continue   // the child keeps running; the next tick decides again from scratch
                }
                // Past the hold, so this relaunch is happening: the safeguard restore's record can
                // be written now, before the child goes, which is what the supervisor behind the
                // relaunch reads to know the event was corrected (SafeguardDrift.swift).
                safeguardRecord?.commit()
                switchRecord?.commit(&manualMoves)
                modelRecord?.commit(&sessionModelState)
                carriedCap = capCarriedAcrossRelaunch(pendingCap, reason: plan.reason)
                let upgrade = selfUpdateFold(captured: supervisorVersion,
                                             attempted: selfUpdateAttempted,
                                             home: plan.target.launchHome)
                performHandoff(to: plan.target, reason: plan.reason, countingFuse: plan.countsFuse)
                launchArgs = planLaunchArgs(launchArgs, plan: plan,
                                            sessionPin: sessionModelState.pin)
                // Republish the account this conversation now runs on, and the pair the next child
                // will run, rather than leaving either to a later tick that reads a token figure: a
                // `tally switch` or a `tally model` from a shell outside this session has only that
                // file to go on (SessionContext.swift). AFTER the args are rewritten above, because
                // what it publishes is what the child about to be spawned actually runs - before
                // it, this would republish the pair the session is leaving.
                // No observation to carry across: the child that produced the old one is gone, and
                // the one about to start has served nothing. Publishing the dead child's reading
                // here would name a model this session is provably no longer on - the same mistake
                // one restart later.
                let nextAxes = publishedSessionAxes(pin: sessionModelState.pin,
                                                    launchArgs: launchArgs, observed: nil)
                sessionContext.accountChanged(to: account.id, pin: manualMoves.sessionPin,
                                              axes: nextAxes,
                                              transcript: watcher.transcriptSessionID,
                                              pid: supervisorPID)
                // THE ACCOUNT SIDECAR MOVES IN THE SAME BREATH, so the two documents naming this
                // session's account can never describe different moments. Left to the spawn below,
                // it would name the account the session has just left for the whole tear-down; and
                // the reading beside it cannot be relied on to lead instead, because a publish that
                // fails is silent while the writer's in-memory copy moves on regardless - after
                // which the delta suppresses the retry and the file keeps the old account for as
                // long as the session idles (codex review of ff5b2a0). Written here rather than
                // only at the spawn, so neither document has to be the fresher one.
                writeSupervisorAccount(account.id, pid: supervisorPID)
                // Last, so an exec that fails falls through to the respawn below with this plan
                // fully applied: a failed upgrade can cost the new build, never the account switch.
                execPlannedSelfUpdate(upgrade, attempted: &selfUpdateAttempted, target: plan.target,
                                      follow: follow, recoveries: fuse.carried(),
                                      sessionPin: manualMoves.sessionPin,
                                      pinOverride: manualMoves.overriddenPin,
                                      pendingCap: carriedCap,
                                      sessionModel: sessionModelState.pin, args: launchArgs)
                break
            }
        }

        if handoff { continue }
        let status = child.wait()   // no relaunch pending: the child exited on its own, so do we
        removeSupervisorState(pid: supervisorPID)
        clearPendingNotice(pid: supervisorPID)
        clearSessionContext(pid: supervisorPID)
        clearSessionState(pid: supervisorPID)
        clearUserNotice(pid: supervisorPID)
        // A SESSION ENDING IS A STATE CHANGE, and the one nothing else can announce. Every other
        // knock is posted by the writer when it publishes; this session publishes nothing more, so
        // without this the board hears nothing until some OTHER supervisor happens to move. For a
        // session that was BLOCKED that is not a stale row, it is a red dot in the menu bar for a
        // conversation that no longer exists, standing until an unrelated session changes state.
        postSessionStateChanged(pid: supervisorPID)
        exit(supervisorExitCode(childStatus: status))
    }
}
