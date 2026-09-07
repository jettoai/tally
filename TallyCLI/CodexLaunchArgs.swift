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

/// The KEY and VALUE of a `-c key=value` override, in the spellings TOML allows for them. codex
/// splits the argument on its first `=` and parses the rest as TOML, so the space around the `=` is
/// TOML's to ignore and the quotes around a string are the string's delimiter rather than part of
/// its contents: `-c 'sandbox_mode = "read-only"'` is the same override as
/// `-c sandbox_mode=read-only`, and it really lands - `codex doctor` reports `approval policy Never`
/// for the spaced spelling of the approval key against a baseline of `OnRequest`.
///
/// A wrapping pair of quotes is stripped from the key as well, even though 0.153.4 does NOT honour
/// one: `-c '"approval_policy"="never"'` parses, changes nothing, and leaves doctor reporting
/// `OnRequest`. Reading it as an override anyway is the safe direction - the launch stands down and
/// codex's own configuration decides, rather than Tally appending a bypass behind something the
/// user plainly meant as a restriction - and it is already right for a codex that starts honouring
/// it.
func codexConfigOverride(_ override: String) -> (key: String, value: String)? {
    // `-c=key=value` is the attached spelling with clap's optional `=` in front of it.
    let bare = override.hasPrefix("=") ? String(override.dropFirst()) : override
    guard let split = bare.firstIndex(of: "=") else { return nil }
    let key = codexTOMLScalar(String(bare[..<split]))
    guard !key.isEmpty else { return nil }
    return (key, codexTOMLScalar(String(bare[bare.index(after: split)...])))
}

/// One TOML scalar as codex reads it: the space around it is the parser's to ignore, and a wrapping
/// pair of quotes delimits a string rather than belonging to it.
func codexTOMLScalar(_ text: String) -> String {
    let trimmed = text.trimmingCharacters(in: .whitespaces)
    guard trimmed.count > 1, let quote = trimmed.first, quote == "\"" || quote == "'",
          trimmed.hasSuffix(String(quote)) else { return trimmed }
    return String(trimmed.dropFirst().dropLast())
}

/// Every `-c`/`--config` override this launch typed, in any of the three spellings clap takes for
/// the option itself: separated (`-c key=v`), joined (`--config=key=v`) and attached (`-ckey=v`,
/// `-c=key=v`).
func codexTypedConfigOverrides(_ typed: [String]) -> [(key: String, value: String)] {
    var overrides: [(key: String, value: String)] = []
    for (index, token) in typed.enumerated() {
        var override: String?
        if token == "-c" || token == "--config" {
            override = index + 1 < typed.count ? typed[index + 1] : nil
        } else if token.hasPrefix("--config=") {
            override = String(token.dropFirst("--config=".count))
        } else if !token.hasPrefix("--"), token.hasPrefix("-c"), token.count > 2 {
            override = String(token.dropFirst(2))
        }
        if let override, let pair = codexConfigOverride(override) { overrides.append(pair) }
    }
    return overrides
}

/// Whether the launch typed a `-c`/`--config` override for one of `keys`.
func codexTypedConfigOverride(_ typed: [String], keys: Set<String>) -> Bool {
    codexTypedConfigOverrides(typed).contains { keys.contains($0.key) }
}

/// What a launch itself said about codex's model axis: whether it named the axis at all, and the
/// name it gave it.
///
/// ONE reader for two questions that must not diverge, because they did. The INJECTION asks whether
/// the axis was spoken for, since a second `-m` behind a typed one is `error: the argument
/// '--model <MODEL>' cannot be used multiple times` and the launch does not start; it knew only the
/// two separated words, so `--model=x` and `-mx` had one appended behind them. The ACCOUNT PICK
/// asks which model will run, since that is what decides which accounts have the window this launch
/// needs; it read the same two words, so a launch that typed `-c model=x` was scored for the
/// configured default instead of for the model it actually runs.
struct CodexModelChoice {
    /// The axis was named, in whatever spelling and with whatever value. This is the injection's
    /// gate: a launch that named it gets nothing added, even where the name it gave is unusable.
    var named = false
    /// The model that name resolves to, nil when the launch left the option dangling (`-m` with
    /// nothing after it) or handed it another flag. Callers fall back to the configured default.
    var value: String?
}

/// The model choice in `typed`, read in every spelling codex's parser takes for it.
///
/// Measured against codex-cli 0.153.4 with `codex <spelling> --version`, an unknown flag as the
/// control (`codex --bogus --version` exits 2, so a 0 is the parse really succeeding rather than
/// `--version` short-circuiting it): separated `-m x` and `--model x`, joined `--model=x` and
/// `-m=x`, attached `-mx`, all accepted, plus the config override `-c model="x"`, which reaches the
/// same setting through clap's global option and is the only spelling the 25 subcommands that
/// refuse `-m` will take.
///
/// The flag OUTRANKS the override when a launch types both, measured off `codex exec`'s own startup
/// banner: `-m gpt-6-astra -c 'model="gpt-5.6-sol"'` comes up `model: gpt-6-astra`. Which is why
/// the override is read first and the flags after it.
func codexModelChoice(_ typed: [String]) -> CodexModelChoice {
    var choice = CodexModelChoice()
    if let override = codexTypedConfigOverrides(typed).last(where: { $0.key == "model" }) {
        choice.named = true
        choice.value = override.value.isEmpty ? nil : override.value
    }
    for (index, token) in typed.enumerated() {
        if token == "-m" || token == "--model" {
            // A value that is itself a flag is not a model. Measured 2026-08-06 on the claude half
            // of this: a dangling flag suppresses the injection (the axis was typed) and the NEXT
            // injection lands right behind it, so a plain read hands back the following flag's name
            // as the model this launch runs.
            let following = index + 1 < typed.count ? typed[index + 1] : nil
            choice.named = true
            choice.value = (following?.hasPrefix("-") ?? true) ? nil : following
        } else if token.hasPrefix("--model=") {
            choice.named = true
            let value = String(token.dropFirst("--model=".count))
            choice.value = value.isEmpty ? nil : value
        } else if !token.hasPrefix("--"), token.hasPrefix("-m"), token.count > 2 {
            // Joined (`-m=x`) and attached (`-mx`). The value is INSIDE the token here, so a dash
            // at the front of it is part of the name rather than the next option.
            choice.named = true
            var value = String(token.dropFirst(2))
            if value.hasPrefix("=") { value = String(value.dropFirst()) }
            choice.value = value.isEmpty ? nil : value
        }
    }
    return choice
}

/// The second name for `--dangerously-bypass-approvals-and-sandbox`, absent from `codex --help` and
/// bound to the same argument. Injecting behind it does not merely double a flag: clap refuses the
/// argument twice and the launch exits 2.
let codexBypassSpellings: Set<String> = ["--dangerously-bypass-approvals-and-sandbox", "--yolo"]

/// The options that STATE a permission, each in both the names codex's parser answers to. ONE row
/// per option rather than a list of short names beside a list of long ones: a fourth permission
/// option added to codex is a row here, and cannot be half-added by being remembered in one list
/// and forgotten in the other. Read by `codexTypedPermission`, which is where the spellings of a
/// single name are unpacked.
let codexPermissionOptions: [(short: String, long: String)] = [
    ("-s", "--sandbox"), ("-a", "--ask-for-approval"), ("-p", "--profile"),
]

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
        guard codexReadsAsOption(token) else { return token }
        index += 1
        if codexVariadicOptions.contains(token) {
            // Every word up to the next option is one of this option's values.
            while index < typed.count, !codexReadsAsOption(typed[index]) { index += 1 }
        } else if codexValueTakingOptions.contains(token) {
            index += 1
        }
    }
    return nil
}

/// The options whose separated spelling takes MORE THAN ONE value: every word after them is a value
/// until the next word clap reads as an option. `-i, --image <FILE>...` is the only one codex
/// 0.153.4 declares, and skipping just one of its values misread what a launch RUNS: measured,
/// `codex -i a.png doctor` starts the interactive session with two images (exit 1,
/// `Error: stdin is not a terminal`) while `codex -i a.png -s read-only doctor` prints
/// `Codex Doctor v0.153.4`, so the word after a lone image is another image and the word after an
/// option is the subcommand.
///
/// SEPARATED only, for the same reason as `codexValueTakingOptions`: the joined and attached
/// spellings carry exactly one value inside the token, measured - `codex --image=a.png doctor` and
/// `codex -ia.png doctor` both run the doctor.
let codexVariadicOptions: Set<String> = ["-i", "--image"]

/// Whether clap reads this word as an option rather than as somebody's value. A lone "-" is codex's
/// "read the prompt from stdin" and belongs to whatever is collecting values: measured,
/// `codex -i a.png - doctor` is still the interactive session.
func codexReadsAsOption(_ token: String) -> Bool { token.hasPrefix("-") && token != "-" }

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
    return typed.contains { token in
        if token == "--approve-for-me" || codexBypassSpellings.contains(token) { return true }
        return codexPermissionOptions.contains { option in
            // The long name is the whole token or carries a joined value; EVERY short spelling
            // begins with the short name and nothing else does, separated (`-s read-only`), joined
            // (`-s=read-only`) and attached (`-sread-only`) alike. Split on the double dash so
            // `--add-dir` cannot read as an `-a` carrying "dd-dir", and matched case-sensitively so
            // `-C` (the working root) is not `-c`.
            if token.hasPrefix("--") {
                return token == option.long || token.hasPrefix(option.long + "=")
            }
            return token.hasPrefix(option.short)
        }
    }
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
/// The gate is per axis, not per launch. The sandbox flag is the session's own and stops at the
/// table above; the model goes on past it in the option every subcommand takes, so that
/// `tally codex review` runs the model the project declared rather than codex's own default; and
/// the effort, which only ever had that second spelling, stops where an APPENDED `-c` is not
/// codex's to read (`codexSubcommandsRejectingAppendedConfig`).
func applyCodexLaunchDefaults(_ args: [String], policy: LaunchPolicy) -> [String] {
    var next = args
    let typed = optionsOnly(args)
    let subcommand = codexSubcommand(typed)
    let takesSessionFlags = subcommand.map(codexSubcommandsTakingSessionFlags.contains) ?? true
    let takesAppendedConfig = subcommand
        .map { !codexSubcommandsRejectingAppendedConfig.contains($0) } ?? true
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
    // The 25 names that refuse `-m` reach the same setting through the config override, which is
    // the spelling that made this worth saying twice: `codex review -m gpt-5.6-sol` is
    // `error: unexpected argument '-m' found` while `codex review -c 'model="gpt-5.6-sol"'` exits
    // 0, and `codex exec -c 'model="gpt-5.6-sol"'` comes up `model: gpt-5.6-sol` on its own banner.
    if let model = policy.model, !codexModelChoice(typed).named {
        if takesSessionFlags {
            next = injectingOptions(next, ["-m", model])
        } else if takesAppendedConfig {
            next = injectingOptions(next, ["-c", "model=\"\(model)\""])
        }
    }
    if let effort = policy.effort, takesAppendedConfig,
       !codexTypedConfigOverride(typed, keys: ["model_reasoning_effort"]) {
        next = injectingOptions(next, ["-c", "model_reasoning_effort=\"\(effort)\""])
    }
    return next
}

/// The subcommand names whose parser never sees a `-c` that Tally APPENDED. `-c` is clap's global
/// option and every one of these takes one in FRONT of its own arguments, so this is a table about
/// the POSITION the injection uses, not about acceptance: `injectingOptions` puts Tally's flags at
/// the end of the options half, which for these three is somebody else's territory.
///
/// Measured on 0.153.4, each against its own control:
///   help       - takes subcommand NAMES and no options at all. `codex help -c
///                model_reasoning_effort="high"` and `codex help review -c …` are both
///                `error: unrecognized subcommand '-c'`, exit 2, where `codex help review` exits 0.
///   sandbox    - `codex sandbox [OPTIONS] [COMMAND]...`, and everything past the command is the
///                command's. `codex sandbox echo hi -c model_reasoning_effort="high"` prints
///                `hi -c model_reasoning_effort="high"`: the override became an argument OF the
///                sandboxed program, silently. The same override in front of the command is codex's
///                own (`codex sandbox -c bogus_no_equals echo hi` is `Error: Invalid override
///                (missing '=')`), which is what makes this a position rather than an acceptance.
///   execpolicy - `codex execpolicy check [OPTIONS] --rules <PATH> <COMMAND>...`, the same shape,
///                detected the way clap's trailing-argument mode shows itself: an unknown flag past
///                the command is SWALLOWED (`codex execpolicy check --rules … ls --bogusflag`
///                exits 0) where a subcommand without that mode rejects one (`codex exec hi
///                --bogusflag` is `error: unexpected argument '--bogusflag' found`, exit 2).
///
/// The other 30 names take the appended override: measured on `mcp list`, `completion bash`,
/// `features list`, `debug models`, `doctor` and `review --commit abc`, all exit 0 with it at the
/// very end, and two of them together (`-c model=… -c model_reasoning_effort=…`) do too.
///
/// Keyed on the TOP-LEVEL name even though two of the three only swallow at a nested one, because
/// standing down costs these three nothing: none of them runs a model or spends any reasoning.
let codexSubcommandsRejectingAppendedConfig: Set<String> = ["help", "sandbox", "execpolicy"]
