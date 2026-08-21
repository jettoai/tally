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
    /// What this session has been TOLD about the account under it running out (QuotaKnock.swift
    /// owns the rules). Per session rather than per child, so a relaunch does not re-announce a
    /// drought this conversation has already heard about; a relaunch that moves accounts re-arms it
    /// by itself, because the new account's binding window is a different cycle.
    var quotaKnock = QuotaKnockState()
    /// What this session knows about the account under it running out (DroughtWatch.swift owns the
    /// rules): whether the pins over it still hold, and whether the one line a blocked drought
    /// leaves has been written. Per session on the same terms as the arm above, and re-keyed by the
    /// ACCOUNT rather than aged out, so a relaunch that moves reads the new account at once.
    var drought = DroughtWatch()
    /// And what it owes the conversation once a wall has actually moved it (CapResume.swift owns the
    /// rules): the one line saying the turn was cut short and asking it to carry on. Per session and
    /// necessarily so - the arm is raised by the tick that ends one child and spent by a tick of the
    /// next one, which is the one event a per-child value could never carry it across.
    var capResume = CapResumeState()
    /// And HOW it is told: filed for this child's own hooks to deliver where they are registered and
    /// runnable, typed into the composer where they are not (QuotaKnockNotice.swift).
    ///
    /// DECLARED BESIDE THE ARM AND ANSWERED BESIDE THE CHILD, which is the one thing about this
    /// value that is load-bearing: the arm belongs to the conversation and outlives every relaunch,
    /// while this belongs to the PROCESS, because the hooks a Claude Code runs are the ones its
    /// settings.json held when it started (`quotaKnockFilingAvailable`). It is re-read at each
    /// spawn below and holds for exactly that child. False until then, so a session that somehow
    /// announced before its first child was up would be typed into rather than filed for.
    var quotaKnockFiling = false
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
    // THE OTHER DOCUMENT AN IMAGE CAN LEAVE UNDER ITS OWN PID, reconciled the other way: a knock
    // filed and not yet delivered is news rather than a live wait, and this image has announced
    // nothing, so it is discarded rather than adopted. Unconditional, and outside the `resumed`
    // branch on purpose - the self-update is the case the sweep below cannot reach, because the pid
    // never died (QuotaKnockNotice.swift enumerates all four ways the file outlives its arm).
    discardCarriedQuotaKnockNotice(pid: supervisorPID)
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
        // WHICH CHANNEL THIS CHILD CAN BE TOLD THROUGH, read here and held for its whole life: the
        // hooks a Claude Code runs are the ones its settings.json held when it started, so this is a
        // property of the process about to exist rather than of the account or of the supervisor
        // (`quotaKnockFilingAvailable` argues the reading, and why it is taken BEFORE the spawn
        // rather than after). Re-read on every pass, so a relaunch onto another account - or one
        // that follows an install - answers for the child it is starting.
        quotaKnockFiling = quotaKnockFilingAvailable(home: account.launchHome)
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
        func performHandoff(to target: Snapshot.Account, reason: String, countingFuse: Bool = true,
                            fresh: Bool = false) {
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
            // A FRESH RELAUNCH CARRIES NOTHING, which is the one thing `tally session clear` needs
            // of this path: the request it answers asked for an empty window, so resuming the
            // conversation on the target would move the context it was told to drop (and copying it
            // there would leave the whole transcript in another account's projects directory for
            // nothing). The id is still LOGGED below - which conversation ended here is what that
            // line is for - and only the resume and the copy are dropped.
            let carrying = fresh ? nil : sessionFile
            if let carrying {
                shareTranscript(carrying, toHome: target.launchHome!, slug: slug)
            }

            // A hard cap is allowed past a session pin, and so is a preventive move off an account
            // with nothing left (DroughtWatch.swift): either way the move ends the pin. Said here,
            // after the child is gone, because the terminal is only ours between a tear-down and
            // the next spawn (PendingNotice.swift), and recorded here so a stood-down relaunch
            // never clears a pin it did not act on.
            let pinCleared = manualMoves.pinCleared(by: reason)
            if pinCleared { warn(sessionPinClearedNotice(reason: reason)) }
            logHandoff(sessionID: sessionFile?.deletingPathExtension().lastPathComponent,
                       from: fromLabel, to: target.label,
                       reason: handoffReason(reason, pinCleared: pinCleared),
                       pid: supervisorPID, cwd: cwd)
            if countingFuse { fuse.record() }
            account = target
            launchArgs = relaunchArgs(
                launchArgs,
                sessionID: carrying?.deletingPathExtension().lastPathComponent,
                sameAccount: sameAccount && !fresh)
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
        /// When this supervisor last typed into this child's composer itself, and nil until it has.
        /// Per child, like the keyboard history above, and for a sharper reason than symmetry: what
        /// reads it is the draft guard, whose question is whether a PERSON has typed lately - and
        /// injected bytes stamp that terminal exactly as fingers do (SessionInputDraft.swift). A
        /// stamp left by the previous child is not evidence about this one either way.
        var lastComposerWrite: Date?
        /// What this child has been asked to type that closes its own window (WindowRepick.swift).
        /// Per child, like the keyboard history above: a relaunch replaces the conversation, so
        /// anything armed against the old one is already answered.
        var windowRepick = WindowRepickState()
        /// Which turn boundaries the turn-boundary mover has already ruled on (TurnBoundaryMove.
        /// swift). Per child on the same terms as the arm above: a relaunch replaces the
        /// conversation, and a boundary recorded against the old one is answered by the restart.
        var turnBoundary = TurnBoundaryState()
        /// Said once per child rather than on every 2s tick a plan is stood down: the planners keep
        /// re-planning while they wait, and the child is drawing on this terminal. Never reset -
        /// the only way out of the hold is a relaunch, and that child gets a fresh one of these.
        var unresolvedHoldWarned = false

        /// ONE POLL TICK, and a function rather than the loop's own body so that the loop can run it
        /// inside an `autoreleasepool`: neither `continue` nor `break` crosses a closure boundary, so
        /// the two escapes it used to spell are `TickOutcome` values now (SupervisorRuntime.swift).
        ///
        /// WHY THE POOL. Swift wraps only `main`, and that pool drains when the process exits - which
        /// for a supervisor is days later, or never. Every Foundation temporary a tick made therefore
        /// stood for the life of the session: above all the `NSURL`s and the prefetched `_FileCache`
        /// behind each one from the transcript-directory passes the idle gates run
        /// (TranscriptFork.swift), 979 bytes per directory entry, about 3.3 passes per tick, 30 ticks
        /// a minute. Measured on a live supervisor 2026-08-19: 16.5 MB/min against a 169-file project
        /// directory, matched within 20% on five processes, and 47 GB on the one that had gone
        /// longest without a self-update exec - which was the only event that ever gave it back,
        /// because it replaces the process image. Six of those took the machine down.
        ///
        /// `leaks(1)` reports nothing here, and that is why it stood for 25 versions: every one of
        /// those objects is reachable from the pool's own pages, so none of them is leaked in the
        /// sense that tool means. The oracle is the slope of the footprint, not a leak report
        /// (tests/supervisor/footprintchecks.swift asserts the slope, and this pool with it).
        func tick() -> TickOutcome {
            // Before any relaunch decision reads it: every gate below asks the same tracker, and it
            // only learns anything by being given each tick's reading.
            keyboard.observe(stamp: lastKeyboardInput())
            // THREE READINGS OF ONE POLICY, and the difference between them is a pin. `fleetPolicy`
            // is what the app and this project declare; `moving` is that with a pin RELEASED when
            // the account it names has nothing left (DroughtWatch.swift), which is the reading
            // everything that moves this session is judged by; and `policy` is `moving` with this
            // SESSION's own pin over it - a pinned session is not rebalanced, not rescued, and not
            // re-picked (`sessionPolicy`, SessionSwitch.swift). The last is derived inside
            // `applySessionDirectives` below rather than here, because that call can create or
            // release the pin, and every mover after it must read the pin the session has once it
            // returns. The cap handoff is the one reader that gets `moving` rather than `policy`,
            // because it is the one move a session pin may not stop (`capReading`).
            // The APP's own document, read before either overlay: `effectivePolicy` turns a project
            // account into `manual` and `sessionPolicy` turns a session pin into `manual`, so a
            // policy read through either can no longer say `off` at all, and the observe-only gate
            // has to be asked of the file the user set (AutoSteering.swift; `runLaunchDir` asks it
            // the same way for the shim).
            let appPolicy = launchPolicy(provider.id)
            let fleetPolicy = effectivePolicy(appPolicy, project: project)
            /// What each account's owner keeps for their own browser use, from the same document
            /// and on the same terms as the policy above: read once here and handed to every mover
            /// that picks an account, because a reserve read twice in one tick is two answers to
            /// one file (AccountReserve.swift). Nine readers, one reading - the same argument
            /// `steering` makes one line down.
            let reserves = accountReserves()
            /// Whether Tally may choose an account for this session at all, this tick. Read once,
            /// here, and handed to every mover that would pick one: nine of them, and a gate spelled
            /// nine times is nine gates that can come to disagree about one file.
            let steering = supervisorMaySteerAccounts(appMode: appPolicy.mode)
            // What THIS session is expected to run: its own pin first, then its command line, then
            // the configured default (`sessionPrimaryModel`, SessionModel.swift). Read by the drift
            // monitor and the degradation paths. Safe to take before the ACCOUNT pin is folded in
            // above: that one never touches the model, so both readings answer this identically.
            var effectivePrimary = sessionPrimaryModel(pin: sessionModelState.pin,
                                                       launchArgs: launchArgs,
                                                       providerID: provider.id,
                                                       policy: fleetPolicy)
            // WHAT THE ACCOUNT UNDER THIS SESSION IS WORTH, and therefore what a pin over it still
            // is (DroughtWatch.swift owns the whole rule): naming an account says which one this
            // conversation belongs on, never that it should sit on an empty one. The reading is
            // taken at most every 30s because the movers below refuse a pinned session BEFORE they
            // read the snapshot, which is what keeps a 2s poll free.
            drought.observe(provider: provider.id, account: account, primaryModel: effectivePrimary,
                            quarantine: quarantine, reserves: reserves)
            /// Whether the pins over this session yield this tick. Asked ONCE, off the app's own
            /// mode rather than the folded policy: a fleet pin is never released, and the folded
            /// reading cannot tell which scope pinned it.
            let pinYields = pinYieldsToSpentAccount(appMode: appPolicy.mode,
                                                    spent: drought.spent)
            /// The fleet's policy as everything that MOVES this session judges it. The pin switch
            /// reads it too, which is the half that matters: released, it stands down instead of
            /// dragging the session straight back onto the account a mover just carried it off.
            let moving = pinReleasedPolicy(fleetPolicy, yielding: pinYields)
            var policy = moving
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
                                   steering: steering,
                                   account: account, providerID: provider.id,
                                   launchArgs: launchArgs, primaryModel: &effectivePrimary,
                                   quarantine: quarantine, reserves: reserves,
                                   watcher: &watcher,
                                   childAge: Date().timeIntervalSince(launchedAt),
                                   keyboardIdle: { keyboard.idle($0) })
            // AND AGAIN, because the station above can have folded a SESSION pin in
            // (`sessionPolicy`), which lands as a fresh `manual` over the reading taken a moment
            // ago. The release is about the account being empty, which is as true of the session's
            // own pin as of the project's. Idempotent when nothing was pinned.
            policy = pinReleasedPolicy(policy, yielding: pinYields)

            // Cap handoff / wait: a pending cap outranks follow, rescue and fallback for the account
            // MOVE (the pin switch above still wins), and it is the only mover a session pin does
            // not stop - though a hand-pinned session is first offered the fallback pairing on the
            // account it is on. CapDetection.swift; rescue/fallback stay gated by `plan == nil`.
            // `moving` rather than `fleetPolicy`: a project profile that pins an account answered
            // `.waitPinned` here for ever, so a session in one of those repos could not even be
            // rescued by a cap (2026-08-21). Released once the account is spent, it is the fleet's
            // own reading in every other respect, the app's own pin included.
            applyCapHandoff(plan: &plan, pendingCap: &pendingCap, account: account,
                            providerID: provider.id, fleet: moving, steering: steering,
                            sessionPin: manualMoves.sessionPin,
                            modelPinned: sessionModelState.isPinned, quarantine: quarantine,
                            fuseAllows: fuse.allows(), reserves: reserves)

            // The session's ACTUAL model is no longer the one it was launched for (claude fell back
            // server-side - e.g. the flagship weekly ran dry). Two ordered answers, at most one per
            // tick: move to a sibling that can still serve the model, else accept the configured
            // fallback pairing here. Both rules, and why they skip a safeguard drift, live in
            // ModelDegradation.swift.
            applyDegradationRescue(plan: &plan, watcher: &watcher, driftActive: drift.isActive,
                                   policy: policy, account: account, providerID: provider.id,
                                   primaryModel: effectivePrimary, quarantine: quarantine,
                                   steering: steering, fuseAllows: fuse.allows(),
                                   reserves: reserves)
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

            // WHAT THIS SESSION IS DOING, decided before the preventive movers rather than after
            // them, which is a move this package made (2026-08-20) and the reason is one word:
            // `blocked`. Both preventive movers and the turn-boundary one below refuse to restart a
            // session that is waiting on a person, and only this reading can tell them - it is the
            // notice hook, the open `AskUserQuestion` and the quiet reading folded together
            // (SessionStateSync.swift), and no cheaper second opinion may stand in for it.
            //
            // NOTHING IT READS MOVES BETWEEN HERE AND WHERE IT USED TO STAND: the axes come from a
            // pin and a command line the directives station has already settled, and the account
            // and the args are only rewritten at the execution point at the bottom of the tick.
            //
            // IT IS NOT A PUBLISHER, which is what the first version of this note called it and was
            // wrong about (review of e52a436, B2). It takes the watcher `inout` and runs
            // `quietness`, so it LOCATES - rebinding `file` and `hasUnresolvedFork` - it fills the
            // open-call scan cache, it unlinks an answered notice, and it posts a state-change
            // knock. Three things make moving it safe anyway, and they are worth naming because
            // "publisher" was doing that work by assertion:
            //
            //   - THE LOCATE IS NOT THE FIRST OF THE TICK. `observeCapHit` runs `sawCapHit`, whose
            //     first act is `locateFile()`, above every station here; the directives station and
            //     the degradation rescue both locate again through `isQuiet`. One more between them
            //     changes no invariant any of them holds.
            //   - THE ONE ORDERING RULE IN THIS AREA IS INTERNAL TO THE STATION IT PRECEDES. The
            //     window repick requires its id and its window reading to be taken as a pair BEFORE
            //     the `isQuiet` inside `applyProactiveMoves` can relocate under them
            //     (WindowRepick.swift); that pair is still read first inside that function, and a
            //     locate before the station leaves both halves describing the same file.
            //   - THE OTHER TWO EFFECTS ARE POSITION-FREE. Clearing an answered notice is
            //     idempotent and narrowed to the event it judged, and the knock is an invitation to
            //     read a file this call has already written.
            //
            // WHAT DID CHANGE is the distance to `applySessionInput`, whose whole reason for taking
            // this value rather than the file is that it wants the state as of THIS tick: there are
            // now three stations and their file I/O between the reading and that consumer. Same
            // tick, further apart.
            //
            // The model published is the one that ANSWERED the last turn where there is one,
            // falling back to what the child was launched with (SessionContext.swift states why
            // those differ); `axes` also feeds the context publish further down.
            let axes = publishedSessionAxes(pin: sessionModelState.pin, launchArgs: launchArgs,
                                            observed: watcher.lastModel)
            let board = syncSessionState(
                &sessionState, pid: supervisorPID, project: boardProject,
                accountID: account.id, childPid: Int(childPID),
                model: (axes.observedModel ?? axes.runningModel ?? axes.pinnedModel)
                    .map(shortModelName),
                watcher: &watcher, keyboardBurstAt: keyboard.lastBurstAt)

            // The two PREVENTIVE movers, lowest priority of the account moves because every block
            // above is repairing something and neither of these repairs anything: the window repick
            // (a session that has just cleared its context is empty, so the restart off a dying
            // account is free) and the idle rebalance (the standing offer for a session nobody
            // clears). Both gated on the recovery fuse; the order between them is a rule, and it
            // lives with them in WindowRepick.swift.
            // WHETHER THIS SESSION'S COMPOSER ALREADY HOLDS SOMETHING, taken ONCE for the three
            // readers below it, from the two facts this process has: a run of keystrokes since the
            // last prompt, and nothing typed by this supervisor since (SessionInputDraft.swift). It
            // is read here, ahead of the preventive movers, because those movers are relaunches and
            // a relaunch ends the composer and the kill buffer of the child it replaces - the same
            // invariant the input station holds when a clear lands, at the other end of the same
            // minute. The transcript was scanned at the top of this tick, so this reading is as
            // fresh here as it was where it used to be taken, and one reading is what stops the two
            // ends of the invariant from ever disagreeing about the same instant.
            let draftSuspected = sessionInputDraftSuspected(burstAt: keyboard.lastBurstAt,
                                                            userTurnAt: watcher.lastUserTurnAt,
                                                            injectedAt: lastComposerWrite)
            // THE BOUNDARY THIS SESSION'S CLAUDE CODE LAST REPORTED, read ONCE for the two stations
            // that consult it: the rebalance below stands down while one is undecided, and the
            // station further down rules on it (TurnBoundaryMove.swift states why the order between
            // them has to be bought this way). One read, so the two cannot disagree about which
            // boundary they are talking about.
            let boundary = readSessionTurnEnd(pid: supervisorPID)
            // AND THIS CHILD'S OWN AGENT ROLL CALL, read ONCE for the two movers that consult it and
            // dropped here if it belongs to the child before this one (AgentRoster.swift: the file
            // is named for the supervisor, which outlives its children, so a relaunch that ended a
            // fan-out leaves ids nothing will ever strike off). The rebalance treats a named worker
            // as a session that has NOT been left alone; the turn-boundary station waits for it.
            // One read, so the two cannot come to disagree about who is working.
            let roster = currentGenerationRoster(pid: supervisorPID, childStartedAt: launchedAt)
            let agentsWorking = rosterReportsWorking(roster)
            applyProactiveMoves(plan: &plan, repick: &windowRepick, watcher: &watcher,
                                keyboardIdle: { keyboard.idle($0) },
                                draftSuspected: draftSuspected, provider: provider.id,
                                account: account, primaryModel: effectivePrimary,
                                mode: policy.mode, steering: steering,
                                blocked: board.waitingOnPerson, agentsWorking: agentsWorking,
                                launchArgs: launchArgs,
                                fuseAllows: fuse.allows(),
                                turnBoundaryPending: turnBoundaryPending(turnBoundary,
                                                                        event: boundary),
                                quarantine: quarantine, reserves: reserves)

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
            // UNLESS THE ACCOUNT IS SPENT, where the rebalance asks for no claim at all and this
            // ride inherits that for free, through the shared `rebalanceMove` rather than through a
            // path of its own (Rebalance.swift). That is the 2026-08-20 incident's own shape: a
            // reload restarted nine sessions while another session held the drought's claim, so
            // three of them were re-placed onto the very account they were leaving.
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
                                                 steering: steering,
                                                 // NOT THIS CALLER'S GATE TO HOLD, on the same
                                                 // terms as `isQuiet: true` beside it: the child is
                                                 // being restarted by the reload whatever this
                                                 // answers, so the prompt a blocked session is
                                                 // holding is lost either way. All this closure
                                                 // decides is WHICH ACCOUNT that restart lands on.
                                                 blocked: false,
                                                 // NOR THIS ONE, for the same reason: the restart
                                                 // is the reload's and it ends whatever is running
                                                 // whichever account it lands on.
                                                 agentsWorking: false,
                                                 isQuiet: true, carryable: carryable,
                                                 fuseAllows: fuse.allows(),
                                                 quarantine: quarantine, reserves: reserves)
                               })
            // How much context a resume of this conversation would reload, and which conversation
            // it is, for the surfaces outside this terminal (SessionContext.swift). `axes` is the
            // reading taken above, beside the board it also feeds.
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
            // THE TWO QUESTIONS ASKED BY EVERYTHING THAT WRITES INTO THIS COMPOSER OR RESTARTS THE
            // CHILD UNDER IT, taken once: two spellings of the same gate are two gates that can
            // come to disagree about the same instant. `turnOver` is a closure rather than a value
            // because it reads a file and a transcript tail, and only a tick that has something to
            // do with the answer has any use for it.
            let composerIdle = keyboard.idle(sessionInputKeyboardQuietSeconds)
            let turnOver = { sessionTurnEnded(pid: supervisorPID, watcher: watcher) }
            // THE THIRD PREVENTIVE MOVER, and the only one that reaches a session which never goes
            // idle: the turn Claude Code has just reported over is the gap a cross-account move
            // fits into without cutting anything, which is what the 120s rebalance and the `/clear`
            // repick can never offer a busy conversation (TurnBoundaryMove.swift owns every gate,
            // the subagent roster among them). HERE rather than beside the other two because it
            // needs the blocked reading the board decided one line above; the claim all three share
            // is kept in the intended order by the one-tick stand-down `turnBoundaryPending` gives
            // the rebalance up there.
            applyTurnBoundaryMove(plan: &plan, state: &turnBoundary, event: boundary,
                                  steering: steering, provider: provider.id, account: account,
                                  primaryModel: effectivePrimary, mode: policy.mode,
                                  blocked: board.waitingOnPerson, keyboardIdle: composerIdle,
                                  draftSuspected: draftSuspected, carryable: carryable,
                                  fuseAllows: fuse.allows(),
                                  agents: { turnBoundaryAgents(roster, boundary: $0, now: $1) },
                                  turnEnded: turnOver(),
                                  toolCallOpen: turnBoundaryToolCallOpen(watcher.file),
                                  quarantine: quarantine, reserves: reserves)
            // AND THE ONE LINE A DROUGHT NOBODY COULD MOVE THIS SESSION OUT OF LEAVES BEHIND
            // (DroughtWatch.swift): once per window cycle, naming the gates that refused. HERE
            // because this is the first point in the tick where every gate all three movers hold
            // has been decided, and it stands down when a relaunch IS planned - that tick moved the
            // session, and the handoff log records the move itself.
            applyDroughtAudit(&drought, relaunchPlanned: plan != nil, account: account.label,
                              sessionID: watcher.transcriptSessionID, pid: supervisorPID, cwd: cwd,
                              steering: steering, mode: policy.mode,
                              blocked: board.waitingOnPerson, agentsWorking: agentsWorking,
                              isQuiet: watcher.isQuiet(followIdleSeconds)
                                  && keyboard.idle(followIdleSeconds),
                              draftSuspected: draftSuspected, carryable: carryable,
                              fuseAllows: fuse.allows(), log: handoffLog)
            // `tally session send`: type a pending request into this terminal, if the reading just
            // taken allows it. THE READING RATHER THAN THE WORD, because this is the one consumer
            // for which "working" is two different answers: a conversation mid-turn is not typed
            // into, one whose dispatched agents are writing is (SessionQuiet.swift argues it).
            // NOT a relaunch reason - it plans nothing, terminates nothing, and
            // is gated on this tick's own reading rather than on the published file
            // (SessionInput.swift owns every rule, the stall it costs included). It is told whether
            // this tick is ABOUT to terminate the child, which is a fact only the loop holds and the
            // state cannot show: an idle session with a plan against it is the very case where
            // typing would be lost and reported as delivered.
            // The tick's last look, and the one answer both readers below need: a PLANNED relaunch
            // is not a relaunch, because the fork hold can stand it down and leave this child
            // running (StandDown.swift carries the whole reasoning, the regression included).
            var replacingChild = relaunchIsHappening(plan: plan, watcher: &watcher)
            // What it TYPED arms the window repick above: a `/clear` that reached the composer is
            // this session's window closing, and the next tick asks Claude Code itself whether it
            // really did (WindowRepick.swift).
            // And whether Claude Code has SAID this turn is over, which is the difference between
            // typing at the end of a turn and typing 30 seconds after it (SessionTurnEnd.swift):
            // both readings are `composerIdle` and `turnOver`, taken above the mover that needs
            // them first.
            // And, for a `tally session clear` only, the account question a window about to be
            // emptied makes free: the repick's own decision, asked at the landing rather than after
            // it (SessionClear.swift). A plain send never reaches it.
            let action = applySessionInput(
                &sessionInput, session: board.state, quiet: board.quiet, turnEnded: turnOver,
                keyboardIdle: composerIdle, relaunchPlanned: replacingChild,
                draftSuspected: draftSuspected,
                clearBoundary: {
                    windowRepickMove(provider: provider.id, account: account,
                                     primaryModel: effectivePrimary, mode: policy.mode,
                                     steering: steering,
                                     carryable: carryable, fuseAllows: fuse.allows(),
                                     quarantine: quarantine, reserves: reserves)
                })
            // `action.repick` RATHER THAN `action.typed`, which is not a rename: the repick is a
            // relaunch, and a session that may be holding an unsent draft is not restarted away from
            // it - the rule `sessionClearMovesAccounts` states about the synchronous move, applied
            // to the one that happens a minute later. Its three answers include CANCELLING an arm an
            // earlier clear left, which is the half that "do not arm" could not say
            // (SessionInputTick.swift, `SessionInputRepick`).
            windowRepick.apply(action.repick, transcript: watcher.transcriptSessionID)
            // What this tick typed is also what the NEXT tick's draft reading has to discount: the
            // child reads those bytes off the terminal and stamps it doing so, and a supervisor that
            // read its own footprints as somebody's draft would paste a stale kill buffer into their
            // composer (SessionInputDraft.swift states the case).
            if action.typed != nil { lastComposerWrite = Date() }
            // A move decided at the landing becomes THIS tick's relaunch, built next door so the
            // rule and its sentence live with the verb (SessionClear.swift). `plan` is nil by
            // construction here: the gate that answered the request refuses every tick that has one
            // (`relaunchPlanned`).
            if let moved = clearBoundaryPlan(action.moveTo, from: account,
                                             primaryModel: effectivePrimary) {
                plan = moved
                // AND THE TICK'S OWN ANSWER MOVES WITH IT. `replacingChild` was taken before this
                // decision existed, when nothing was planned, and both the execution block below
                // and the knock beside it branch on it: left at false, the block would read this
                // plan as one an unresolved fork had stood down, restore, log a hold that is not
                // there and `continue` - having already told the caller its window was moved.
                // A stand-down cannot apply to this plan in any case: what stands one down is an
                // unresolved fork, and a session with one never reaches this landing (that reading
                // is `busy`, so the gate holds the line as the session's own turn).
                replacingChild = true
            }
            // AND THE LINE THAT PICKS UP WHERE A WALL CUT THIS CONVERSATION OFF (CapResume.swift):
            // a cap handoff has moved it and the work that 429 interrupted is sitting in the
            // resumed window with nobody to ask for it. Same door and the same gates as the two
            // writers either side of it, plus one of its own - a session waiting on a person is not
            // typed at.
            // BETWEEN THE TWO, which is the priority these three composer writers have: a line
            // somebody ASKED for outranks it, and it outranks news about an account, because work
            // this session lost is the more urgent of the two things nobody asked for.
            let resumed = applyCapResume(&capResume, pid: supervisorPID,
                                         typedAlready: action.typed != nil, session: board.state,
                                         quiet: board.quiet, turnEnded: turnOver,
                                         keyboardIdle: composerIdle,
                                         relaunchPlanned: replacingChild,
                                         draftSuspected: draftSuspected,
                                         userTurnAt: watcher.lastUserTurnAt)
            // On the same terms as the two beside it: what this tick typed is what the next tick's
            // draft reading has to discount.
            if resumed != nil { lastComposerWrite = Date() }
            // AND THE ONE LINE NOBODY ASKED FOR: the account under this session is running out, and
            // the movers above cannot help a session that is busy (QuotaKnock.swift). Same door and
            // the same gates, after the request station rather than beside it - a tick that has just
            // typed somebody's line has spent this composer's turn, and so has one that has just
            // typed the resume above.
            let knocked = applyQuotaKnock(&quotaKnock, pid: supervisorPID, provider: provider.id,
                                          account: account, primaryModel: effectivePrimary,
                                          typedAlready: action.typed != nil || resumed != nil,
                                          session: board.state,
                                          quiet: board.quiet,
                                          turnEnded: turnOver, keyboardIdle: composerIdle,
                                          relaunchPlanned: replacingChild,
                                          draftSuspected: draftSuspected, quarantine: quarantine,
                                          reserves: reserves,
                                          // The reading taken when THIS child was launched, not one
                                          // taken now: a settings.json edited since says nothing
                                          // about the hooks the running process holds.
                                          filing: { quotaKnockFiling })
            // The third writer into this composer, recorded on the same terms as the two above it:
            // what makes the next tick's draft reading right is that EVERY one of them says when it
            // typed, since a supervisor that read its own footprints as somebody's draft would
            // decline the preventive move for the rest of that session's life.
            if knocked != nil { lastComposerWrite = Date() }

            // Execute the tick's one relaunch: terminate the child once, then apply any
            // model/effort/extra flags this plan carries on top of the resumed args. A pending app
            // update rides along on THIS restart instead of waiting for an idle moment that only
            // starts counting again after it (a cap handoff at 06:34 and the self-update it
            // deferred at 06:36, session c80ebeb2, 2026-07-26). Decided before anything is
            // terminated, and against the account the plan moves TO, so the new build resumes the
            // conversation where this handoff is about to put it rather than on the old account.
            if let plan {
                if !replacingChild {
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
                    return .keepPolling   // the child keeps running; the next tick decides afresh
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
                // Read before the move, because the sentence one line down names it: which account
                // this conversation is LEAVING is the half of that news that explains why its turn
                // died, and after the handoff there is nothing left holding it.
                let leaving = account
                performHandoff(to: plan.target, reason: plan.reason, countingFuse: plan.countsFuse,
                               fresh: plan.fresh)
                // AND WHETHER THE NEXT CHILD IS OWED A LINE ASKING IT TO CARRY ON (CapResume.swift
                // owns every gate): a cap handoff whose wall cut a turn short leaves work sitting in
                // a conversation nobody is going to resume by itself. Raised HERE rather than at the
                // plan, because `performHandoff` has just relocated the transcript with a forced
                // fork check, so this is the first point in the tick where the id being resumed is
                // the one the conversation is really in. It only ever RAISES an arm; whether that
                // line is ever typed is decided tick by tick against the child that follows.
                capResume.arm(reason: plan.reason, fresh: plan.fresh, cappedAt: pendingCap?.cappedAt,
                              answeredAt: watcher.lastMainChainEventAt,
                              conversation: watcher.transcriptSessionID,
                              from: leaving, to: plan.target,
                              userTurnAt: watcher.lastUserTurnAt)
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
                //
                // A FRESH RELAUNCH HAS NOTHING TO REPUBLISH, because what it starts is a different
                // conversation: the reading is retired here rather than moved. The watcher standing
                // beside this line still holds the id and the size of the window that was just
                // closed, so republishing them under the new account attributes a dead conversation
                // to it - a context the panel paints for a window nobody is in, and an id every hook
                // matches its events against, dropping the new conversation's notifications, its
                // agent roll call and its turn-end fact for as long as it stands (HookNotify.swift,
                // HookAgents.swift). Nothing corrects it soon either: the next child's watcher starts
                // with no token reading at all, and `sync` publishes nothing until that conversation
                // writes its first turn with usage in it (codex review of a599a06).
                if plan.fresh {
                    sessionContext.conversationEnded(pid: supervisorPID)
                } else {
                    let nextAxes = publishedSessionAxes(pin: sessionModelState.pin,
                                                        launchArgs: launchArgs, observed: nil)
                    sessionContext.accountChanged(to: account.id, pin: manualMoves.sessionPin,
                                                  axes: nextAxes,
                                                  transcript: watcher.transcriptSessionID,
                                                  pid: supervisorPID)
                }
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
                return .childReplaced
            }
            return .keepPolling
        }

        child.poll()
        while child.isRunning {
            usleep(2_000_000)
            child.poll()
            guard child.isRunning else { break }
            // The pool the whole tick runs in, and the one line this loop exists to hold: what it
            // reclaims is every Foundation temporary the tick made, which had nowhere else to go.
            if autoreleasepool(invoking: tick) == .childReplaced { break }
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
