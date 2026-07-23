import Darwin
import Foundation

// Auto-handoff supervision (Phase B).
//
// `tally claude` stays resident as a thin parent around the interactive claude child. It tails the
// session transcript for a cap-hit event; on a hit it terminates the child, re-picks the best other
// account, and relaunches `claude --resume <session>` in the same terminal - the conversation
// continues on the fresh account with no manual step. The transcript tailer that detects the cap
// lives in TranscriptWatcher.swift; the value types and pure helpers in SupervisorRuntime.swift.

/// posix_spawnp keeping the child in OUR process group. Foundation's `Process` puts the child in
/// a NEW process group, so the interactive child is background to the terminal and job control
/// stops it with SIGTTIN the moment it reads (claude suspended `T`, blank screen, 2026-07-18).
/// Same-group spawn reproduces what a plain exec gives: the child shares the foreground group.
private func spawnChild(_ argv: [String], environment: [String: String]) -> pid_t? {
    var cArgs: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) }
    cArgs.append(nil)
    var cEnv: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") }
    cEnv.append(nil)
    defer { for pointer in cArgs + cEnv { free(pointer) } }
    var pid: pid_t = 0
    return posix_spawnp(&pid, argv[0], nil, nil, cArgs, cEnv) == 0 ? pid : nil
}

/// Resident supervision: spawn claude, tail its transcript, hand off on a cap hit.
///
/// `follow`: adopt a later change to the launch-default model at the next quiet moment. The caller
/// sets it false when the user typed their own `--model` or passed `--no-follow`.
func runSupervised(_ provider: Provider, account initial: Snapshot.Account, args: [String],
                   follow: Bool = false) -> Never {
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
    /// True while a follow adoption has nowhere to land (no account can serve the new model), so
    /// the "waiting" note is shown once, not every tick. Cleared when an account frees up.
    var followDeadEnd = false
    /// The recovery fuse for THIS supervisor, held across relaunches: at most 3 automatic
    /// cross-account recoveries per 10 minutes (a cap handoff or a degradation rescue). In memory
    /// and per process, so a fleet-wide drain never trips one session on another's account
    /// switches. Deliberate moves (pin, follow) and same-account relaunches (fallback) do not count.
    var fuse = RecoveryFuse()
    /// Accounts THIS supervisor saw cap, excluded from its own automatic picks until the TTL
    /// passes (union with the cross-supervisor shared records). Persists across relaunches.
    var quarantine: [String: Date] = [:]
    /// Stamped into the child env so the status line can tell whether the supervisor watching this
    /// session is the current build (a session launched before an app update runs stale logic).
    let supervisorVersion = supervisorBuildVersion()
    let supervisorPID = String(getpid())

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
            kill(childPID, SIGTERM)   // let claude run its SessionEnd cleanup
            _ = awaitChild()

            watcher.locateFile()
            let sessionFile = watcher.file
            if let sessionFile {
                // Make the transcript visible to the target account (no-op on a shared tree).
                let sourceResolved = sessionFile.resolvingSymlinksInPath()
                let destDir = URL(fileURLWithPath: target.launchHome!)
                    .appendingPathComponent("projects/\(slug)")
                let dest = destDir.appendingPathComponent(sessionFile.lastPathComponent)
                if dest.resolvingSymlinksInPath() != sourceResolved,
                   !FileManager.default.fileExists(atPath: dest.path) {
                    try? FileManager.default.createDirectory(at: destDir,
                                                             withIntermediateDirectories: true)
                    try? FileManager.default.copyItem(at: sessionFile, to: dest)
                }
            }

            logHandoff(sessionID: sessionFile?.deletingPathExtension().lastPathComponent,
                       from: fromLabel, to: target.label, reason: reason)
            if countingFuse { fuse.record() }
            account = target
            var next: [String] = []
            var skip = false
            for argument in launchArgs {
                if skip { skip = false; continue }
                switch argument {
                case "--continue", "-c": continue
                case "--resume", "-r": skip = true; continue
                default: next.append(argument)
                }
            }
            if let sessionFile {
                launchArgs = ["--resume", sessionFile.deletingPathExtension().lastPathComponent] + next
            } else {
                launchArgs = next
            }
            handoff = true
        }

        // A cap this child could not hand off yet: remembered across poll ticks so a blocked
        // handoff retries instead of stranding the session. Reset per child - a fresh launch is
        // a clean slate; the previous account's cap is not this one's.
        var pendingCap: PendingCapRecovery?

        pollChild()
        while childStatus == nil {
            usleep(2_000_000)
            pollChild()
            guard childStatus == nil else { break }
            let policy = launchPolicy(provider.id)
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
                pendingCap = PendingCapRecovery(
                    cappedAccountID: account.id, cappedAt: Date(),
                    primaryModel: flagValue(launchArgs, "--model") ?? policy.model,
                    nextRetry: .distantPast, reason: "")
                // Keep every session (this one and any launching now) off the account that just
                // capped until its snapshot catches up.
                let until = Date().addingTimeInterval(capQuarantineTTL)
                quarantine[account.id] = until
                quarantineAccount(account.id, until: until)
            }

            // Live pin switch: pinning another account in the Tally panel moves the RUNNING
            // session there. An explicit human act, so no fuse; the pinned account is used even
            // when capped (that is what pinning means). Waits for a quiet transcript so an
            // in-flight response is never cut mid-stream (the next 2s poll retries).
            if policy.mode == "manual", let pinnedID = policy.pinnedAccountID, pinnedID != account.id,
               watcher.isQuiet() {
                let (snapshot, _) = loadSnapshot()
                if let target = snapshot?.accounts.first(where: {
                    $0.id == pinnedID && $0.provider == provider.id && $0.launchHome != nil
                }) {
                    warn("pinned in Tally → switching to \(target.label)")
                    plan = RelaunchPlan(target: target, reason: "pin", countsFuse: false)
                }
            }

            // Cap handoff / wait: a pending cap outranks follow, rescue, and fallback (the pin
            // switch above still wins - moving the pin is an explicit "go here" even mid-cap). The
            // handoff is retried at a backoff while blocked, and the terminal warns only when the
            // waiting reason changes, so a stuck session is never noisy and never abandoned.
            if plan == nil, var pending = pendingCap {
                guard Date() >= pending.nextRetry else { continue }
                let (snapshot, snapshotProblem) = loadSnapshot()
                let primary = pending.primaryModel
                let excluded = quarantinedAccounts(sessionLocal: quarantine)
                let target = snapshot?.accounts
                    .filter { $0.provider == provider.id && eligible($0, primaryModel: primary)
                        && $0.id != account.id && !excluded.contains($0.id) }
                    .max { smartScore($0, primaryModel: primary)
                        < smartScore($1, primaryModel: primary) }
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
                    continue
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
            if follow {
                let desired = (policy.model?.lowercased(), policy.effort?.lowercased())
                if desired == (followedModel, followedEffort) {
                    pendingSince = nil
                } else if pendingSince == nil || desired != (pendingModel, pendingEffort) {
                    (pendingModel, pendingEffort) = desired
                    pendingSince = Date()
                } else if let since = pendingSince,
                          plan != nil || Date().timeIntervalSince(since) >= followDebounce,
                          watcher.isQuiet() {
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
                            let excluded = quarantinedAccounts(sessionLocal: quarantine)
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
                            continue
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
                }
            }

            // The session's ACTUAL model degraded away from the declared primary (claude fell
            // back server-side - e.g. the flagship weekly ran dry). Flagship-first response:
            // a sibling whose flagship window still has real room takes the conversation and
            // KEEPS the primary model. Not for pinned sessions (a pin means "this account"),
            // and under the same fuse as every automatic handoff.
            // The expectation is what THIS session was launched with (a hand-typed --model
            // outranks the configured default - a deliberate haiku session must not be
            // "rescued" back to fable).
            let effectivePrimary = flagValue(launchArgs, "--model") ?? policy.model
            if plan == nil, let primary = effectivePrimary?.lowercased(),
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
                let excluded = quarantinedAccounts(sessionLocal: quarantine)
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
            if plan == nil, !fallbackApplied,
               let fallbackList = policy.fallbackModel,
               policy.fallbackEffort != nil || policy.fallbackArgs != nil,
               let actual = watcher.lastModel?.lowercased(),
               (flagValue(launchArgs, "--model") ?? policy.model)
                   .map({ !actual.contains($0.lowercased()) }) ?? true,
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

            // Execute the tick's one relaunch: terminate the child once, then apply any
            // model/effort/extra flags this plan carries on top of the resumed args.
            if let plan {
                performHandoff(to: plan.target, reason: plan.reason, countingFuse: plan.countsFuse)
                if plan.model != nil || plan.effort != nil || !plan.extraArgs.isEmpty {
                    launchArgs = removingFlagPairs(launchArgs, ["--model", "--effort"])
                    if let model = plan.model { launchArgs += ["--model", model] }
                    if let effort = plan.effort { launchArgs += ["--effort", effort] }
                    launchArgs += plan.extraArgs
                }
                break
            }
        }

        if handoff { continue }
        let status = awaitChild()   // no relaunch pending: the child exited on its own, so do we
        let exited = (status & 0x7f) == 0
        exit(exited ? (status >> 8) & 0xff : 128 + (status & 0x7f))
    }
}
