import Foundation

// An exported CLAUDE_CONFIG_DIR chooses the ACCOUNT, not the whole launch.
//
// The defect (owner-reported 2026-08-13): the exit for an already-exported config home sat ABOVE
// the policy read in `runLaunch`, so it skipped not the account pick but EVERYTHING - the
// permission mode, the model, the fallback model, the effort and the start mode. Every session
// launched from inside another one exports that variable, so Settings read bypass on fable/high
// while the session came up in manual mode on the CLI's own default. None of the axes it dropped
// is a statement about which account runs, which is the only question the variable answers.
//
// Runs as a function main.swift calls, which owns the shared harness (`check`, `after`,
// `appDefaults`) and hands the launcher's source over.

func runExportedHomeChecks(launcher: String) {
    // Asserted by ORDER, because order is what decides those axes. Since #424 the launcher reads its
    // inputs, asks `resolveLaunch` (LaunchDecision.swift) and only carries the answer out, so the
    // source half below pins that shape and the behaviour half (further down) asks the decision.
    /// The same source with every run of whitespace collapsed to one space, so a call the formatter
    /// wrapped across two lines is still ONE string to search.
    let folded = launcher.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" })
        .joined(separator: " ")
    func at(_ needle: String) -> String.Index? { folded.range(of: needle)?.lowerBound }
    let defaultsInjection = at("passthrough = applyLaunchDefaults(passthrough,")
    let decideAt = at("let decision = resolveLaunch(provider, intent: intent,")
    let unset = at("decision.envToUnset.forEach { unsetenv($0) }")
    let firstStart = at("startModeArgs(passthrough, home:")
    let launch = at("executeLaunch(provider, decision: decision,")
    check("the harness really found the decision", decideAt != nil)
    check("…and the injection it has to stand after", defaultsInjection != nil)
    // THE FIX of 2026-08-13, in its new shape: every route's start args are built from the args the
    // defaults were injected into, because the decision is taken after the injection.
    check("the decision is taken after the launch defaults are injected, so every route carries them",
          defaultsInjection.map { d in decideAt.map { d < $0 } ?? false } ?? false)
    check("…and no route execs the raw passthrough, which is how the defaults were being dropped",
          !folded.contains("launchProvider(") && folded.contains("account: account, args: args,"))
    // Against the home the decision landed on (for an exported home, the one that was exported):
    // `--continue` is resolved by claude against the config home it runs under.
    check("…resolving the start mode against the home the decision landed on",
          folded.contains("guard var account = decision.account, let home = account.launchHome")
              && folded.contains("args = startModeArgs(passthrough, home: home)"))
    check("…and the one launch call names the account it resolved the start mode for",
          folded.contains("executeLaunch(provider, decision: decision, account: account, args: args,"))
    let executor = (try? String(contentsOfFile: "TallyCLI/CodexSupervisor.swift", encoding: .utf8))
        .map { $0.components(separatedBy: "func executeLaunch(").dropFirst().first ?? "" }
        .map { $0.components(separatedBy: "\n}\n").first ?? "" } ?? ""
    check("…which leaves the environment alone for an inherited-home route, so the child keeps the "
          + "home the user exported", executor.contains("env: decision.childEnv == .inherit ? nil :"))
    check("…and runs the handoff supervisor only when the decision says so",
          executor.contains("case .handoff:") && executor.contains("runSupervised(")
              && !launcher.contains("runSupervised"))
    // Nothing in this function reaches the CLI any other way. The wrapper is where the seeding
    // happens, so a branch that called `exec` directly would launch a session whose home was never
    // brought up to date - silently, and only on that one branch.
    check("no branch of the launcher execs the CLI behind the wrapper's back",
          !launcher.contains("exec(provider.cli") && !executor.contains("exec(provider.cli"))
    check("the environment is read in one place, the intent, never again by the launcher",
          !launcher.contains("getenv("))

    // The axes that exit was dropping, exercised directly rather than by source. Nothing here is
    // claude-specific plumbing: `applyLaunchDefaults` is one function, so codex rides the same fix.
    let bypassArgs = applyLaunchDefaults([], policy: appDefaults, providerID: "claude")
    check("a bypass permission mode is injected as the flag claude actually reads",
          bypassArgs.contains("--dangerously-skip-permissions"))
    check("…alongside the model, the fallback model and the effort of the same launch",
          after("--model", in: bypassArgs) == "fable"
              && after("--fallback-model", in: bypassArgs) == "opus"
              && after("--effort", in: bypassArgs) == "high")
    check("a typed --permission-mode still outranks the configured bypass",
          !applyLaunchDefaults(["--permission-mode", "plan"], policy: appDefaults,
                               providerID: "claude").contains("--dangerously-skip-permissions"))
    check("…and a typed --dangerously-skip-permissions is not doubled",
          applyLaunchDefaults(["--dangerously-skip-permissions"], policy: appDefaults,
                              providerID: "claude")
              .filter { $0 == "--dangerously-skip-permissions" }.count == 1)
    let codexArgs = applyLaunchDefaults([], policy: appDefaults, providerID: "codex")
    check("codex's effort rides the same injection, in the spelling its own CLI takes",
          after("-c", in: codexArgs) == "model_reasoning_effort=\"high\"")
    check("…as does its model", after("-m", in: codexArgs) == "fable")

    // The permission mode is ONE setting across providers, and for a while it was one setting that
    // only one provider obeyed: Settings and the panel both read "bypass" for codex (it is the
    // factory default for every provider) while the launcher injected nothing at all, so the
    // session came up asking for approval on its first command. Every row below is the same mode in
    // codex's own vocabulary, asserted as the flags codex actually reads.
    check("a bypass permission mode reaches codex as the flag that drops both of its gates",
          codexArgs.contains("--dangerously-bypass-approvals-and-sandbox"))
    var planPolicy = appDefaults
    planPolicy.permissionMode = "plan"
    check("plan is codex's read-only sandbox",
          after("-s", in: applyLaunchDefaults([], policy: planPolicy, providerID: "codex"))
              == "read-only")
    var acceptPolicy = appDefaults
    acceptPolicy.permissionMode = "acceptEdits"
    let acceptArgs = applyLaunchDefaults([], policy: acceptPolicy, providerID: "codex")
    // BOTH halves, because the sandbox alone still stops to ask: workspace-write on its own is the
    // approval dialog this mode exists to remove, and `never` on its own is a dialog-free launch
    // that can still be asked to write anywhere. The approval half is a config override rather than
    // `-a never` so that it survives the subcommands `--ask-for-approval` does not exist on
    // (CodexLaunchArgs.swift), which is also why it is read as the FIRST `-c` here: the effort
    // rides the same option and is injected behind it.
    check("…and accept edits is a writable workspace that never stops to ask",
          after("-s", in: acceptArgs) == "workspace-write"
              && after("-c", in: acceptArgs) == "approval_policy=\"never\"")
    check("a typed sandbox still outranks the configured bypass",
          !applyLaunchDefaults(["-s", "read-only"], policy: appDefaults, providerID: "codex")
              .contains("--dangerously-bypass-approvals-and-sandbox"))
    // The same choice said through the config-override spelling, which is the one a `-s` scan
    // cannot see: `-c approval_policy="never"` is a `-c` like any other until its VALUE is read.
    check("…as does the same choice typed as a config override",
          !applyLaunchDefaults(["-c", "approval_policy=\"never\""], policy: appDefaults,
                               providerID: "codex")
              .contains("--dangerously-bypass-approvals-and-sandbox"))
    check("…and a typed bypass flag is not doubled",
          applyLaunchDefaults(["--dangerously-bypass-approvals-and-sandbox"], policy: appDefaults,
                              providerID: "codex")
              .filter { $0 == "--dangerously-bypass-approvals-and-sandbox" }.count == 1)

    // MARK: - An environment INHERITED from a session is not a hand pin

    // The second half of the same evening's defect: the exit above believes an exported home is the
    // user choosing an account, and a terminal STARTED from inside a session inherits that session's
    // whole environment, so every window opened afterwards arrives carrying one account's home - the
    // machine silently stuck on one account, and every new session's transcript unsaved on top of
    // it. Three shapes reach this decision and are each asserted directly below: a hand export, a
    // leak, and a real child session. The fourth, a supervisor relaunching its own child, never
    // arrives here at all - it assembles the child's environment from the account it chose
    // (SupervisorRuntime.swift), so there is no exported home for it to read.
    check("the marker this reads is the one Claude Code actually sets",
          childSessionMarker == "CLAUDE_CODE_CHILD_SESSION")
    let leaked = ["CLAUDE_CONFIG_DIR": "/Users/u/.claude2", childSessionMarker: "1"]
    // Row 2, the leak: a child marker in a launch somebody TYPED contradicts itself, because real
    // children are spawned through a pipe.
    check("a child marker in a launch typed at a terminal is a leak, not a child session",
          inheritedSessionEnvironment(providerID: "claude", stdoutIsTTY: true,
                                      environment: leaked))
    // Row 1: nothing contradicts the export, so it stands - the hand pin the exit above exists for.
    check("an exported home with no marker behind it is still the user's own choice",
          !inheritedSessionEnvironment(providerID: "claude", stdoutIsTTY: true,
                                       environment: ["CLAUDE_CONFIG_DIR": "/Users/u/.claude2"]))
    // Row 3, the one this may not break: a REAL child, spawned by a session's own shell and routed
    // here by the PATH shim. Following its parent's home is what stops one conversation picking a
    // second account halfway through.
    check("the same marker with stdout on a pipe is a real child, which keeps its parent's home",
          !inheritedSessionEnvironment(providerID: "claude", stdoutIsTTY: false,
                                       environment: leaked))
    check("codex reads nothing into a marker that was never about it",
          !inheritedSessionEnvironment(providerID: "codex", stdoutIsTTY: true,
                                       environment: ["CODEX_HOME": "/Users/u/.codex2",
                                                     childSessionMarker: "1"]))
    // The default argument, which is what the launcher calls: the answer comes from THIS process's
    // environment, and clearing the marker is therefore what makes a launch stop reading as
    // inherited - the mechanism the launcher's `unsetenv` relies on for every exec it makes.
    setenv(childSessionMarker, "1", 1)
    check("…and it reads the live environment, which is where a leak lands",
          inheritedSessionEnvironment(providerID: "claude", stdoutIsTTY: true))
    unsetenv(childSessionMarker)
    check("…so clearing the marker is what stops a launch reading as inherited",
          !inheritedSessionEnvironment(providerID: "claude", stdoutIsTTY: true))

    // The launcher's half, read off its source: the terminal is read once and handed to the intent,
    // and the cleanup happens before any start mode is settled or any child launched.
    check("the launcher asks the intent, handing it the terminal signal the supervision reads",
          folded.contains("launchIntent(provider, args: passthrough, accountFlag: pinned, stdoutIsTTY: stdoutIsTTY)"))
    check("…which this launch answers once, so its readers cannot disagree",
          launcher.components(separatedBy: "isatty(").count == 2)
    check("the leak cleanup runs before any start mode is settled",
          unset.map { u in firstStart.map { u < $0 } ?? false } ?? false
              && (decideAt.map { d in unset.map { d < $0 } ?? false } ?? false))
    check("…and before the launch itself, `env: nil` routes included",
          unset.map { u in launch.map { u < $0 } ?? false } ?? false)
    check("…and nowhere else, so a home somebody exported by hand is never unset behind them",
          !launcher.contains("unsetenv(provider.envKey)") && !launcher.contains("unsetenv(childSessionMarker)"))

    // MARK: - The decision itself (LaunchDecision.swift), asked directly

    let now = Date()
    let home1 = "/tmp/eh-claude-work1", homeR = "/tmp/eh-claude-R"
    func row(_ name: String, _ home: String, weekly: Double) -> Snapshot.Account {
        Snapshot.Account(id: "claude:\(name)", provider: "claude", label: name, launchHome: home,
                         sessionRemaining: 90, weeklyRemaining: weekly, modelRemaining: nil,
                         sessionResetsAt: now.addingTimeInterval(4 * 3600),
                         weeklyResetsAt: now.addingTimeInterval(100 * 3600), modelResetsAt: nil,
                         modelWindowName: nil, resetCreditsAvailable: nil, isStale: false,
                         error: nil, lastRefreshFailed: false)
    }
    let fleet = Snapshot(version: 2, generatedAt: now,
                         accounts: [row("work1", home1, weekly: 90), row("R", homeR, weekly: 50)])
    let held = AccountReserves(settings: [homeR: AccountRoleSetting(role: AccountRoles.personal,
                                                                     reserve: 60)])
    func decide(_ provider: Provider = providers[0], env: [String: String], tty: Bool = true,
                account: String? = nil, args: [String] = [],
                snapshot: Snapshot? = fleet) -> LaunchDecision {
        resolveLaunch(provider, intent: launchIntent(provider, args: args, accountFlag: account,
                                                     stdoutIsTTY: tty, environment: env),
                      readings: LaunchReadings(snapshot: snapshot, policy: LaunchPolicy(),
                                               pinnedBy: "pinned in Tally", primaryModel: nil,
                                               reserves: held, quarantined: [], clearance: true,
                                               now: now))
    }
    let exportedOne = decide(env: ["CLAUDE_CONFIG_DIR": home1])
    check("an exported home is the route, launched in that very home",
          exportedOne.route == .exportedHome && exportedOne.account?.launchHome == home1)
    check("…leaving the environment alone, so the child inherits the home the user exported",
          exportedOne.childEnv == .inherit)
    check("…as a plain exec, with no supervisor in front of it",
          exportedOne.supervision == .none(.handPinned))
    check("…and says so before it launches",
          exportedOne.notices == ["CLAUDE_CONFIG_DIR already set - keeping that account, launch "
                                  + "defaults still apply"])
    check("a --account pin still outranks an exported home",
          decide(env: ["CLAUDE_CONFIG_DIR": homeR], account: "work1").route == .accountFlag)
    // B-1213: the home names an account as surely as `--account`, so its reserve refuses it, before
    // the exec - except for a real child (its marker still set here) and under `--spend-reserve`.
    let refused = decide(env: ["CLAUDE_CONFIG_DIR": homeR])
    check("an exported home under its owner's line is refused before the launch",
          refused.route == .exportedHome && refused.account == nil
              && { if case .named? = refused.refusal { return true }; return false }())
    check("…unless --spend-reserve",
          decide(env: ["CLAUDE_CONFIG_DIR": homeR], args: [spendReserveFlag]).refusal == nil)
    let child = decide(env: ["CLAUDE_CONFIG_DIR": homeR, childSessionMarker: "1"], tty: false)
    check("…and never for a real child following its parent's home",
          child.route == .exportedHome && child.refusal == nil && child.envToUnset.isEmpty)
    check("a home the snapshot has no row for has no reading and launches as exported",
          decide(env: ["CLAUDE_CONFIG_DIR": "/tmp/eh-elsewhere"]).account?.launchHome
              == "/tmp/eh-elsewhere")
    let leak = decide(env: ["CLAUDE_CONFIG_DIR": homeR, childSessionMarker: "1"])
    check("the exported-home exit stands down for an inherited environment, and the launch picks",
          leak.route == .pick && leak.supervision == .handoff)
    check("a leaked config home is dropped from the environment too, not just the marker that "
          + "gave it away", leak.envToUnset == ["CLAUDE_CONFIG_DIR", childSessionMarker])
    check("…and the leak is said first, since it carried a home",
          leak.notices.first?.hasPrefix("CLAUDE_CONFIG_DIR was inherited from another session") == true)
    let markerOnly = decide(env: [childSessionMarker: "1"])
    check("a marker with no home still clears, and has nothing to report",
          markerOnly.envToUnset == ["CLAUDE_CONFIG_DIR", childSessionMarker]
              && !markerOnly.notices.contains { $0.contains("was inherited") })
    check("a home somebody exported by hand is never unset behind them",
          exportedOne.envToUnset.isEmpty)
    let bareLaunch = decide(env: [:], snapshot: nil)
    check("the bare fallback resolves against the default home and inherits this environment",
          bareLaunch.route == .bare && bareLaunch.childEnv == .inherit
              && bareLaunch.account?.launchHome == defaultHome(providers[0]))
    check("codex reads nothing into the marker: an exported CODEX_HOME stays the route",
          decide(providers[1], env: ["CODEX_HOME": "/tmp/eh-codex", childSessionMarker: "1"]).route
              == .exportedHome)
}
