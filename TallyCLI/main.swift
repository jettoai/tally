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

    guard let snapshot,
          let account = best(providerID: provider.id, in: snapshot, primaryModel: policy.model) else {
        warn("no eligible \(provider.id) account - launching bare `\(provider.cli)`")
        exec(provider.cli, args: passthrough, env: nil)
    }
    warn("→ \(account.label) (\(pickReason(account, primaryModel: policy.model)))")
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
        .filter { $0.provider == provider.id && eligible($0) && $0.id != newest.account.id }
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

/// `tally statusline claude` - Claude Code's statusLine hook (registered by the app's
/// Integrations pane): reads the session JSON claude pipes on stdin, prints "account · model".
/// The account is whichever home this claude was launched with (the hook inherits its env),
/// labeled with the user's nickname from the snapshot. Fail-open at every step: a status line
/// must render SOMETHING, never error.
func runStatusline(args: [String]) -> Never {
    let home = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude").path
    let (snapshot, problem) = loadSnapshot()
    let label = snapshot?.accounts.first { $0.launchHome == home }?.label
        ?? URL(fileURLWithPath: home).lastPathComponent
    // The working-state signal answers the user's actual unknown - "is this Claude session
    // under Tally's control?" - so it names Tally outright (the user already knows they are
    // in Claude; the env marker rides in from exec/supervisor/shim). A stale/missing snapshot
    // adds the off note: launched by Tally or not, steering data is dead.
    let steered = ProcessInfo.processInfo.environment["TALLY_LAUNCHED"] == "1"
    // Colors: the sparkle wears the same electric purple as the app's Smart badge (one brand
    // vocabulary for "Tally is steering"); the account stays dim (payload, not signal) and
    // the off note goes warning-yellow. Claude Code renders ANSI in status lines.
    let purple = "\u{1B}[38;5;135m", dim = "\u{1B}[2m", yellow = "\u{1B}[33m", reset = "\u{1B}[0m"
    let statusPiece: String? = steered
        ? (problem == nil
            ? "\(purple)✦ Tally\(reset)"
            : "\(purple)✦ Tally\(reset) \(yellow)(off)\(reset)")
        : (problem != nil ? "\(yellow)(tally off)\(reset)" : nil)
    // The account name only carries information when there is a choice: with one account it
    // reads as noise next to a Claude session, so the status signal stands alone.
    let siblings = snapshot?.accounts.filter { $0.provider == "claude" }.count ?? 0
    let identity = [statusPiece, siblings > 1 ? "\(dim)\(label)\(reset)" : nil]
        .compactMap { $0 }.joined(separator: " · ")
    let input = FileHandle.standardInput.readDataToEndOfFile()

    // The quota pieces: per-window remaining as a mini meter bar + percent (tinted by room
    // left) + reset countdown. Built once, used by the standalone line and the full-quota
    // wrapped line alike; empty when the snapshot is stale or the account is unknown.
    var quota: [String] = []
    if problem == nil, let account = snapshot?.accounts.first(where: { $0.launchHome == home }) {
        let now = Date()
        func piece(_ name: String, _ remaining: Double?, _ resetsAt: Date?) -> String? {
            guard let remaining else { return nil }
            // Same thresholds AND the same palette as the app's meters (TallyColor sage green /
            // amber / softened red, 256-colour approximations) - one brand vocabulary from the
            // panel to the terminal.
            let tint = remaining < 20 ? "\u{1B}[38;5;167m"
                : remaining < 50 ? "\u{1B}[38;5;214m" : "\u{1B}[38;5;71m"
            let cells = 6
            let filled = min(cells, max(remaining > 0 ? 1 : 0,
                                        Int((remaining / 100 * Double(cells)).rounded())))
            let bar = tint + String(repeating: "█", count: filled) + reset
                + dim + String(repeating: "░", count: cells - filled) + reset
            var text = "\(dim)\(name)\(reset) \(bar) \(tint)\(Int(remaining.rounded()))%\(reset)"
            if let resetsAt, resetsAt > now {
                text += " \(dim)(\(shortETA(resetsAt.timeIntervalSince(now))))\(reset)"
            }
            return text
        }
        quota = [piece("5h", account.sessionRemaining, account.sessionResetsAt),
                 piece("7d", account.weeklyRemaining, account.weeklyResetsAt),
                 piece(account.modelWindowName ?? "model", account.modelRemaining, nil)]
            .compactMap { $0 }
    }

    // Wrapped mode: the user's own status line (carried as base64 - see IntegrationsStore)
    // keeps the lead position, fed the same JSON; the account is appended. Augmentation,
    // never replacement.
    if let wrapIndex = args.firstIndex(of: "--wrap"), wrapIndex + 1 < args.count,
       let original = Data(base64Encoded: args[wrapIndex + 1])
           .flatMap({ String(data: $0, encoding: .utf8) }) {
        var body = ""
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", original]
        let stdinPipe = Pipe(), stdoutPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.nullDevice
        if (try? process.run()) != nil {
            stdinPipe.fileHandleForWriting.write(input)
            try? stdinPipe.fileHandleForWriting.close()
            let out = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            // The WHOLE output passes through - multi-line status lines keep every line and
            // their layout (only line 1 survived at first, which would wreck them).
            body = String(data: out, encoding: .utf8)?
                .trimmingCharacters(in: .newlines) ?? ""
        }
        // No double identity: a status line that already names the account anywhere (by
        // nickname or by config-dir name) keeps its account rendering, gaining only the
        // working-state signals; otherwise the whole identity joins the LAST line, where a
        // width-padded first line can't be pushed out of shape.
        // Full-quota mode (opt-in via the app): the whole quota line joins on its OWN line
        // beneath the custom status line - for people who drop their own quota rendering and
        // rely on Tally's. The line is ours, so the account always shows here.
        if snapshot?.statuslineFullQuota == true, !quota.isEmpty {
            let richLine = ([statusPiece, "\(dim)\(label)\(reset)"].compactMap { $0 } + quota)
                .joined(separator: " · ")
            print(body.isEmpty ? richLine : "\(body)\n\(richLine)")
            exit(0)
        }
        let homeName = URL(fileURLWithPath: home).lastPathComponent
        let alreadyShown = body.localizedCaseInsensitiveContains(label)
            || body.localizedCaseInsensitiveContains(homeName)
        let addition = alreadyShown ? (statusPiece ?? "") : identity
        // A run of spaces in the last line means the script width-manages it (right-aligned
        // time/diff); appending inline would push that content off the edge (live incident
        // 2026-07-19: the git diff truncated to "+413 -1…"). The addition takes its own line
        // there; plain last lines keep the compact inline join.
        let widthManaged = body.split(separator: "\n").last?.contains("   ") ?? false
        print(addition.isEmpty ? body
              : body.isEmpty ? addition
              : widthManaged ? "\(body)\n\(addition)" : "\(body) · \(addition)")
        exit(0)
    }

    // Standalone mode: Tally IS the whole status line, so it always carries the quota story
    // itself (plus the model name from the session JSON, which no other line is showing).
    let json = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any]
    let model = (json?["model"] as? [String: Any])?["display_name"] as? String
    print(([identity.isEmpty ? nil : identity, model].compactMap { $0 } + quota)
        .joined(separator: " · "))
    exit(0)
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
case "statusline":
    runStatusline(args: Array(arguments.dropFirst()))
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
