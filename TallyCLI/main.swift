import Darwin
import Foundation

_ = runCodexPTYChildIfRequested()

// `tally` - launch a provider CLI on the account with the most proven headroom.
//
//   tally claude [args…]       launch `claude` on the best Claude account (args pass through);
//                              stays resident and auto-hands-off on a cap hit (see Supervisor.swift)
//   tally codex  [args…]       launch and monitor interactive Codex sessions on the best account
//   tally resume [args…]       continue this directory's latest Claude session on the best account
//   tally status [--json]      print every account's remaining windows (--json for scripts)
//   tally best-dir <provider>  print the `export CLAUDE_CONFIG_DIR=…` line for the best account
//
// Selection/launch plumbing lives in Snapshot.swift; auto-handoff in Supervisor.swift.
// Fail open: a missing/stale snapshot or no eligible account warns on stderr and runs the bare
// CLI. The one refusal is a reserve (B-1213): every launchable account under its owner's line, or
// a named one under it (`--account`, a pin, an exported home), exits 1 unless `--spend-reserve`.

func runLaunch(_ provider: Provider, args: [String]) -> Never {
    // `--account <name>` pins a specific account (matched against the label or the config-dir
    // name, case-insensitive) - the manual override, so nobody needs hand-rolled per-account
    // aliases. The flag is tally's own; it is stripped before the args pass through.
    var passthrough = args
    let pinned = takeAccountFlag(&passthrough)
    // `-w/--worktree [name]` launches inside a git worktree (claude only): resolve/create it, share
    // the project's memory, run the repo setup hook, and chdir so the supervisor and the CLI inherit
    // it. Done before the decision below, so every launch it settles runs in the worktree.
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
    // What the launch's own args, environment and terminal ask for (LaunchDecision.swift): whether
    // it is a one-shot run, the opt-outs, an exported or inherited config home, Tally's own flags.
    let stdoutIsTTY = isatty(STDOUT_FILENO) == 1
    let intent = launchIntent(provider, args: passthrough, accountFlag: pinned,
                              stdoutIsTTY: stdoutIsTTY)
    passthrough = intent.passthrough
    // Say so when the pipe is why a Claude session is left unsupervised, the one reason nobody
    // typed: a session silently losing its auto-handoff is only noticed later, at the wall. On
    // stderr, out of the piped output. Piped Codex commands deliberately remain one-shot.
    if provider.id == "claude", intent.pipedOnly {
        warn("not supervised: stdout is not a terminal (claude runs one-shot when piped)")
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
    let wantsNew = optionsOnly(passthrough).contains("--new") || worktreeFresh
    passthrough = removingOption(passthrough, "--new")
    passthrough = applyLaunchDefaults(passthrough, policy: policy, providerID: provider.id)

    // The start mode needs the config home this launch lands on, settled only below, so every exec
    // path finalizes its args through this. What it injects is `--resume <id>` rather than a bare
    // `--continue`, because that flag answers out of a pointer private to whichever account was
    // picked - which walked the conversation backwards a launch at a time (LaunchResume.swift). The
    // live set is read HERE, once, so the decision is made against the sessions running in this
    // directory at this instant.
    /// The cleared, never-used conversation the start mode declined to resume, for the supervisor
    /// to find its task list by (TaskListPin.swift).
    var clearedConversation: String? = nil
    func startModeArgs(_ args: [String], home: String, preflight: Bool = true) -> [String] {
        if provider.id == "codex" {
            let next = applyCodexStartMode(args, policy: policy, wantsNew: wantsNew, home: home,
                cwd: FileManager.default.currentDirectoryPath, interactive: stdoutIsTTY, live: liveCodexConversations())
            return preflight ? prepareCodexLaunch(next, home: home, interactive: stdoutIsTTY) : next
        }
        // One reading of the working directory for both halves of the question, rather than two: the
        // chdir a worktree launch performs has already happened by here (above), and a decision made
        // about one directory must not be filtered by the sessions running in another.
        let here = FileManager.default.currentDirectoryPath
        let (next, note, cleared) = applyStartMode(args, policy: policy, wantsNew: wantsNew,
                                                   home: home, live: liveConversations(in: here),
                                                   cwd: here)
        clearedConversation = cleared
        if let note { warn(note) }
        return next
    }

    // What the accounts are scored FOR, off the args the launch runs with (Snapshot.swift), each
    // owner's reserve (AccountReserve.swift), and the accounts another session just saw cap (the
    // snapshot lags the real cap: Quarantine.swift). Then the one decision (LaunchDecision.swift):
    // an exported home, `--account`, the pin, or the headroom pick, refused under a reserve unless
    // `--spend-reserve`, and supervised or not.
    let primaryModel = launchPrimaryModel(passthrough, providerID: provider.id) ?? policy.model
    let reserves = accountReserves()
    let pinnedBy = project.accountID != nil ? "pinned for this project" : "pinned in Tally"
    let decision = resolveLaunch(provider, intent: intent, readings: LaunchReadings(
        snapshot: snapshot, policy: policy, pinnedBy: pinnedBy, primaryModel: primaryModel,
        reserves: reserves, quarantined: quarantinedAccounts(forPrimary: primaryModel),
        clearance: true, now: Date()))

    // An inherited environment's home and marker go before any exec: the bare fallbacks hand the
    // child `env: nil`, THIS process's environment, and Claude Code reads the marker as "you are a
    // child session" and stops saving the transcript.
    decision.envToUnset.forEach { unsetenv($0) }
    decision.notices.forEach { warn($0) }
    if let refusal = launchRefusalText(decision, pinnedBy: pinnedBy) {
        warn(refusal); exit(1)
    }
    guard var account = decision.account, let home = account.launchHome else { exit(1) }
    var args: [String]
    if decision.route == .pick {
        // The start mode is settled before the clearance lane may take the launch (`settleLaunch`).
        guard case let (landed, settled)? = settleLaunch(providerID: provider.id, pick: {
            $0 ? decision.clearanceAccount : decision.account
        }, startArgs: { startModeArgs(passthrough, home: $0, preflight: false) }, finish: {
            provider.id == "codex" ? prepareCodexLaunch($0, home: $1, interactive: stdoutIsTTY) : $0 })
        else { exit(1) }
        (account, args) = (landed, settled)
        if let dip = reserveDipNotice(account, primaryModel: primaryModel, reserves: reserves) {
            warn(dip)
        }
        warn("→ \(account.label) (\(pickReason(account, primaryModel: primaryModel)))")
    } else {
        args = startModeArgs(passthrough, home: home)
    }
    executeLaunch(provider, decision: decision, account: account, args: args,
                  clearedConversation: clearedConversation)
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
                                      reserves: accountReserveIDs(snapshot, reserves),
                                      flagship: accountFlagshipModels(snapshot),
                                      live: advisorLiveAccounts(snapshot))
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
        // A private build's read-only rows (OverlayStatus.swift) join HERE and nowhere else:
        // send, clear and every other reader of `sessionReadings()` keep seeing this Mac only.
        print(encodeStatusReport(statusReport(snapshot, policies: policies, advisor: advisor,
                                              quarantined: quarantined,
                                              accountSessions: live.accountSessions,
                                              sessions: live.sessions + OverlayStatus.extraSessions(now: Date()),
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
    // One instant for every row, so two windows on one line cannot straddle a reset.
    let reportedAt = Date()
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
            state += resetStatusSuffix(account) + sharedLoginSuffix(account, in: accounts)
            print("\(marker) \(account.label): " +
                  "session \(account.statusFigure(account.sessionRemaining, resetsAt: account.sessionResetsAt, now: reportedAt)) · " +
                  "weekly \(account.statusFigure(account.weeklyRemaining, resetsAt: account.weeklyResetsAt, now: reportedAt)) · " +
                  "model \(account.statusFigure(account.modelRemaining, resetsAt: account.modelResetsAt, now: reportedAt))\(state)")
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
                var text = (pool.plan.map { "\($0.lowercased()) " } ?? "")
                    + "\(poolLabel(pool.poolName)) "
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
        print("advisor: \(reading.provider) \(advisorHeadline(reading, in: snapshot))")
    }
    // AND WHETHER THE MACHINE UNDER ALL OF IT IS STILL STANDING UP, which no other line here can
    // say: every figure above is about a subscription, and the 2026-09-05 incident was a laptop
    // with no memory left running sessions whose quota was fine (HostHealthLogic.swift). Fail-open
    // on the advisor's terms - a Tally that is not running has published no report, and a report
    // this build cannot read is the same answer, so the section is simply absent.
    if let host = hostHealthStatusLine(loadHostHealthReport()) { print(host) }
    // …and the way out of this report into everything else the binary does (`tallyStatusHelpHint`).
    // Human output only: the JSON shape returned above, and a line of prose in it would be a parse
    // error for every script reading the contract.
    print(tallyStatusHelpHint)
}

// MARK: - Entry

wireClearanceSessionCounter()
let arguments = Array(CommandLine.arguments.dropFirst())
if let word = arguments.first, let code = runHookSubcommand(word, Array(arguments.dropFirst())) {
    exit(code)
}
switch arguments.first {
case "claude": runLaunch(providers[0], args: Array(arguments.dropFirst()))
case "codex": runLaunch(providers[1], args: Array(arguments.dropFirst()))
case "start": runStart(args: Array(arguments.dropFirst()))
case "resume":
    runResume(args: Array(arguments.dropFirst()))
case "worktree":
    runWorktree(args: Array(arguments.dropFirst()))
case "project":
    runProject(args: Array(arguments.dropFirst()))
case "prespawn":
    exit(runPreSpawn(args: Array(arguments.dropFirst())))
case "status", nil:
    runStatus(json: arguments.contains("--json"))
case "best-dir":
    runBestDir(arguments.dropFirst().first ?? "claude")
case "launch-dir":
    runLaunchDir(arguments.dropFirst().first ?? "codex",
                 arguments: Array(arguments.dropFirst(2)))
case "statusline":
    runStatusline(args: Array(arguments.dropFirst()))
case "reload":
    let reloadArgs = Array(arguments.dropFirst())
    exit(reloadArgs.contains("--self") ? runReloadSelf(args: reloadArgs)
                                       : runReload(args: reloadArgs))
// `account` is the name this is called by now, matching the slash command (`/tally-account`) and
// the axis it sets, the way `model` does. `switch` still answers: it is in muscle memory, in the
// skill files installed by older app versions, and in whatever anyone wrote down.
case "account", "switch":
    exit(runSwitch(args: Array(arguments.dropFirst())))
case "model":
    exit(runModel(args: Array(arguments.dropFirst())))
// The acts a supervised session can be asked to perform on ITSELF (SessionInputCommand.swift says
// why a namespace); `type` is its top-level spelling, `send` the name that shipped first.
case "session":
    exit(runSession(args: Array(arguments.dropFirst())))
case "type", "send":
    exit(runSend(args: Array(arguments.dropFirst())))
case "message": exit(runMessage(args: Array(arguments.dropFirst())))
// One Claude in Chrome step on the account the extension is signed in to, for a session that
// stays on its own (ChromeRun.swift).
case "chrome":
    exit(runChrome(args: Array(arguments.dropFirst())))
case "harness":
    exit(runHarness(args: Array(arguments.dropFirst())))
case "inbox":
    exit(runInbox(args: Array(arguments.dropFirst())))
case "events":
    exit(runEvents(args: Array(arguments.dropFirst())))
case "codex-session-status":
    runCodexSessionInstall(Array(arguments.dropFirst()))
case "codex-session-hook":
    runCodexSessionHook()
case "codex-hook": // internal: native harness adapter
    exit(runCodexHook(args: Array(arguments.dropFirst())))
case mcpServeCommand:   // internal: the MCP server behind the native pickers (MCPServe.swift)
    exit(runMCPServe())
case resuperviseCommand:   // internal: a supervisor replacing itself after an app update
    runResupervise(args: Array(arguments.dropFirst()))
case "completion":
    exit(runCompletion(args: Array(arguments.dropFirst())))
case "codex-update": exit(runCodexUpdate(args: Array(arguments.dropFirst())))   // internal: CodexUpdateCommand.swift
case "update": runUpdate()
case "cost": exit(runCost(args: Array(arguments.dropFirst())))
case "reap": exit(runReap(args: Array(arguments.dropFirst())))
case "redeem": exit(runRedeem(args: Array(arguments.dropFirst())))
case "add": runAdd(args: Array(arguments.dropFirst()))
// Commands a private build adds (OverlayCLI.swift); the public build has none.
case let command? where OverlayCLI.handles(command):
    exit(OverlayCLI.run(command, args: Array(arguments.dropFirst())))
// What `add` does for an account it creates, done to one that is already here (ShareCommand.swift).
case "share": exit(runShare(args: Array(arguments.dropFirst()), liveCounts: { liveSessionCounts() }))
// The one act of repair this binary performs on somebody else's data, and it is repair of damage
// this binary did (KeychainPartitionRepair.swift). Run by hand, by every launch, and once by the app
// at startup; the exit code is what the last of those would read if it read anything.
case "keychain-repair": exit(runKeychainRepair())
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
