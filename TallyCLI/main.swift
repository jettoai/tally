import Darwin
import Foundation

// `tally` - launch a provider CLI on the account with the most proven headroom.
//
//   tally claude [args…]       launch `claude` on the best Claude account (args pass through);
//                              stays resident and auto-hands-off on a cap hit (see Supervisor.swift)
//   tally codex  [args…]       exec `codex` on the best Codex account
//   tally resume [args…]       continue this directory's latest Claude session on the best account
//   tally status               print every account's remaining windows
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

    // An explicitly exported config home is also the user choosing by hand - honour it.
    if pinned == nil, getenv(provider.envKey) != nil {
        warn("\(provider.envKey) already set - launching bare `\(provider.cli)` with it")
        exec(provider.cli, args: passthrough, env: nil)
    }
    let (snapshot, problem) = loadSnapshot()
    if let problem { warn(problem) }

    // The app's permission-mode setting (Settings → Claude permissions), injected only when the
    // user typed no permission flag of their own - explicit flags always win.
    let policy = launchPolicy(provider.id)
    if provider.id == "claude", let mode = policy.permissionMode,
       !passthrough.contains("--dangerously-skip-permissions"),
       !passthrough.contains("--permission-mode") {
        switch mode {
        case "plan": passthrough += ["--permission-mode", "plan"]
        case "acceptEdits": passthrough += ["--permission-mode", "acceptEdits"]
        case "bypass": passthrough += ["--dangerously-skip-permissions"]
        default: break
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
                runSupervised(provider, account: match, args: passthrough)
            }
            exec(provider.cli, args: passthrough, env: launchEnv(provider, home: match.launchHome!))
        }
        if let home = policy.pinnedHome {
            warn("→ pinned account (set in Tally)")
            exec(provider.cli, args: passthrough, env: launchEnv(provider, home: home))
        }
        warn("pinned account not found - picking by headroom instead")
    }

    guard let snapshot, let account = best(providerID: provider.id, in: snapshot) else {
        warn("no eligible \(provider.id) account - launching bare `\(provider.cli)`")
        exec(provider.cli, args: passthrough, env: nil)
    }
    warn("→ \(account.label) (headroom \(Int(headroom(account).rounded()))%)")
    // Claude sessions get the resident supervisor (auto-handoff on a cap hit); an explicit
    // `--account` pin or `--no-handoff` opts out, and codex stays a plain exec for now.
    if provider.id == "claude", wantsHandoff {
        runSupervised(provider, account: account, args: passthrough)
    }
    exec(provider.cli, args: passthrough, env: launchEnv(provider, home: account.launchHome!))
}

func runStatus() {
    let (snapshot, problem) = loadSnapshot()
    if let problem { warn(problem) }
    guard let snapshot else { exit(1) }
    for provider in providers {
        let accounts = snapshot.accounts.filter { $0.provider == provider.id }
        guard !accounts.isEmpty else { continue }
        let policy = launchPolicy(provider.id)
        let bestID = best(providerID: provider.id, in: snapshot)?.id
        for account in accounts {
            let pinned = policy.mode == "manual" && account.id == policy.pinnedAccountID
            let marker = pinned || (policy.mode != "manual" && account.id == bestID) ? "→" : " "
            var state = account.error.map { " !\($0)" } ?? (account.isStale ? " (stale)" : "")
            if pinned { state += " (pinned)" }
            print("\(marker) \(account.label): session \(fmt(account.sessionRemaining)) · " +
                  "weekly \(fmt(account.weeklyRemaining)) · model \(fmt(account.modelRemaining))\(state)")
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
    let target = snapshot.accounts
        .filter { $0.provider == provider.id && eligible($0) && $0.id != newest.account.id }
        .max { headroom($0) < headroom($1) } ?? newest.account
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
         "(headroom \(Int(headroom(target).rounded()))%)")
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
case "status", nil:
    runStatus()
case "best-dir":
    runBestDir(arguments.dropFirst().first ?? "claude")
case "launch-dir":
    runLaunchDir(arguments.dropFirst().first ?? "codex")
default:
    warn("""
    usage:
      tally claude [args…]      launch Claude Code on the best account (auto-handoff on cap hit;
                                opt out with --no-handoff or TALLY_AUTO_HANDOFF=0)
      tally claude --account <n>  pin a specific account (label or config-dir name)
      tally codex [args…]       launch Codex on the best account
      tally resume [args…]      continue this directory's latest Claude session on the best account
      tally status              show every account's remaining windows
      tally best-dir <provider> print the export line for the best account
      tally launch-dir <provider> shim interface: like best-dir but honours the app's
                                launch policy (off → prints nothing)
    """)
    exit(2)
}
