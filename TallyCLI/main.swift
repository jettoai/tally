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
    passthrough.removeAll { $0 == "--no-handoff" }   // tally's own flag, never passed through
    // A running session follows a later Settings change to the default model/effort UNLESS the
    // user opted out (--no-follow) or typed their own --model or --effort (a deliberate choice
    // outranks the default, and the follow adopts the pair as a whole - it must never overwrite
    // a hand-typed flag). Captured before the policy injects its own flags below.
    let allowFollow = autoFollowEnabled(args: passthrough) && !passthrough.contains("--model")
        && !passthrough.contains("--effort")
    passthrough.removeAll { $0 == "--no-follow" }    // tally's own flag, never passed through

    // An explicitly exported config home is also the user choosing by hand - honour it.
    if pinned == nil, getenv(provider.envKey) != nil {
        warn("\(provider.envKey) already set - launching bare `\(provider.cli)` with it")
        exec(provider.cli, args: passthrough, env: nil)
    }
    let (snapshot, problem) = loadSnapshot()
    if let problem { warn(problem) }

    // Launch defaults from the app (Settings), injected only when the user typed no flag of
    // their own on the same axis - explicit flags always win. `--new` is tally's own flag: it
    // suppresses a "continue by default" setting for this one launch and is never passed through.
    let policy = launchPolicy(provider.id)
    let wantsNew = passthrough.contains("--new") || worktreeFresh
    passthrough.removeAll { $0 == "--new" }
    if provider.id == "claude" {
        if let mode = policy.permissionMode,
           !passthrough.contains("--dangerously-skip-permissions"),
           !passthrough.contains("--permission-mode") {
            switch mode {
            case "plan": passthrough += ["--permission-mode", "plan"]
            case "acceptEdits": passthrough += ["--permission-mode", "acceptEdits"]
            case "bypass": passthrough += ["--dangerously-skip-permissions"]
            default: break
            }
        }
        if let model = policy.model, !passthrough.contains("--model") {
            passthrough += ["--model", model]
        }
        if let fallback = policy.fallbackModel, !passthrough.contains("--fallback-model") {
            passthrough += ["--fallback-model", fallback]
        }
        if let effort = policy.effort, !passthrough.contains("--effort") {
            passthrough += ["--effort", effort]
        }
    }
    if provider.id == "codex" {
        if let model = policy.model,
           !passthrough.contains("-m"), !passthrough.contains("--model") {
            passthrough += ["-m", model]
        }
        if let effort = policy.effort,
           !passthrough.contains(where: { $0.contains("model_reasoning_effort") }) {
            passthrough += ["-c", "model_reasoning_effort=\"\(effort)\""]
        }
    }

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
        let query = pinned.lowercased()
        let match = snapshot?.accounts.first { account in
            account.provider == provider.id && account.launchHome != nil &&
                (account.label.lowercased().contains(query) ||
                 URL(fileURLWithPath: account.launchHome!).lastPathComponent.lowercased().contains(query))
        }
        guard let match else {
            warn("no \(provider.id) account matches \"\(pinned)\" - try `tally status`")
            exit(1)
        }
        warn("→ \(match.label) (pinned)")
        exec(provider.cli, args: startModeArgs(passthrough, home: match.launchHome!),
             env: launchEnv(provider, home: match.launchHome!))
    }

    // The app's launch policy (Settings → Launch account). A `--account` flag above outranks it.
    // "off" still auto-picks HERE: invoking `tally claude` is itself an explicit ask to pick -
    // off only means Tally must not steer launches it wasn't asked into (the PATH shim).
    if policy.mode == "manual" {
        if let match = snapshot?.accounts.first(where: {
            $0.id == policy.pinnedAccountID && $0.launchHome != nil
        }) {
            if headroom(match) <= 0 {
                warn("\(match.label) is out of quota - launching anyway (pinned in Tally)")
            }
            warn("→ \(match.label) (pinned in Tally)")
            let args = startModeArgs(passthrough, home: match.launchHome!)
            // Still supervised: a Tally pin can be MOVED from the panel mid-session (live pin
            // switch), so the supervisor stays resident; it won't cap-handoff while pinned.
            // A CLI --account pin remains a plain exec - that flag opts out of supervision.
            if provider.id == "claude", wantsHandoff {
                runSupervised(provider, account: match, args: args, follow: allowFollow)
            }
            exec(provider.cli, args: args, env: launchEnv(provider, home: match.launchHome!))
        }
        if let home = policy.pinnedHome {
            warn("→ pinned account (set in Tally)")
            exec(provider.cli, args: startModeArgs(passthrough, home: home),
                 env: launchEnv(provider, home: home))
        }
        warn("pinned account not found - picking by headroom instead")
    }

    guard let snapshot else {
        warn("no eligible \(provider.id) account - launching bare `\(provider.cli)`")
        exec(provider.cli, args: startModeArgs(passthrough, home: defaultHome(provider)), env: nil)
    }
    // Skip an account another session just saw cap: the snapshot lags the real cap, so its
    // percentage still reads healthy and picking it would drop a fresh session onto the wall that
    // just failed. `launchPick` also carries the "quarantine left nothing, launch anyway" fallback,
    // and is what `tally status` and the app's badge predict this launch with.
    let quarantined = quarantinedAccounts(forPrimary: policy.model)
    guard let account = launchPick(providerID: provider.id, in: snapshot,
                                   primaryModel: policy.model, quarantined: quarantined) else {
        warn("no eligible \(provider.id) account - launching bare `\(provider.cli)`")
        exec(provider.cli, args: startModeArgs(passthrough, home: defaultHome(provider)), env: nil)
    }
    warn("→ \(account.label) (\(pickReason(account, primaryModel: policy.model)))")
    let args = startModeArgs(passthrough, home: account.launchHome!)
    // Claude sessions get the resident supervisor (auto-handoff on a cap hit); an explicit
    // `--account` pin or `--no-handoff` opts out, and codex stays a plain exec for now.
    if provider.id == "claude", wantsHandoff {
        runSupervised(provider, account: account, args: args, follow: allowFollow)
    }
    exec(provider.cli, args: args, env: launchEnv(provider, home: account.launchHome!))
}

func runStatus(json: Bool = false) {
    let (snapshot, problem) = loadSnapshot()
    if let problem { warn(problem) }
    guard let snapshot else { exit(1) }
    let advisor = loadAdvisorReadings()
    // The arrow marks the account a launch WOULD land on, so it has to skip what the launcher
    // skips: a quarantined account (see Quarantine.swift). Read once for both output shapes.
    let policies = Dictionary(uniqueKeysWithValues: providers.map { ($0.id, launchPolicy($0.id)) })
    let quarantined = policies.mapValues { quarantinedAccounts(forPrimary: $0.model) }
    if json {
        print(encodeStatusReport(statusReport(snapshot, policies: policies, advisor: advisor,
                                              quarantined: quarantined)))
        return
    }
    for provider in providers {
        let accounts = snapshot.accounts.filter { $0.provider == provider.id }
        guard !accounts.isEmpty else { continue }
        let policy = policies[provider.id] ?? LaunchPolicy()
        let bestID = launchPick(providerID: provider.id, in: snapshot, primaryModel: policy.model,
                                quarantined: quarantined[provider.id] ?? [])?.id
        for account in accounts {
            let pinned = policy.mode == "manual" && account.id == policy.pinnedAccountID
            let marker = pinned || (policy.mode != "manual" && account.id == bestID) ? "→" : " "
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
                let label = pool.poolName.map { "\($0.lowercased()) pool" } ?? "pool"
                var text = "\(label) " + String(format: "%.1f/%d", pool.remaining / 100,
                                                Int((pool.capacity / 100).rounded()))
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

    // Prefer the best OTHER eligible account; fall back to the source account (a plain resume).
    let primaryModel = launchPolicy(provider.id).model
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
    exec(provider.cli, args: ["--resume", sessionID] + args, env: launchEnv(provider, home: target.launchHome!))
}

func runBestDir(_ providerID: String) {
    guard let provider = providers.first(where: { $0.id == providerID }) else {
        warn("unknown provider `\(providerID)` - use claude or codex")
        exit(2)
    }
    let (snapshot, problem) = loadSnapshot()
    if let problem { warn(problem) }
    // A Tally-set manual pin is the answer regardless of headroom - the user chose by hand.
    let policy = launchPolicy(provider.id)
    let pinnedHome: String? = policy.mode == "manual"
        ? snapshot?.accounts.first { $0.id == policy.pinnedAccountID }?.launchHome ?? policy.pinnedHome
        : nil
    let home = pinnedHome ?? snapshot.flatMap { best(providerID: provider.id, in: $0)?.launchHome }
    guard let home else {
        warn("no eligible \(providerID) account")
        exit(1)
    }
    // Mirror launchEnv: the default home must UNSET the variable (explicitly setting the default
    // path makes Claude Code look up a hashed Keychain item that doesn't exist). Both lines eval.
    if launchEnv(provider, home: home) == nil {
        print("unset \(provider.envKey)")
    } else {
        print("export \(provider.envKey)=\(home)")
    }
    // The status line reads this to show "this session runs under Tally" (✦). A shim-steered bare
    // launch has no resident supervisor, so mark it unsupervised (the status line stays quiet
    // rather than nagging "supervisor unknown").
    print("export TALLY_LAUNCHED=1")
    print("export TALLY_SUPERVISED=0")
}

/// `tally launch-dir` - the machine interface for the codex/claude PATH shims. Unlike `best-dir`
/// (an explicit "which is best" question), this answers "should a BARE invocation be steered, and
/// where": mode off prints nothing (the shim passes through untouched), manual prints the pin,
/// auto prints the headroom pick. Output is eval-able (`export …` / `unset …`) or empty.
func runLaunchDir(_ providerID: String) {
    guard let provider = providers.first(where: { $0.id == providerID }) else {
        warn("unknown provider `\(providerID)` - use claude or codex")
        exit(2)
    }
    let policy = launchPolicy(provider.id)
    guard policy.mode != "off" else { return }
    let (snapshot, problem) = loadSnapshot()
    if let problem { warn(problem) }
    let pinnedHome: String? = policy.mode == "manual"
        ? snapshot?.accounts.first { $0.id == policy.pinnedAccountID }?.launchHome ?? policy.pinnedHome
        : nil
    guard let home = pinnedHome ?? snapshot.flatMap({ best(providerID: provider.id, in: $0)?.launchHome })
    else { return }   // nothing eligible - stay silent, the shim runs the bare CLI
    if launchEnv(provider, home: home) == nil {
        print("unset \(provider.envKey)")
    } else {
        print("export \(provider.envKey)=\(home)")
    }
    // The status line reads this to show "this session runs under Tally" (✦). A shim-steered bare
    // launch has no resident supervisor, so mark it unsupervised (the status line stays quiet
    // rather than nagging "supervisor unknown").
    print("export TALLY_LAUNCHED=1")
    print("export TALLY_SUPERVISED=0")
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
                                worktree, its branch, and its transcripts); bare picks from a menu
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
      tally reload [--now]      restart every supervised session at its next idle moment, so edited
                                hooks, skills, and instructions take effect everywhere without
                                visiting each terminal (--now waits only for a 5s quiet gap, so it
                                may land closer to an active turn)
      tally update              check for app updates now (opens the update window)
    """)
    exit(2)
}
