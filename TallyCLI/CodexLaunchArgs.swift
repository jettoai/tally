import Foundation

// codex's launch vocabulary, read the way codex's own parser reads it. The provider-neutral half of
// the injection (the policy, `optionsOnly`, `injectingOptions`) stays in Snapshot.swift; what lives
// here is everything that is true of a VERSION of somebody else's CLI, which is a table rather than
// a rule and grows every time that CLI does.
//
// EVERY TABLE BELOW WAS MEASURED, not read off the help text. codex-cli 0.153.4, 2026-09-07, by
// putting the spelling through the real parser and reading the exit status: `codex <spelling>
// --version` and `codex <subcommand> <flag> --help` answer 0 when the parser took it and 2 with
// "unexpected argument" when it did not, with an unknown flag and an invalid value as controls
// (both 2, so a 0 is the parse really succeeding rather than `--version` short-circuiting it).
//
// The help text is not the parser, and here that is not a theoretical distinction. Three of the
// subcommand names below (`execpolicy`, `responses-api-proxy`, `stdio-to-uds`) appear in no `codex
// --help` output at all, and neither does `--yolo`, which is the bypass flag under a second name.
// Those came from `codex completion bash`, whose word list is generated from the parser itself.

/// The options whose VALUE is the next word. Used to walk an argument vector looking for its first
/// POSITIONAL: without this, `-m gpt-5.6-sol` reads as a flag followed by codex's prompt.
///
/// Only the SEPARATED spelling is here. clap takes three spellings of one option (`-s v`,
/// `--sandbox=v`, `-sv`) and the other two carry their value inside the token, so nothing follows
/// them to skip.
let codexValueTakingOptions: Set<String> = [
    "-c", "--config", "--enable", "--disable", "--remote", "--remote-auth-token-env",
    "-i", "--image", "-m", "--model", "--local-provider", "-p", "--profile",
    "-s", "--sandbox", "-C", "--cd", "--add-dir", "-a", "--ask-for-approval",
]

/// Every word codex matches as a SUBCOMMAND rather than as the start of a prompt, its aliases
/// included (`e` for exec, `a` for apply). Anything not in here is the prompt, and a launch whose
/// arguments are a prompt is the interactive session all of codex's own session flags describe.
let codexSubcommands: Set<String> = [
    "agents", "exec", "e", "review", "login", "logout", "mcp", "plugin", "mcp-server",
    "app-server", "remote-control", "app", "completion", "update", "doctor", "sandbox", "debug",
    "execpolicy", "apply", "a", "resume", "queue", "archive", "delete", "migrate-rollouts",
    "unarchive", "fork", "cloud", "responses-api-proxy", "stdio-to-uds", "exec-server",
    "features", "help",
]

/// The subcommands whose own parser still takes the session flags: `-s`, `-m`, and the bypass flag.
/// One set for the three because the three were measured to have exactly the same acceptance - 8 of
/// the names above take them (aliases counted) and the other 25 answer `error: unexpected argument`
/// and exit 2, `codex review`, `codex login`, `codex mcp` and `codex doctor` among them.
///
/// Measured with the flag AFTER the subcommand's own arguments as well, which is where these land
/// (`codex exec 'hello world' -s read-only`, `codex resume abc123 -s read-only`): a table built
/// only from flags in front of a positional would not describe the vector Tally actually produces.
let codexSubcommandsTakingSessionFlags: Set<String> = [
    "exec", "e", "resume", "queue", "archive", "delete", "unarchive", "fork",
]

/// …and the narrower set that also takes `-a`, which is the half of `acceptEdits` that cannot be
/// dropped. `codex exec` is the one that surprises: it has `-s` and the bypass flag but no
/// `--ask-for-approval` at all, so acceptEdits is the mode that breaks the launch automation uses.
let codexSubcommandsTakingApproval: Set<String> = ["resume", "fork"]

/// The second name for `--dangerously-bypass-approvals-and-sandbox`, absent from `codex --help` and
/// bound to the same argument. Injecting behind it does not merely double a flag: clap refuses the
/// argument twice and the launch exits 2.
let codexBypassSpellings: Set<String> = ["--dangerously-bypass-approvals-and-sandbox", "--yolo"]

/// The first word of `typed` that is neither an option nor an option's value: codex's subcommand
/// when the launch names one, the first word of the prompt when it does not, nil when the launch is
/// all flags.
///
/// `typed` is the OPTIONS half of a vector (`optionsOnly`), because past a bare `--` the same word
/// is something the user wrote rather than something they asked for.
func codexFirstPositional(_ typed: [String]) -> String? {
    var index = 0
    while index < typed.count {
        let token = typed[index]
        // A lone "-" is codex's "read the prompt from stdin", which is a positional and not a flag.
        guard token.hasPrefix("-"), token != "-" else { return token }
        if codexValueTakingOptions.contains(token) { index += 1 }
        index += 1
    }
    return nil
}

/// The subcommand this launch runs, or nil when it runs the interactive session.
func codexSubcommand(_ typed: [String]) -> String? {
    guard let first = codexFirstPositional(typed), codexSubcommands.contains(first) else {
        return nil
    }
    return first
}

/// Whether this launch has already SAID what it may do, in any spelling codex's parser accepts.
///
/// One question for both axes, because half a mode injected behind a typed one is nobody's choice,
/// and because getting it wrong costs something different in each mode. Under a configured bypass
/// the injected flag WINS SILENTLY: measured off `codex exec`'s own startup banner, `--sandbox=
/// read-only` plus the bypass flag comes up `sandbox: danger-full-access`, with no error and no
/// sign on screen that the confinement the user typed was dropped. Under plan or acceptEdits the
/// same miss is a launch that does not start at all: a second `--sandbox` is `error: the argument
/// '--sandbox <SANDBOX_MODE>' cannot be used multiple times`.
///
/// Three spellings of each flag, all measured against 0.153.4: separated (`-s read-only`), joined
/// (`--sandbox=read-only`, `-s=read-only`) and attached (`-sread-only`). The config override says
/// the same thing again in its own three (`-c sandbox_mode=read-only`,
/// `--config=sandbox_mode=read-only`, `-csandbox_mode=read-only`), and is a `-c` like any other
/// until its value is read.
///
/// `--profile` is in here for a reason one step removed: a profile is a config file, and a config
/// file can set `sandbox_mode` or `approval_policy`. Measured the same way as the rest - a profile
/// declaring read-only comes up `danger-full-access` once the bypass flag is injected behind it -
/// so naming one is a permission choice, even though the choice is not in the argument vector.
func codexTypedPermission(_ typed: [String]) -> Bool {
    let permissionKeys = ["sandbox_mode=", "approval_policy="]
    func overridesPermission(_ value: String) -> Bool {
        // `-c=key=value` is the attached spelling with clap's optional `=` in front of it.
        let bare = value.hasPrefix("=") ? String(value.dropFirst()) : value
        return permissionKeys.contains { bare.hasPrefix($0) }
    }
    for (index, token) in typed.enumerated() {
        if token == "--approve-for-me" || codexBypassSpellings.contains(token) { return true }
        if ["-s", "--sandbox", "-a", "--ask-for-approval", "-p", "--profile"].contains(token) {
            return true
        }
        if token.hasPrefix("--sandbox=") || token.hasPrefix("--ask-for-approval=")
            || token.hasPrefix("--profile=") { return true }
        // The attached spellings. Guarded on the single dash so `--add-dir` cannot read as an `-a`
        // carrying "dd-dir", and case-sensitively so `-C` (the working root) is not `-c`.
        if !token.hasPrefix("--"), token.count > 2 {
            if token.hasPrefix("-s") || token.hasPrefix("-a") || token.hasPrefix("-p") {
                return true
            }
            if token.hasPrefix("-c"), overridesPermission(String(token.dropFirst(2))) { return true }
        }
        if token == "-c" || token == "--config", index + 1 < typed.count,
           overridesPermission(typed[index + 1]) { return true }
        if token.hasPrefix("--config="),
           overridesPermission(String(token.dropFirst("--config=".count))) { return true }
    }
    return false
}

/// codex's half of `applyLaunchDefaults`: the permission mode, the model and the effort, said in
/// codex's own vocabulary (codex-cli 0.153.4).
///
///   plan        -> `-s read-only`: it may read the workspace and change nothing.
///   acceptEdits -> `-s workspace-write -a never`: edits inside the workspace go through unasked,
///                  one outside it fails back to the model rather than stopping on a dialog. BOTH
///                  halves are the mode - the sandbox alone still asks.
///   bypass      -> `--dangerously-bypass-approvals-and-sandbox` (claude's
///                  `--dangerously-skip-permissions`), which drops both at once.
///
/// AND ONLY WHERE THE PARSER TAKES THEM. These are the interactive session's flags; 25 of the 33
/// names codex matches as a subcommand exit 2 rather than ignore one, so a launch that had one
/// appended did not start. The factory default is bypass for a provider nobody has configured
/// (`launchPolicy`), which is why this was not a corner: with the shim installed, a new user's
/// first `codex login` was a command that refused to run.
///
/// The gate is per axis, not per launch, because the acceptance differs by flag: `-a` is taken by
/// only two of them, so `acceptEdits` stands down where `plan` and `bypass` still apply, and the
/// effort rides a `-c`, which every subcommand takes (it is clap's global option) and which
/// therefore has no gate at all.
func applyCodexLaunchDefaults(_ args: [String], policy: LaunchPolicy) -> [String] {
    var next = args
    let typed = optionsOnly(args)
    let subcommand = codexSubcommand(typed)
    let takesSessionFlags = subcommand.map(codexSubcommandsTakingSessionFlags.contains) ?? true
    let takesApproval = subcommand.map(codexSubcommandsTakingApproval.contains) ?? true
    if let mode = policy.permissionMode, !codexTypedPermission(typed) {
        switch mode {
        case "plan" where takesSessionFlags:
            next = injectingOptions(next, ["-s", "read-only"])
        case "acceptEdits" where takesSessionFlags && takesApproval:
            next = injectingOptions(next, ["-s", "workspace-write", "-a", "never"])
        case "bypass" where takesSessionFlags:
            next = injectingOptions(next, ["--dangerously-bypass-approvals-and-sandbox"])
        default: break
        }
    }
    if let model = policy.model, takesSessionFlags,
       !typed.contains("-m"), !typed.contains("--model") {
        next = injectingOptions(next, ["-m", model])
    }
    if let effort = policy.effort,
       !typed.contains(where: { $0.contains("model_reasoning_effort") }) {
        next = injectingOptions(next, ["-c", "model_reasoning_effort=\"\(effort)\""])
    }
    return next
}
