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
    let exportedExit = lines.firstIndex { $0.contains("if pinned == nil,") }
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
}
