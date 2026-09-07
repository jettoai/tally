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

// THERE IS NO SECOND TABLE FOR THE APPROVAL POLICY, and the reason is worth writing down.
// `--ask-for-approval` is taken by only two of those names, so saying `acceptEdits` with `-a never`
// would have left the one mode that needs BOTH halves standing down for `codex exec` - the launch
// this repo's own automation runs. Standing down is not neutral: it hands the question back to
// codex's own configuration, and a configuration set to danger-full-access is WIDER than the
// workspace-write the Settings row says it applied. So that half is said as a config override
// instead, which every subcommand takes because `-c` is clap's global option.

/// The KEY of a `-c key=value` override, in the spellings TOML allows for it. codex splits the
/// argument on its first `=` and parses the rest as TOML, so the space around the `=` is TOML's to
/// ignore: `-c 'sandbox_mode = "read-only"'` is the same override as `-c sandbox_mode="read-only"`,
/// and it really lands - `codex doctor` reports `approval policy Never` for the spaced spelling of
/// the approval key against a baseline of `OnRequest`.
///
/// A wrapping pair of quotes is stripped from the key as well, even though 0.153.4 does NOT honour
/// one: `-c '"approval_policy"="never"'` parses, changes nothing, and leaves doctor reporting
/// `OnRequest`. Reading it as an override anyway is the safe direction - the launch stands down and
/// codex's own configuration decides, rather than Tally appending a bypass behind something the
/// user plainly meant as a restriction - and it is already right for a codex that starts honouring
/// it.
func codexConfigKey(_ override: String) -> String? {
    // `-c=key=value` is the attached spelling with clap's optional `=` in front of it.
    let bare = override.hasPrefix("=") ? String(override.dropFirst()) : override
    guard let split = bare.firstIndex(of: "=") else { return nil }
    var key = bare[..<split].trimmingCharacters(in: .whitespaces)
    if key.count > 1, let quote = key.first, quote == "\"" || quote == "'",
       key.hasSuffix(String(quote)) {
        key = String(key.dropFirst().dropLast())
    }
    return key.isEmpty ? nil : key
}

/// Whether the launch typed a `-c`/`--config` override for one of `keys`, in any of the three
/// spellings clap takes for the option itself: separated (`-c key=v`), joined (`--config=key=v`)
/// and attached (`-ckey=v`, `-c=key=v`).
func codexTypedConfigOverride(_ typed: [String], keys: Set<String>) -> Bool {
    for (index, token) in typed.enumerated() {
        var override: String?
        if token == "-c" || token == "--config" {
            override = index + 1 < typed.count ? typed[index + 1] : nil
        } else if token.hasPrefix("--config=") {
            override = String(token.dropFirst("--config=".count))
        } else if !token.hasPrefix("--"), token.hasPrefix("-c"), token.count > 2 {
            override = String(token.dropFirst(2))
        }
        guard let override, let key = codexConfigKey(override) else { continue }
        if keys.contains(key) { return true }
    }
    return false
}

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
    if codexTypedConfigOverride(typed, keys: ["sandbox_mode", "approval_policy"]) { return true }
    for token in typed {
        if token == "--approve-for-me" || codexBypassSpellings.contains(token) { return true }
        if ["-s", "--sandbox", "-a", "--ask-for-approval", "-p", "--profile"].contains(token) {
            return true
        }
        if token.hasPrefix("--sandbox=") || token.hasPrefix("--ask-for-approval=")
            || token.hasPrefix("--profile=") { return true }
        // The attached spellings. Guarded on the single dash so `--add-dir` cannot read as an `-a`
        // carrying "dd-dir", and case-sensitively so `-C` (the working root) is not `-c`.
        if !token.hasPrefix("--"), token.count > 2,
           token.hasPrefix("-s") || token.hasPrefix("-a") || token.hasPrefix("-p") {
            return true
        }
    }
    return false
}

/// codex's half of `applyLaunchDefaults`: the permission mode, the model and the effort, said in
/// codex's own vocabulary (codex-cli 0.153.4).
///
///   plan        -> `-s read-only`: it may read the workspace and change nothing.
///   acceptEdits -> `-s workspace-write -c approval_policy="never"`: edits inside the workspace go
///                  through unasked, one outside it fails back to the model rather than stopping on
///                  a dialog. BOTH halves are the mode - the sandbox alone still asks - and the
///                  approval half is said as a config override rather than as `-a never` so that it
///                  reaches every launch the sandbox flag reaches (see the note above the key
///                  reader). Measured: `codex doctor -c 'approval_policy="never"'` reports
///                  `approval policy Never` where the baseline reports `OnRequest`.
///   bypass      -> `--dangerously-bypass-approvals-and-sandbox` (claude's
///                  `--dangerously-skip-permissions`), which drops both at once.
///
/// AND ONLY WHERE THE PARSER TAKES THEM. These are the interactive session's flags; 25 of the 33
/// names codex matches as a subcommand exit 2 rather than ignore one, so a launch that had one
/// appended did not start. The factory default is bypass for a provider nobody has configured
/// (`launchPolicy`), which is why this was not a corner: with the shim installed, a new user's
/// first `codex login` was a command that refused to run.
///
/// The gate is per axis, not per launch: the sandbox flag and `-m` are the session's own and stop
/// at the table above, while the effort rides a `-c`, which every subcommand takes and which
/// therefore has no gate at all.
func applyCodexLaunchDefaults(_ args: [String], policy: LaunchPolicy) -> [String] {
    var next = args
    let typed = optionsOnly(args)
    let takesSessionFlags = codexSubcommand(typed)
        .map(codexSubcommandsTakingSessionFlags.contains) ?? true
    if let mode = policy.permissionMode, !codexTypedPermission(typed), takesSessionFlags {
        switch mode {
        case "plan": next = injectingOptions(next, ["-s", "read-only"])
        case "acceptEdits":
            next = injectingOptions(next, ["-s", "workspace-write",
                                           "-c", "approval_policy=\"never\""])
        case "bypass":
            next = injectingOptions(next, ["--dangerously-bypass-approvals-and-sandbox"])
        default: break
        }
    }
    if let model = policy.model, takesSessionFlags,
       !typed.contains("-m"), !typed.contains("--model"),
       !codexTypedConfigOverride(typed, keys: ["model"]) {
        next = injectingOptions(next, ["-m", model])
    }
    if let effort = policy.effort,
       !codexTypedConfigOverride(typed, keys: ["model_reasoning_effort"]) {
        next = injectingOptions(next, ["-c", "model_reasoning_effort=\"\(effort)\""])
    }
    return next
}
