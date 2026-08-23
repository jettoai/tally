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
    // it. Done before the exported-home exit below, so even that launch runs in the worktree.
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

    // An exported config home is the user choosing the ACCOUNT by hand, and that is the ONLY axis
    // it settles. What it used to skip was everything: this test sat above the policy read, so an
    // exported CLAUDE_CONFIG_DIR also threw away the permission mode, the model, the fallback
    // model, the effort and the start mode - none of which is a statement about which account runs.
    // Any session launched from inside another one exports the variable, so Settings could read
    // bypass on fable/high while the launch came up in manual mode on the CLI's own default
    // (owner-reported, 2026-08-13).
    //
    // The home comes from the environment rather than from the snapshot because the exported value
    // IS the answer, and `--continue` has to be resolved against that same directory: asking the
    // account we would otherwise have picked would predict a conversation this launch cannot reach.
    //
    // A plain exec on purpose, never `runSupervised`: the supervisor's job is to move a session to
    // another account on a cap hit, and a hand-pinned home leaves it nowhere to move to. `--account`
    // still outranks this (the branch below, which the `pinned == nil` guard falls through to):
    // that flag names an account, this variable names a config directory.
    //
    // …unless nobody exported it. A terminal started from inside a session inherits that session's
    // whole environment, so every window opened afterwards arrives carrying one account's home and
    // reads as a hand pin: the machine silently stuck on one account (owner-reported 2026-08-13, the
    // same evening as the defect above). What gives a leak away is Claude Code's own child marker in
    // a launch somebody typed (`inheritedSessionEnvironment`, Snapshot.swift), and a leak is not a
    // choice - so the exit stands down and this launch picks normally, supervisor and all. The
    // marker is dropped from the environment as well, because Claude Code reads it as "you are a
    // child session" and stops saving the transcript. A REAL child (the same marker, stdout on a
    // pipe) keeps both: following its parent's home is what stops one conversation picking a second
    // account, and `! tally claude` typed inside a session is the accepted cost of that test - it
    // reads as a leak and picks by policy, with `--account` still there to pin it by hand.
    let inheritedEnvironment = inheritedSessionEnvironment(providerID: provider.id,
                                                           stdoutIsTTY: stdoutIsTTY)
    if inheritedEnvironment {
        // Said only when a home was actually inherited: the marker can outlive the variable, and a
        // launch that was never going to read one has nothing to report.
        if getenv(provider.envKey) != nil {
            warn("\(provider.envKey) was inherited from another session rather than exported by "
                + "you - ignoring it and choosing the account normally")
        }
        // "Ignoring it" has to be true of every exec below, not only of the exit that reads the
        // variable. Two of them hand the child `env: nil` (the bare "no eligible account"
        // fallbacks), which means THIS process's environment: a leaked home left sitting in it
        // would run the fallback under the very account the warning above says is being ignored,
        // and under one whose `--continue` was resolved against the default home - the launcher
        // deciding against one directory and running in another. Unconditional because unsetting a
        // variable that is not there is nothing; the warning above is the part that needs the ask.
        unsetenv(provider.envKey)
        unsetenv(childSessionMarker)
    }

    if pinned == nil, !inheritedEnvironment, let exported = getenv(provider.envKey) {
        warn("\(provider.envKey) already set - keeping that account, launch defaults still apply")
        let home = String(cString: exported)
        launchProvider(provider, args: startModeArgs(passthrough, home: home), home: home, env: nil)
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
        launchProvider(provider, args: startModeArgs(passthrough, home: match.launchHome!),
                       home: match.launchHome!,
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
            launchProvider(provider, args: args, home: match.launchHome!,
                           env: launchEnv(provider, home: match.launchHome!))
        }
        // The denormalized home, for a pin whose account is missing from this snapshot. NOT for one
        // the snapshot lists WITHOUT a launch home: that is Tally saying the login is gone, and
        // exec'ing it anyway drops the session into a signed-out config dir (AccountPick.swift).
        if let home = pinnedLaunchHome(snapshot, policy: policy) {
            warn("→ pinned account (set in Tally)")
            launchProvider(provider, args: startModeArgs(passthrough, home: home), home: home,
                           env: launchEnv(provider, home: home))
        }
        warn(pinnedAccountIsSignedOut(snapshot, policy: policy)
            ? "pinned account is signed out - renew its login in Tally; picking by headroom instead"
            : "pinned account not found - picking by headroom instead")
    }

    guard let snapshot else {
        warn("no eligible \(provider.id) account - launching bare `\(provider.cli)`")
        launchProvider(provider, args: startModeArgs(passthrough, home: defaultHome(provider)),
                       home: defaultHome(provider), env: nil)
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
    // What each account's owner keeps for their own browser use (AccountReserve.swift). Read HERE
    // and nowhere above: every branch that got this far chose an account by name - a `--account`
    // flag, a panel pin, this project's own pin - and a reserve is an instruction about the picks
    // Tally makes for itself.
    let reserves = accountReserves()
    guard let account = launchPick(providerID: provider.id, in: snapshot,
                                   primaryModel: primaryModel, quarantined: quarantined,
                                   reserves: reserves) else {
        warn("no eligible \(provider.id) account - launching bare `\(provider.cli)`")
        launchProvider(provider, args: startModeArgs(passthrough, home: defaultHome(provider)),
                       home: defaultHome(provider), env: nil)
    }
    // The whole fleet is under its own water line and this launch had to spend some of it anyway:
    // said before the arrow, because it is the part of the sentence the reader did not expect.
    if let dip = reserveDipNotice(account, primaryModel: primaryModel, reserves: reserves) {
        warn(dip)
    }
    warn("→ \(account.label) (\(pickReason(account, primaryModel: primaryModel)))")
    let args = startModeArgs(passthrough, home: account.launchHome!)
    // Claude sessions get the resident supervisor (auto-handoff on a cap hit); an explicit
    // `--account` pin or `--no-handoff` opts out, and codex stays a plain exec for now.
    if provider.id == "claude", wantsHandoff {
        runSupervised(provider, account: account, args: args, follow: allowFollow)
    }
    launchProvider(provider, args: args, home: account.launchHome!,
                   env: launchEnv(provider, home: account.launchHome!))
}

func runStatus(json: Bool = false) {
    let (snapshot, problem) = loadSnapshot()
    if let problem { warn(problem) }
    guard let snapshot else {
        // THE RUN WITH NO REPORT IN IT IS THE ONE THAT NEEDS THE WAY OUT MOST: there is no snapshot
        // before the app has run once, so this is what somebody typing the binary's own name gets on
        // a fresh machine, and the warning above it names a file rather than a command. Same line as
        // the full report ends on and on the same stream, so it is read in the same place whichever
        // way this command came out - the human output is prose either way, and the JSON shape is
        // the contract, so it stays silent here as it does at the foot of the report.
        if !json { print(tallyStatusHelpHint) }
        exit(1)
    }
    // What each account's owner keeps for their own use, read once for the whole report: the arrow
    // predicts a launch and the advisor's verdict is about the capacity Tally may actually spend,
    // so both read it (AccountReserve.swift).
    let reserves = accountReserves()
    let advisor = loadAdvisorReadings(plans: accountPlans(snapshot),
                                      reserves: accountReserveIDs(snapshot, reserves))
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
        // these are per-conversation answers a script asks for by name (SessionInventory.swift) -
        // how big the conversation on each account is, and where every session on the machine is
        // running. ONE VALUE for both blocks, which is one scan: asked separately they could
        // describe different moments.
        let live = sessionReadings()
        print(encodeStatusReport(statusReport(snapshot, policies: policies, advisor: advisor,
                                              quarantined: quarantined,
                                              accountSessions: live.accountSessions,
                                              sessions: live.sessions,
                                              projectPolicy: profile, reserves: reserves)))
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
                                               quarantined: quarantined[provider.id] ?? [],
                                               reserves: reserves)
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
        // The pooled cross-account view: the share of each pool still unspent ("fable pool 12%"),
        // with a dry forecast or a sustainable tick. THE ONLY CLI SURFACE THAT PRINTS A POOL - the
        // status line is a session reading (this account, this model, this account's windows), and
        // this report is where somebody asks about the fleet. Present only while the app's fleet
        // gauge is on; older snapshots carry only the single headline pool.
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
    // …and the way out of this report into everything else the binary does (`tallyStatusHelpHint`).
    // Human output only: the JSON shape returned above, and a line of prose in it would be a parse
    // error for every script reading the contract.
    print(tallyStatusHelpHint)
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
// The acts a supervised session can be asked to perform on ITSELF, as opposed to the axes it runs
// on. A namespace from the first verb (SessionInputCommand.swift states why).
case "session":
    exit(runSession(args: Array(arguments.dropFirst())))
case "hook-tally":    // internal: the `/tally` prompt hook (TallyHook.swift)
    exit(runHookTally(args: Array(arguments.dropFirst())))
case "hook-notify":   // internal: Claude Code's Notification hook (UserNotice.swift)
    exit(runHookNotify(args: Array(arguments.dropFirst())))
// internal: Claude Code's three subagent-facing hooks, which take the event as their argument
// because one subcommand answers all three (HookAgents.swift).
case "hook-agents":
    exit(runHookAgents(args: Array(arguments.dropFirst())))
// internal: Claude Code's two context-carrying hooks, which take the event as their argument for
// the reason the three above do - one subcommand answers both, and the answer has to name the event
// it is answering (HookKnock.swift).
case "hook-knock":
    exit(runHookKnock(args: Array(arguments.dropFirst())))
// internal: Claude Code's `PreToolUse` hook on the `Artifact` tool, which takes no argument because
// it answers for exactly one tool - the matcher it is registered under names it, and the payload
// names it again (HookArtifact.swift).
case "hook-artifact":
    exit(runHookArtifact())
// The two the merge replaced. Still answered, because a registration written by an older app is in
// somebody's settings.json until the self-heal rewrites it, and a hook that runs a subcommand this
// binary does not have prints usage and lets the expansion through - a model turn, for a command
// whose whole point is not spending one.
case "hook-switch":   // internal: the pre-merge `/tally-account` prompt hook (SwitchHook.swift)
    exit(runHookSwitch(args: Array(arguments.dropFirst())))
case "hook-model":    // internal: the pre-merge `/tally-model` prompt hook (ModelHook.swift)
    exit(runHookModel(args: Array(arguments.dropFirst())))
case mcpServeCommand:   // internal: the MCP server behind the native pickers (MCPServe.swift)
    exit(runMCPServe())
case resuperviseCommand:   // internal: a supervisor replacing itself after an app update
    runResupervise(args: Array(arguments.dropFirst()))
case "completion":
    exit(runCompletion(args: Array(arguments.dropFirst())))
case "update":
    runUpdate()
case "add":
    runAdd(args: Array(arguments.dropFirst()))
// What `add` does for an account it creates, done to one that is already here (ShareCommand.swift).
case "share":
    exit(runShare(args: Array(arguments.dropFirst())))
// The one act of repair this binary performs on somebody else's data, and it is repair of damage
// this binary did (KeychainPartitionRepair.swift). Run by hand, by every launch, and once by the app
// at startup; the exit code is what the last of those would read if it read anything.
case "keychain-repair":
    exit(runKeychainRepair())
// ASKED FOR, so it is an answer rather than a complaint: stdout and a zero exit, which is what a
// shell pipeline and a person typing `tally help | less` both read. The default branch below
// prints the very same text on stderr with exit 2, because a word this binary does not know is an
// error - and one of those two is what every wrapper around this binary is checking for.
case "help", "--help", "-h":
    print(tallyUsage)
    exit(0)
default:
    warn(tallyUsage)
    exit(2)
}
