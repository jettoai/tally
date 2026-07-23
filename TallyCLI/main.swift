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
    let wantsHandoff = autoHandoffEnabled(args: passthrough)
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
    let wantsNew = passthrough.contains("--new")
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
        if policy.startMode == "continue", !wantsNew,
           !passthrough.contains(where: { ["--continue", "-c", "--resume", "-r", "--print", "-p"].contains($0) }) {
            passthrough.append("--continue")
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
        exec(provider.cli, args: passthrough, env: launchEnv(provider, home: match.launchHome!))
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
            // Still supervised: a Tally pin can be MOVED from the panel mid-session (live pin
            // switch), so the supervisor stays resident; it won't cap-handoff while pinned.
            // A CLI --account pin remains a plain exec - that flag opts out of supervision.
            if provider.id == "claude", wantsHandoff {
                runSupervised(provider, account: match, args: passthrough, follow: allowFollow)
            }
            exec(provider.cli, args: passthrough, env: launchEnv(provider, home: match.launchHome!))
        }
        if let home = policy.pinnedHome {
            warn("→ pinned account (set in Tally)")
            exec(provider.cli, args: passthrough, env: launchEnv(provider, home: home))
        }
        warn("pinned account not found - picking by headroom instead")
    }

    guard let snapshot else {
        warn("no eligible \(provider.id) account - launching bare `\(provider.cli)`")
        exec(provider.cli, args: passthrough, env: nil)
    }
    // Skip an account another session just saw cap: the snapshot lags the real cap, so its
    // percentage still reads healthy and picking it would drop a fresh session onto the wall that
    // just failed. If quarantine leaves nothing eligible, ignore it rather than refuse to launch.
    let quarantined = quarantinedAccounts()
    guard let account = best(providerID: provider.id, in: snapshot, primaryModel: policy.model,
                             excluding: quarantined)
            ?? best(providerID: provider.id, in: snapshot, primaryModel: policy.model) else {
        warn("no eligible \(provider.id) account - launching bare `\(provider.cli)`")
        exec(provider.cli, args: passthrough, env: nil)
    }
    warn("→ \(account.label) (\(pickReason(account, primaryModel: policy.model)))")
    // Claude sessions get the resident supervisor (auto-handoff on a cap hit); an explicit
    // `--account` pin or `--no-handoff` opts out, and codex stays a plain exec for now.
    if provider.id == "claude", wantsHandoff {
        runSupervised(provider, account: account, args: passthrough, follow: allowFollow)
    }
    exec(provider.cli, args: passthrough, env: launchEnv(provider, home: account.launchHome!))
}

func runStatus(json: Bool = false) {
    let (snapshot, problem) = loadSnapshot()
    if let problem { warn(problem) }
    guard let snapshot else { exit(1) }
    if json {
        let policies = Dictionary(uniqueKeysWithValues: providers.map { ($0.id, launchPolicy($0.id)) })
        print(encodeStatusReport(statusReport(snapshot, policies: policies)))
        return
    }
    for provider in providers {
        let accounts = snapshot.accounts.filter { $0.provider == provider.id }
        guard !accounts.isEmpty else { continue }
        let policy = launchPolicy(provider.id)
        let bestID = best(providerID: provider.id, in: snapshot, primaryModel: policy.model)?.id
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
    // The status line reads this to show "this session runs under Tally" (✦).
    print("export TALLY_LAUNCHED=1")
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
    // The status line reads this to show "this session runs under Tally" (✦).
    print("export TALLY_LAUNCHED=1")
}

// MARK: - Entry

/// `tally add claude|codex`: create the next numbered config home and hand this terminal to the
/// official login flow. A numbered home that exists but never finished logging in is resumed
/// rather than skipped, so an aborted login doesn't burn a number. The default home counts too:
/// on a machine with no account at all, `tally add` is simply the first login.
///
/// Sharing is the DEFAULT (opt out with --no-share): before the login, the main account's
/// harness is symlinked into the new home (see `harnessItems(for:)`) - one set of
/// instructions/skills/hooks/agents/settings maintained once, and one conversation record,
/// so cross-account resume and handoff continue the same history. Multi-account in Tally
/// means one person's accounts working as one fleet; separate setups are the special case,
/// not the default. The launch report says out loud when conversations are shared.
func runAdd(args: [String]) -> Never {
    let share = !args.contains("--no-share")
    let providerID = args.first { !$0.hasPrefix("--") } ?? ""
    guard let provider = providers.first(where: { $0.id == providerID }) else {
        warn("usage: tally add <claude|codex> [--no-share]")
        exit(2)
    }
    let fm = FileManager.default
    let home = fm.homeDirectoryForCurrentUser
    let base = provider.id == "claude" ? ".claude" : ".codex"
    let authFile = provider.id == "claude" ? ".credentials.json" : "auth.json"
    var chosen: (dir: URL, name: String)?
    for n in 1 ... 99 {
        let name = n == 1 ? base : "\(base)\(n)"
        let dir = home.appendingPathComponent(name)
        if !fm.fileExists(atPath: dir.appendingPathComponent(authFile).path) {
            chosen = (dir, name)
            break
        }
    }
    guard let (dir, name) = chosen else {
        warn("no free slot: ~/\(base) through ~/\(base)99 all have logins")
        exit(1)
    }
    // codex refuses a CODEX_HOME that doesn't exist; creating it is harmless for claude.
    try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    let mainHome = home.appendingPathComponent(base)
    if !share, dir.path != mainHome.path {
        // Opting out must UNDO what an earlier (aborted, default-shared) run linked into
        // this reused directory - otherwise --no-share leaves the conversations shared.
        let removed = unlinkSharedHarness(from: mainHome, to: dir,
                                          items: harnessItems(for: provider.id, in: mainHome))
        if !removed.isEmpty {
            warn("share opted out - removed earlier share links: \(removed.joined(separator: ", "))")
        }
    }
    if share {
        if dir.path == mainHome.path {
            warn("share skipped: ~/\(base) IS the main account (nothing to link yet)")
        } else {
            let (linked, kept, failed) = linkSharedHarness(from: mainHome, to: dir,
                                                           items: harnessItems(for: provider.id, in: mainHome))
            if !linked.isEmpty {
                warn("sharing the main account's harness: \(linked.joined(separator: ", "))")
            }
            if !kept.isEmpty {
                warn("left as-is (already present): \(kept.joined(separator: ", "))")
            }
            if !failed.isEmpty {
                warn("could not link: \(failed.joined(separator: ", ")) - check permissions; the share is incomplete")
            }
            // The privacy note follows the ACTUAL state, not this run's work: shared is
            // shared whether it happened now, on an earlier run, or by hand.
            if sharesConversations(providerID: provider.id, source: mainHome, target: dir) {
                warn("note: \(conversationEntry(provider.id))/ is shared - every account can read every account's conversations (next time: --no-share)")
            }
        }
    }
    warn("adding a \(provider.id) account at ~/\(name) - finish the login below; the account shows up in Tally within a minute")
    exec(provider.cli, args: provider.id == "codex" ? ["login"] : [],
         env: launchEnv(provider, home: dir.path))
}

/// `tally update`: ask the menu bar app to run a user-initiated Sparkle check (its window
/// follows the pointer's screen), launching the app first when it isn't running. Uses pgrep +
/// a distributed notification so the statusline hot path never has to link AppKit.
func runUpdate() {
    func run(_ path: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
        return p.terminationStatus
    }
    if run("/usr/bin/pgrep", ["-xq", "Tally"]) != 0 {
        _ = run("/usr/bin/open", ["-b", "ai.jetto.tally"])
        Thread.sleep(forTimeInterval: 2)   // let the updater finish starting before we knock
    }
    DistributedNotificationCenter.default().postNotificationName(
        Notification.Name("ai.jetto.tally.checkForUpdates"),
        object: nil, userInfo: nil, deliverImmediately: true)
    print("[tally] update check requested; Tally's update window will appear in a moment.")
}

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case "claude":
    runLaunch(providers[0], args: Array(arguments.dropFirst()))
case "codex":
    runLaunch(providers[1], args: Array(arguments.dropFirst()))
case "resume":
    runResume(args: Array(arguments.dropFirst()))
case "status", nil:
    runStatus(json: arguments.contains("--json"))
case "best-dir":
    runBestDir(arguments.dropFirst().first ?? "claude")
case "launch-dir":
    runLaunchDir(arguments.dropFirst().first ?? "codex")
case "statusline":
    runStatusline(args: Array(arguments.dropFirst()))
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
      tally codex [args…]       launch Codex on the best account
      tally resume [args…]      continue this directory's latest Claude session on the best account
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
      tally update              check for app updates now (opens the update window)
    """)
    exit(2)
}
