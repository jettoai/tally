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
    // Asserted by ORDER, because order is what decides those axes, and against the exit's own body:
    // this harness cannot call `runLaunch` (it execs), the same reason the pick checks read source.
    // The anchor is the half of the condition the broken and the fixed shape SHARE, so a test going
    // red here says "the exit moved back above the injection" rather than "somebody renamed a
    // local" - a needle that only the fixed shape contains would report the defect and a rename
    // identically, and would go green on the broken tree by simply finding nothing.
    let lines = launcher.components(separatedBy: "\n")
    // Both halves are shared by the broken and the fixed shape. The BINDING is part of the anchor
    // because `pinned == nil` is not unique in this function: an anchor that matched another test of
    // it sliced a different block, one that still satisfied the guard below by containing a `getenv`
    // of its own - the needle missing its target and reporting nothing (found while writing the
    // leak checks at the foot of this file, 2026-08-13).
    let exportedExit = lines.firstIndex {
        $0.contains("if pinned == nil,") && $0.contains("let exported = getenv(provider.envKey)")
    }
    let defaultsInjection = lines.firstIndex {
        $0.contains("passthrough = applyLaunchDefaults(passthrough,")
    }
    /// The exit's body: its `if` line down to the brace closing it at function indent.
    let exportedBlock: String = {
        guard let start = exportedExit else { return "" }
        let end = lines[(start + 1)...].firstIndex { $0 == "    }" } ?? lines.endIndex
        return lines[start ... min(end, lines.endIndex - 1)].joined(separator: "\n")
    }()

    check("the harness really found the exported-home exit",
          !exportedBlock.isEmpty && exportedBlock.contains("getenv(provider.envKey)"))
    check("…and the injection it has to stand after", defaultsInjection != nil)
    // THE FIX. Above the injection, the exit exec'd args no default had been applied to yet.
    check("the exit stands after the launch defaults are injected, so it carries them",
          (exportedExit ?? 0) > (defaultsInjection ?? Int.max))
    check("…and never execs the raw passthrough, which is how the defaults were being dropped",
          !exportedBlock.contains("args: passthrough,"))
    // Against the home that was EXPORTED: `--continue` is resolved by claude against the config
    // home it runs under, so asking the account we would otherwise have picked would predict a
    // conversation this launch cannot reach.
    check("…resolving the start mode against the home that was exported",
          exportedBlock.contains("startModeArgs(passthrough, home: String(cString: exported))"))
    check("…and leaving the environment alone, so the child inherits the home the user exported",
          exportedBlock.contains("env: nil"))
    // Deliberately unsupervised: the supervisor exists to move a session to ANOTHER account on a
    // cap hit, and a home pinned by hand leaves it nowhere to move to.
    check("…as a plain exec, with no supervisor in front of it",
          !exportedBlock.contains("runSupervised"))
    // `--account` names an account; this variable names a config directory. The flag still wins.
    check("a --account pin still outranks an exported home",
          exportedBlock.contains("pinned == nil")
              && (exportedExit ?? Int.max)
                  < (lines.firstIndex { $0.contains("if let pinned {") } ?? 0))

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

    /// The launcher's own call to that predicate, and the name it binds the answer to - read off the
    /// source rather than written down here, so a rename carries these checks with it instead of
    /// turning them green by finding nothing.
    let leakCall = lines.firstIndex { $0.contains("= inheritedSessionEnvironment(") }
    let leakBinding = leakCall.map {
        lines[$0].components(separatedBy: "= inheritedSessionEnvironment(")[0]
            .replacingOccurrences(of: "let ", with: "").trimmingCharacters(in: .whitespaces)
    }
    check("the launcher asks whether its environment was inherited at all", leakBinding != nil)
    check("…handing it the terminal signal the supervision decision reads",
          leakCall.map { lines[$0 ... min($0 + 1, lines.count - 1)].joined() }?
              .contains("stdoutIsTTY: stdoutIsTTY") == true)
    check("…which this launch answers once, so its two readers cannot disagree",
          launcher.components(separatedBy: "isatty(").count == 2)
    // THE FIX, in the exit's own condition (the half it SHARES with the broken shape is asserted
    // above): a leak stands the exit down, and the launch carries on to the pick below - and to the
    // supervisor, which the exit's own plain exec has to do without.
    check("the exported-home exit stands down for an inherited environment",
          leakBinding.map { exportedBlock.contains("!\($0)") } == true)

    /// The branch that acts on a leak, sliced by the same rule as the exit's body.
    let leakBlock: String = {
        guard let binding = leakBinding,
              let start = lines.firstIndex(where: { $0.contains("if \(binding) {") })
        else { return "" }
        let end = lines[(start + 1)...].firstIndex { $0 == "    }" } ?? lines.endIndex
        return lines[start ... min(end, lines.endIndex - 1)].joined(separator: "\n")
    }()
    check("the harness really found that branch", !leakBlock.isEmpty)
    check("a leaked marker is cleared, so the session it starts saves its transcript again",
          leakBlock.contains("unsetenv(childSessionMarker)"))
    check("…only there, so a real child keeps the marker it was given",
          launcher.components(separatedBy: "unsetenv(childSessionMarker)").count == 2)
    check("…and before every exec below, which is how the child inherits it cleared",
          (lines.firstIndex { $0.contains("unsetenv(childSessionMarker)") } ?? Int.max)
              < (lines.firstIndex { $0.contains("exec(provider.cli") } ?? 0))
}
