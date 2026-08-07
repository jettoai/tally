import Darwin
import Foundation

// `tally` - launch a provider CLI on the account with the most proven headroom.
//
//   tally claude [args…]       launch `claude` on the best Claude account (args pass through);
//                              stays resident and auto-hands-off on a cap hit (see Supervisor.swift)
//   tally codex  [args…]       exec `codex` on the best Codex account
//   tally resume [args…]       continue this directory's latest Claude session on the best account
//   tally status [--json]      print every account's remaining windows (--json for scripts)
//   tally best-dir <provider>  print the `export CLAUDE_CONFIG_DIR=…` line for the best account
//
// Selection/launch plumbing lives in Snapshot.swift; auto-handoff in Supervisor.swift.
// Fail open: a missing/stale snapshot or no eligible account warns on stderr and runs the bare
// CLI - `tally claude` must never be the reason you can't start a session.

func runLaunch(_ provider: Provider, args: [String]) -> Never {
    // `--account <name>` pins a specific account (matched against the label or the config-dir
    // name, case-insensitive) - the manual override, so nobody needs hand-rolled per-account
    // aliases. The flag is tally's own; it is stripped before the args pass through.
    var passthrough = args
    var pinned: String?
    if let index = passthrough.firstIndex(of: "--account"), index + 1 < passthrough.count {
        pinned = passthrough[index + 1]
        passthrough.removeSubrange(index ... index + 1)
    }
    // `-w/--worktree [name]` launches inside a git worktree (claude only): resolve/create it, share
    // the project's memory, run the repo setup hook, and chdir so the supervisor and the CLI inherit
    // it. Done before the env early-exit below so even a bare passthrough runs in the worktree.
    let (wantsWorktree, worktreeName) = extractWorktreeFlag(&passthrough)
    if wantsWorktree, provider.id != "claude" {
        warn("--worktree is claude-only for now")
        exit(2)
    }
    // Suppress "continue" for a worktree with no conversation to continue (fresh, or a hand-made one
    // with no session yet): strip a hand-typed --continue/--resume (claude errors out continuing
    // nothing) and mark it new so the policy's continue-by-default is suppressed via wantsNew.
    let worktreeFresh = wantsWorktree ? enterWorktree(name: worktreeName) : false
    if worktreeFresh, stripContinueResume(&passthrough) {
        warn("no conversation in this worktree yet - starting fresh")
    }
    // A one-shot run is deliberately left unsupervised: every supervisor action restarts the child,
    // which resumes a conversation but RE-RUNS a command (LaunchFlags.swift). Read before the flag
    // is stripped, and before the worktree edit above can matter, because it is a question about
    // what the user actually asked for.
    let stdoutIsTTY = isatty(STDOUT_FILENO) == 1
    let wantsHandoff = shouldSupervise(args: passthrough, stdoutIsTTY: stdoutIsTTY)
    // Say so when the reason was the pipe, because that reason is invisible: `--print` is something
    // the user typed and `--no-handoff` is something they asked for, but a redirected stdout is a
    // property of the shell line, and a session silently losing its auto-handoff is the kind of
    // thing only noticed later, at the wall. On stderr, so it cannot land in the output being piped.
    // Only for the provider that would otherwise have had a supervisor: codex is a plain exec
    // either way (the `runSupervised` calls below are both behind `provider.id == "claude"`), so
    // telling a piped `tally codex` what it lost would be naming a thing it never had.
    if provider.id == "claude", !wantsHandoff, !stdoutIsTTY, autoHandoffEnabled(args: passthrough),
       !optionsOnly(passthrough).contains(where: { printFlags.contains($0) }) {
        warn("not supervised: stdout is not a terminal (claude runs one-shot when piped)")
    }
    // Tally's own flags, never passed through - and never taken out of the PROMPT, where the
    // same word belongs to the user (Snapshot.swift: `removingOption`).
    passthrough = removingOption(passthrough, "--no-handoff")
    // A running session follows a later Settings change to the default model/effort UNLESS the
    // user opted out (--no-follow) or typed their own --model or --effort (a deliberate choice
    // outranks the default, and the follow adopts the pair as a whole - it must never overwrite
    // a hand-typed flag). Captured before the policy injects its own flags below; the project
    // profile joins the same condition once it is read (`allowFollow`, further down).
    let followEnabled = autoFollowEnabled(args: passthrough)
        && !optionsOnly(passthrough).contains("--model")
        && !optionsOnly(passthrough).contains("--effort")
    passthrough = removingOption(passthrough, "--no-follow")

    // An explicitly exported config home is also the user choosing by hand - honour it.
    if pinned == nil, getenv(provider.envKey) != nil {
        warn("\(provider.envKey) already set - launching bare `\(provider.cli)` with it")
        exec(provider.cli, args: passthrough, env: nil)
    }
    let (snapshot, problem) = loadSnapshot()
    if let problem { warn(problem) }

    // Launch defaults, injected only when the user typed no flag of their own on the same axis -
    // explicit flags always win. Two sources, narrower first: this directory's own launch profile
    // (`tally project`) laid over the app's Settings. What that decides is not only what the session
    // runs but - through `primaryModel` below - which accounts it may run on. Resolved once; the cwd
    // cannot change under this process (the worktree chdir already happened).
    // `--new` is tally's own flag: it suppresses a "continue by default" setting for this one launch
    // and is never passed through.
    let project = projectPolicy(provider.id)
    let policy = effectivePolicy(launchPolicy(provider.id), project: project)
    // A project profile is as deliberate a choice about this session's pair as a typed flag, and
    // the follow adopts the Settings pair AS A WHOLE - letting it run would overwrite what the
    // project declared with the fleet-wide default it was written to escape.
    let allowFollow = followEnabled && project.model == nil && project.effort == nil
    let wantsNew = optionsOnly(passthrough).contains("--new") || worktreeFresh
    passthrough = removingOption(passthrough, "--new")
    passthrough = applyLaunchDefaults(passthrough, policy: policy, providerID: provider.id)

    // The start mode is the one launch default that cannot be decided up here: `--continue` is
    // resolved by claude against the config home it runs under, so whether injecting it produces a
    // session or "No conversation found to continue" depends on the account this launch lands on -
    // known only below. Every exec path therefore finalizes its args through this.
    func startModeArgs(_ args: [String], home: String) -> [String] {
        guard provider.id == "claude" else { return args }
        let (next, note) = applyStartMode(args, policy: policy, wantsNew: wantsNew, home: home)
        if let note { warn(note) }
        return next
    }

    if let pinned {
        let match: Snapshot.Account
        switch accountMatching(pinned, provider: provider.id, in: snapshot) {
        case .one(let account):
            match = account
        case .none:
            warn("no \(provider.id) account matches \"\(pinned)\" - try `tally status`")
            exit(1)
        case .several(let candidates):
            // Refused rather than picked, and refused rather than falling through to the headroom
            // pick below: `--account` is the flag that means "not the one you would have chosen",
            // so answering it with a choice of our own is the one thing it rules out.
            warn(accountMatchAmbiguity(pinned, provider: provider.id, candidates: candidates))
            exit(1)
        }
        warn("→ \(match.label) (pinned)")
        exec(provider.cli, args: startModeArgs(passthrough, home: match.launchHome!),
             env: launchEnv(provider, home: match.launchHome!))
    }

    // The pinned account: the app's launch policy (Settings → Launch account) or this project's own
    // `tally project set --account`, which the overlay above expressed as the same pin. A
    // `--account` flag outranks both (handled above).
    // "off" still auto-picks HERE: invoking `tally claude` is itself an explicit ask to pick -
    // off only means Tally must not steer launches it wasn't asked into (the PATH shim).
    if policy.mode == "manual" {
        let pinnedBy = project.accountID != nil ? "pinned for this project" : "pinned in Tally"
        if let match = snapshot?.accounts.first(where: {
            $0.id == policy.pinnedAccountID && $0.launchHome != nil
        }) {
            if headroom(match) <= 0 {
                warn("\(match.label) is out of quota - launching anyway (\(pinnedBy))")
            }
            warn("→ \(match.label) (\(pinnedBy))")
            let args = startModeArgs(passthrough, home: match.launchHome!)
            // Still supervised: a Tally pin can be MOVED from the panel mid-session (live pin
            // switch), so the supervisor stays resident; it won't cap-handoff while pinned.
            // A CLI --account pin remains a plain exec - that flag opts out of supervision.
            if provider.id == "claude", wantsHandoff {
                runSupervised(provider, account: match, args: args, follow: allowFollow)
            }
            exec(provider.cli, args: args, env: launchEnv(provider, home: match.launchHome!))
        }
        // The denormalized home, for a pin whose account is missing from this snapshot. NOT for one
        // the snapshot lists WITHOUT a launch home: that is Tally saying the login is gone, and
        // exec'ing it anyway drops the session into a signed-out config dir (AccountPick.swift).
        if let home = pinnedLaunchHome(snapshot, policy: policy) {
            warn("→ pinned account (set in Tally)")
            exec(provider.cli, args: startModeArgs(passthrough, home: home),
                 env: launchEnv(provider, home: home))
        }
        warn(pinnedAccountIsSignedOut(snapshot, policy: policy)
            ? "pinned account is signed out - renew its login in Tally; picking by headroom instead"
            : "pinned account not found - picking by headroom instead")
    }

    guard let snapshot else {
        warn("no eligible \(provider.id) account - launching bare `\(provider.cli)`")
        exec(provider.cli, args: startModeArgs(passthrough, home: defaultHome(provider)), env: nil)
    }
    // What the accounts are scored FOR: the model this launch will actually run, read off the args
    // it will run with (Snapshot.swift). The three sources were already ranked when the defaults
    // were injected, so a hand-typed `--model` reaches the pick exactly as it reaches the child -
    // scoring on `policy.model` here would have quietly ignored the flag the user typed.
    let primaryModel = launchPrimaryModel(passthrough, providerID: provider.id) ?? policy.model
    // Skip an account another session just saw cap: the snapshot lags the real cap, so its
    // percentage still reads healthy and picking it would drop a fresh session onto the wall that
    // just failed. `launchPick` also carries the "quarantine left nothing, launch anyway" fallback,
    // and is what `tally status` and the app's badge predict this launch with.
    let quarantined = quarantinedAccounts(forPrimary: primaryModel)
    guard let account = launchPick(providerID: provider.id, in: snapshot,
                                   primaryModel: primaryModel, quarantined: quarantined) else {
        warn("no eligible \(provider.id) account - launching bare `\(provider.cli)`")
        exec(provider.cli, args: startModeArgs(passthrough, home: defaultHome(provider)), env: nil)
    }
    warn("→ \(account.label) (\(pickReason(account, primaryModel: primaryModel)))")
    let args = startModeArgs(passthrough, home: account.launchHome!)
    // Claude sessions get the resident supervisor (auto-handoff on a cap hit); an explicit
    // `--account` pin or `--no-handoff` opts out, and codex stays a plain exec for now.
    if provider.id == "claude", wantsHandoff {
        runSupervised(provider, account: account, args: args, follow: allowFollow)
    }
    exec(provider.cli, args: args, env: launchEnv(provider, home: account.launchHome!))
}

/// The live sessions as `status --json` reports them: the published reading per account
/// (SessionContext.swift) turned into the report's own value type. Here rather than in either file,
/// because StatusReport.swift is a pure value type that must not learn where a supervisor publishes
/// anything, and SessionContext.swift must not learn what the JSON contract looks like.
func statusSessions() -> [String: StatusReport.SessionSummary] {
    supervisedSessionsByAccount().mapValues {
        StatusReport.SessionSummary(contextTokens: $0.contextTokens, model: $0.sessionModel,
                                    effort: $0.sessionEffort)
    }
}

func runStatus(json: Bool = false) {
    let (snapshot, problem) = loadSnapshot()
    if let problem { warn(problem) }
    guard let snapshot else { exit(1) }
    let advisor = loadAdvisorReadings(plans: accountPlans(snapshot))
    // The arrow marks the account a launch WOULD land on, so it has to skip what the launcher
    // skips: a quarantined account (see Quarantine.swift). Read once for both output shapes.
    //
    // Through the same overlay the launcher applies, and keyed on the directory this command was
    // run in: a project that declares opus is predicted on opus. A status that answered from the
    // fleet-wide default would name a different account than the launch a line later lands on,
    // which is the one thing a prediction may never do (ProjectPolicy.swift).
    let projectKey = projectPolicyKey()
    let projectFile = loadProjectPolicies()
    let policies = Dictionary(uniqueKeysWithValues: providers.map {
        ($0.id, effectivePolicy(launchPolicy($0.id),
                                project: projectFile.policy($0.id, for: projectKey)))
    })
    let quarantined = policies.mapValues { quarantinedAccounts(forPrimary: $0.model) }
    let profile = statusProjectProfile(projectFile, key: projectKey)
    if json {
        // Only the JSON shape carries the live sessions: the human output is a fleet summary, and
        // this is a per-conversation number a script asks for by name (SessionContext.swift).
        print(encodeStatusReport(statusReport(snapshot, policies: policies, advisor: advisor,
                                              quarantined: quarantined,
                                              sessions: statusSessions(),
                                              projectPolicy: profile)))
        return
    }
    // Said before the rows, because it changes how they read: these arrows were placed under this
    // project's model, not under the app's.
    let declaredHere = projectFile.declared(for: projectKey)
    for provider in providers {
        guard let declared = declaredHere[provider.id] else { continue }
        // Named as the rows below name it: the id is what the profile stores, and printing it
        // beside a list of labels asks the reader to do the join themselves.
        print("project \(projectKey): \(provider.id) runs " +
              projectPolicySummary(declared,
                                   accountLabel: projectPolicyAccountLabel(declared, in: snapshot)))
    }
    for provider in providers {
        let accounts = snapshot.accounts.filter { $0.provider == provider.id }
        guard !accounts.isEmpty else { continue }
        let policy = policies[provider.id] ?? LaunchPolicy()
        // Both markers from the one resolver the JSON uses (StatusReport.swift), so the two output
        // shapes cannot disagree about which account a launch would land on.
        let (bestID, pinnedID) = launchMarkers(providerID: provider.id, in: snapshot, policy: policy,
                                               quarantined: quarantined[provider.id] ?? [])
        for account in accounts {
            let pinned = account.id == pinnedID
            let marker = account.id == bestID ? "→" : " "
            var state = account.error.map { " !\($0)" } ?? (account.isStale ? " (stale)" : "")
            if pinned { state += " (pinned)" }
            if let resets = account.resetCreditsAvailable, resets > 0 {
                state += " · \(resets) reset\(resets == 1 ? "" : "s") banked"
            }
            print("\(marker) \(account.label): session \(fmt(account.sessionRemaining)) · " +
                  "weekly \(fmt(account.weeklyRemaining)) · model \(fmt(account.modelRemaining))\(state)")
        }
        // The pooled cross-account view, same vocabulary and units as the status line's fleet
        // zone: accounts' worth left per pool ("fable pool 0.0/2"), dry forecast or a
        // sustainable tick. Present only while the app's fleet gauge is on; older snapshots
        // carry only the single headline pool.
        let pools = (snapshot.fleetPools?[provider.id]
            ?? snapshot.fleet?[provider.id].map { [$0] } ?? [])
            .filter { $0.capacity > 0 }
        if !pools.isEmpty {
            let now = Date()
            let pieces = pools.map { pool -> String in
                var text = "\(poolLabel(pool.poolName)) "
                    + poolRemainingFigure(remaining: pool.remaining, capacity: pool.capacity)
                if let dryAt = pool.dryAt, dryAt > now {
                    text += " (~\(shortETA(dryAt.timeIntervalSince(now))) left)"
                } else if pool.sustainable {
                    text += " ✓"
                }
                return text
            }
            print("  fleet: \(pieces.joined(separator: " · "))")
        }
    }
    // The "should I add an account?" verdict per provider, from the recorded burn history. One
    // trailing line each (only when there is a reading), same vocabulary as the panel's strip.
    for reading in advisor {
        print("advisor: \(reading.provider) \(UsageAdvisor.englishHeadline(reading))")
    }
}

/// `tally resume` - hand this directory's latest Claude session to the account with the most
/// headroom and continue the SAME conversation there (the manual counterpart of auto-handoff).
///
/// Transcripts live per-account (`<home>/projects/<cwd-slug>/<session>.jsonl`); resuming on another
/// account needs the file present in that account's tree. Copy is additive only - never overwrites,
/// and a shared/symlinked projects dir (this machine's setup) needs no copy at all. Empirically
/// verified 2026-07-16: account 2 resumed account 1's session and recalled its content.
func runResume(args: [String]) -> Never {
    let provider = providers[0]   // claude only for now
    let (snapshot, problem) = loadSnapshot()
    if let problem { warn(problem) }
    guard let snapshot else { exit(1) }

    let slug = projectSlug(forCwd: FileManager.default.currentDirectoryPath)

    // Newest session for this directory across every account = the conversation to hand off.
    let claudeAccounts = snapshot.accounts.filter { $0.provider == provider.id && $0.launchHome != nil }
    var newest: (account: Snapshot.Account, file: URL, modified: Date)?
    for account in claudeAccounts {
        let dir = URL(fileURLWithPath: account.launchHome!).appendingPathComponent("projects/\(slug)")
        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for file in files where file.pathExtension == "jsonl" {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            if newest == nil || modified > newest!.modified {
                newest = (account, file, modified)
            }
        }
    }
    guard let newest else {
        warn("no Claude session found for this directory")
        exit(1)
    }
    let sessionID = newest.file.deletingPathExtension().lastPathComponent

    // The args this resume will RUN with: the launch defaults injected exactly as a fresh launch
    // injects them (a flag the user typed still wins), so the conversation comes back on the model
    // its project declared instead of on whatever the CLI defaults to.
    //
    // Scoring the accounts and launching the session read the SAME vector, which is the whole point
    // of building it here. They used to disagree: the pick was made for the project's model while
    // the exec passed the user's args through untouched, so a resume was placed on an account
    // chosen for opus and then ran fable on it - the one failure mode an account pick has no way to
    // recover from, because by then the session is already somewhere.
    //
    // The account pin a project may also declare is deliberately not read here: this command's
    // whole purpose is to move a conversation to a different account, and the app's own pin has
    // never been honoured here either.
    let effective = effectivePolicy(launchPolicy(provider.id), project: projectPolicy(provider.id))
    let resumeArgs = applyLaunchDefaults(args, policy: effective, providerID: provider.id)
    let primaryModel = launchPrimaryModel(resumeArgs, providerID: provider.id) ?? effective.model
    let target = snapshot.accounts
        .filter { $0.provider == provider.id && eligible($0, primaryModel: primaryModel)
            && $0.id != newest.account.id }
        .max {
            smartScore($0, primaryModel: primaryModel) < smartScore($1, primaryModel: primaryModel)
        } ?? newest.account
    if target.id == newest.account.id {
        warn("no other eligible account - resuming on \(target.label)")
    }

    // Make the transcript visible to the target (no-op when the projects tree is shared/symlinked;
    // never overwrite an existing file).
    let sourceResolved = newest.file.resolvingSymlinksInPath()
    let destDir = URL(fileURLWithPath: target.launchHome!).appendingPathComponent("projects/\(slug)")
    let dest = destDir.appendingPathComponent(newest.file.lastPathComponent)
    if dest.resolvingSymlinksInPath() != sourceResolved,
       !FileManager.default.fileExists(atPath: dest.path) {
        try? FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        do {
            try FileManager.default.copyItem(at: newest.file, to: dest)
        } catch {
            warn("cannot copy transcript to \(target.label): \(error.localizedDescription)")
            exit(1)
        }
    }

    warn("→ resuming \(sessionID.prefix(8))… from \(newest.account.label) on \(target.label) " +
         "(\(pickReason(target, primaryModel: primaryModel)))")
    exec(provider.cli, args: ["--resume", sessionID] + resumeArgs,
         env: launchEnv(provider, home: target.launchHome!))
}

// MARK: - Entry

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case "claude":
    runLaunch(providers[0], args: Array(arguments.dropFirst()))
case "codex":
    runLaunch(providers[1], args: Array(arguments.dropFirst()))
case "resume":
    runResume(args: Array(arguments.dropFirst()))
case "worktree":
    runWorktree(args: Array(arguments.dropFirst()))
case "project":
    runProject(args: Array(arguments.dropFirst()))
case "status", nil:
    runStatus(json: arguments.contains("--json"))
case "best-dir":
    runBestDir(arguments.dropFirst().first ?? "claude")
case "launch-dir":
    runLaunchDir(arguments.dropFirst().first ?? "codex")
case "statusline":
    runStatusline(args: Array(arguments.dropFirst()))
case "reload":
    exit(runReload(args: Array(arguments.dropFirst())))
// `account` is the name this is called by now, matching the slash command (`/tally-account`) and
// the axis it sets, the way `model` does. `switch` still answers: it is in muscle memory, in the
// skill files installed by older app versions, and in whatever anyone wrote down.
case "account", "switch":
    exit(runSwitch(args: Array(arguments.dropFirst())))
case "model":
    exit(runModel(args: Array(arguments.dropFirst())))
case "hook-switch":   // internal: the `/tally-account` prompt hook (SwitchHook.swift)
    exit(runHookSwitch())
case "hook-model":    // internal: the `/tally-model` prompt hook (ModelHook.swift)
    exit(runHookModel())
case resuperviseCommand:   // internal: a supervisor replacing itself after an app update
    runResupervise(args: Array(arguments.dropFirst()))
case "update":
    runUpdate()
case "add":
    runAdd(args: Array(arguments.dropFirst()))
default:
    warn("""
    usage:
      tally claude [args…]      launch Claude Code on the best account (auto-handoff on cap hit;
                                opt out with --no-handoff or TALLY_AUTO_HANDOFF=0)
      tally claude --account <n>  pin a specific account (label or config-dir name)
      tally claude -w [name]    launch in a git worktree (creates ../<repo>-<name> if needed,
                                shares project memory, runs .tally/worktree-setup.sh); bare -w lists existing
      tally codex [args…]       launch Codex on the best account
      tally resume [args…]      continue this directory's latest Claude session on the best account
      tally worktree            overview of the main repo and its worktrees, marking where you
                                are (same as `tally worktree tree`)
      tally worktree root       print the main repo's absolute path, one line for scripts
      tally worktree list       one tab-separated line per worktree, for grep and pipes
      tally worktree remove [name]  tear down a merged worktree (kill its agents, remove the
                                worktree and its branch, keeping their transcripts unless
                                --purge-transcripts); bare picks from a menu
      tally project set --model <model> [--effort <effort>] [--account <name>]
                                declare what THIS project launches (the whole repo, worktrees
                                included): overrides the app's defaults, is overridden by a flag
                                you type, and steers the account pick too - a project on opus
                                stops letting a drained flagship window rule an account out.
                                `show` / `list` / `clear` round it out
      tally status [--json]     show every account's remaining windows (--json: versioned
                                machine-readable report for scripts, hooks, agent skills)
      tally best-dir <provider> print the export line for the best account
      tally launch-dir <provider> shim interface: like best-dir but honours the app's
                                launch policy (off → prints nothing)
      tally add <provider>      log in one more account (next free ~/.claudeN / ~/.codexN,
                                directory created for you). The main account's harness
                                (CLAUDE.md/AGENTS.md, skills, hooks, agents, settings) and
                                conversation record are symlinked in BY DEFAULT: one setup
                                serves every account. Opt out with --no-share
      tally account <account>   pin THIS session to another account, keeping the conversation: run
                                it inside the session (the agent in it can run it too) and the move
                                happens when the current turn ends. It STAYS there - automatic
                                selection stops moving this session - until `tally account --auto`
                                releases it. A hard cap is answered inside that decision where it
                                can be: the session keeps the account and drops to the fallback
                                model declared in Settings. Only when this account can serve none of
                                those is it handed on, which clears the pin and says so. No project
                                profile is touched: for "this project always runs
                                there", use `tally project set --account`. Inside Claude Code,
                                typing `/tally-account <account>` does the same without waking a
                                model (installed with the Claude Code skill integration). Also
                                answers to `tally switch`, the name it shipped under
      tally account --auto      release that pin: this session follows automatic account selection
                                again (the project profile, then the app's pin or smart pick)
      tally model <model> [effort]
                                run THIS conversation on that model (and depth) for the rest of its
                                life: it changes when the current turn ends and STAYS, surviving
                                every relaunch - a cap handoff, a reload, an app self-update - which
                                is what Claude Code's own `/model` cannot do, since the supervisor
                                relaunches from its own command line. Name only a model and the
                                effort is left alone. `tally model auto` hands the session back to
                                this project's profile and then the app's default; bare, in a
                                terminal, it shows what is running and offers a menu. Inside Claude
                                Code, `/tally-model opus xhigh` does the same without waking a model
                                (installed with the Claude Code skill integration)
      tally reload [--now]      restart every supervised session at its next idle moment, so edited
                                hooks, skills, and instructions take effect everywhere without
                                visiting each terminal (--now waits only for a 5s quiet gap, so it
                                may land closer to an active turn)
      tally update              check for app updates now (opens the update window)
    """)
    exit(2)
}
