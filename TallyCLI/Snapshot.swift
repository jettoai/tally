import Darwin
import Foundation

// Snapshot model + launch plumbing shared by every subcommand; the account pick itself (scoring,
// `best`, and the picks built on it) lives next door in AccountPick.swift.
//
// The CLI NEVER calls a usage API - Tally.app is the only poller (the Anthropic usage endpoint
// rate-limits; see the app's UsageSnapshot.swift). It reads the app's published snapshot
// (~/.tally/snapshot.json), picks the eligible account whose binding quota window can sustain
// the highest spend rate (see `smartScore`), sets the provider's config-home env var, and runs
// the provider's own CLI. No tokens are read or written, ever.

/// Mirror of the app's `UsageSnapshot` (kept dependency-free).
struct Snapshot: Decodable {
    /// Equatable so a value that CARRIES an account can be compared as a whole (the switch target
    /// state, and the assertions about it). Every stored property is already Equatable, so this is
    /// the synthesized member-by-member comparison and nothing more.
    struct Account: Decodable, Equatable {
        var id: String
        var provider: String
        var label: String
        /// The subscribed plan ("Max 20x", "Pro", "Team"); absent in snapshots from older apps,
        /// which just leaves the advisor's tier split unnamed.
        var plan: String?
        var launchHome: String?
        var sessionRemaining: Double?
        var weeklyRemaining: Double?
        var modelRemaining: Double?
        // v2 fields (absent in old snapshots; scoring then degrades to plain headroom order).
        var sessionResetsAt: Date?
        var weeklyResetsAt: Date?
        var modelResetsAt: Date?
        var modelWindowName: String?
        /// Codex reset banking: banked resets the account can redeem (read-only signal).
        var resetCreditsAvailable: Int?
        var isStale: Bool
        var error: String?
        /// When THIS ACCOUNT's numbers were fetched, which is a different question from when the
        /// file was written: the app rebuilds the whole document from its cached accounts whenever
        /// a setting changes, so `generatedAt` can be seconds old while every reading in it is
        /// minutes old (`republishSnapshot`, Tally/Stores/UsageStorePublishing.swift). Only this
        /// stamp can tell a supervisor whether a reading describes the wall its session just hit.
        ///
        /// SECOND GRANULARITY, deliberately: the writer encodes dates with `.iso8601` and no
        /// fractional seconds, so this arrives floored to the second while the cap's own instant
        /// comes from a transcript line that keeps its milliseconds. Every comparison against it is
        /// therefore biased toward "cannot tell", which is the safe direction here and the reason
        /// the writer is left alone - turning fractional seconds on there would change the encoding
        /// of every date in the file for supervisors from earlier builds that are still running.
        ///
        /// nil in a snapshot from an app that predates the field (the schema only ever gains
        /// fields), and readers must treat that as "cannot tell" rather than as "fresh".
        var refreshedAt: Date?
        /// Whether this account's LATEST poll failed, so every number in this row is held over from
        /// an earlier round. Published from the first failure with no debounce, which is the whole
        /// reason it exists beside `isStale`: that one waits for a second consecutive failure so the
        /// app's "Outdated" badge does not flicker on a token rotation, and the interval between the
        /// two failures is a row that reads as freshly fetched and is not.
        ///
        /// nil from an app that predates the field, which is "cannot tell" and not "the poll
        /// succeeded": a reader that must not act on held-over numbers falls back to `isStale` and
        /// `error` there, and accepts that such an app leaves the first failure unannounced.
        var lastRefreshFailed: Bool?
    }

    var version: Int
    var generatedAt: Date
    var accounts: [Account]
    /// The account ids in the order the app's PANEL renders them (the user's own drag order).
    /// Absent in snapshots from an older app, which reads as "no preference" and leaves every
    /// surface on the order `accounts` arrives in.
    var accountOrder: [String]?
    /// User preference: the status line renders the full quota line even when wrapping a
    /// custom status line (absent in old snapshots → minimal signal).
    var statuslineFullQuota: Bool?
    /// The panel's used/remaining toggle ("used" | "remaining"); the status line follows it.
    var displayMode: String?
    /// Per-provider fleet pool summary (present only while the app's fleet gauge is on and the
    /// provider has 2+ accounts). Units: one account's full weekly window = 100.
    struct Fleet: Codable {
        var remaining: Double
        var capacity: Double
        var dryAt: Date?
        var sustainable: Bool
        /// Which pool this is when a model pool leads the gauge ("Fable"); nil = the weekly pool.
        var poolName: String?
    }
    var fleet: [String: Fleet]?
    /// The panel's ordered pool list per provider (gauge focus applied app-side), leading pool
    /// first - the status line renders every entry. Absent in snapshots from older apps; the
    /// status line then falls back to the single headline pool in `fleet`.
    var fleetPools: [String: [Fleet]]?
}

let snapshotURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".tally/snapshot.json")
let snapshotMaxAge: TimeInterval = 15 * 60

struct Provider {
    let id: String
    let cli: String
    let envKey: String
    /// The environment variable that tells this CLI which model to run, or nil when it has none.
    ///
    /// Only the ENVIRONMENT reaches a launch nobody passed arguments to - the PATH shim's bare
    /// `claude` (IntegrationsStore.shimScript). So this is also what decides whether a bare launch
    /// may be STEERED by a model: scoring accounts for a model that cannot be handed to the child
    /// picks an account for a session that will not run it, which is worse than not steering.
    ///
    /// claude: verified against 2.1.222 by reading the binary, never by running it (this repo does
    /// not probe `claude -p`). The CLI resolves `t.model || process.env.ANTHROPIC_MODEL`, prefers
    /// the env var over the settings file, and its own startup telemetry names the three sources in
    /// that order (`cli_flag`, `env_var`, `settings_file`). codex 0.146.0 exposes no counterpart:
    /// its CODEX_* variables cover auth, home, and transport, and none of them names a model.
    let modelEnvKey: String?
}

let providers = [
    Provider(id: "claude", cli: "claude", envKey: "CLAUDE_CONFIG_DIR",
             modelEnvKey: "ANTHROPIC_MODEL"),
    Provider(id: "codex", cli: "codex", envKey: "CODEX_HOME", modelEnvKey: nil),
]

/// The user-intent half of the app↔CLI contract (`~/.tally/state.json`, written by the app's
/// LaunchPolicyStore): which account new sessions launch on. Missing file/entry = "auto"
/// (headroom pick), the launcher's historical behavior.
struct LaunchPolicy {
    var mode = "auto"
    var pinnedAccountID: String?
    var pinnedHome: String?
    /// Claude permission mode chosen in the app ("plan" / "acceptEdits" / "bypass"); nil = inject
    /// nothing. Flags the user typed always outrank it.
    var permissionMode: String?
    /// Launch defaults chosen in the app; nil = inject nothing. Same rule: typed flags win.
    var startMode: String?
    var model: String?
    var fallbackModel: String?
    var effort: String?
    var fallbackEffort: String?
    var fallbackArgs: String?
}

let stateURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".tally/state.json")

func launchPolicy(_ providerID: String) -> LaunchPolicy {
    struct StateFile: Decodable {
        struct Policy: Decodable {
            var mode: String?
            var pinnedAccountID: String?
            var pinnedHome: String?
            var permissionMode: String?
            var startMode: String?
            var model: String?
            var fallbackModel: String?
            var effort: String?
            var fallbackEffort: String?
            var fallbackArgs: String?
        }
        var launch: [String: Policy]?
    }
    guard let data = try? Data(contentsOf: stateURL),
          let file = try? JSONDecoder().decode(StateFile.self, from: data),
          let policy = file.launch?[providerID] else {
        // Mirror of LaunchPolicyStore.factoryDefault (the app side): a provider the user never
        // configured launches with the power-user defaults, not with nothing.
        var fresh = LaunchPolicy()
        fresh.permissionMode = "bypass"
        fresh.startMode = "continue"
        if providerID == "claude" {
            fresh.model = "fable"
            fresh.effort = "high"
            fresh.fallbackModel = "opus"
            fresh.fallbackEffort = "ultracode"
        } else {
            fresh.model = "gpt-5.6-sol"
            fresh.effort = "xhigh"
        }
        return fresh
    }
    return LaunchPolicy(mode: policy.mode ?? "auto",
                        pinnedAccountID: policy.pinnedAccountID,
                        pinnedHome: policy.pinnedHome,
                        permissionMode: policy.permissionMode,
                        startMode: policy.startMode,
                        model: policy.model,
                        fallbackModel: policy.fallbackModel,
                        effort: policy.effort,
                        fallbackEffort: policy.fallbackEffort,
                        fallbackArgs: policy.fallbackArgs)
}

func loadSnapshot() -> (Snapshot?, String?) {
    guard let data = try? Data(contentsOf: snapshotURL) else {
        return (nil, "no snapshot at \(snapshotURL.path) - is Tally.app running?")
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    guard let snapshot = try? decoder.decode(Snapshot.self, from: data) else {
        return (nil, "unreadable snapshot - update Tally.app?")
    }
    let age = Date().timeIntervalSince(snapshot.generatedAt)
    if age > snapshotMaxAge {
        return (snapshot, "snapshot is \(Int(age / 60))m old - is Tally.app running?")
    }
    return (snapshot, nil)
}

/// Compact two-unit countdown ("4h22m", "4d3h", "45m") - one unit hid too much ("(5d)" for
/// 5d 23h), and the status line inherited the coarseness user-visibly.
func shortETA(_ seconds: TimeInterval) -> String {
    let minutes = max(Int((seconds / 60).rounded()), 0)
    if minutes < 60 { return "\(minutes)m" }
    let hours = minutes / 60
    if hours < 48 {
        let m = minutes % 60
        return m > 0 ? "\(hours)h\(m)m" : "\(hours)h"
    }
    let days = hours / 24
    let h = hours % 24
    return h > 0 ? "\(days)d\(h)h" : "\(days)d"
}

func warn(_ message: String) {
    FileHandle.standardError.write(Data("[tally] \(message)\n".utf8))
}

/// Replace this process with the provider CLI (never returns on success).
func exec(_ cli: String, args: [String], env: (key: String, value: String)?) -> Never {
    if let env { setenv(env.key, env.value, 1) }
    // Every launch that went through tally is marked, so the status line can show ✦.
    setenv("TALLY_LAUNCHED", "1", 1)
    // A plain exec is deliberately unsupervised (--account pin, --no-handoff, bare fallback): mark
    // it so the status line stays quiet instead of nagging "supervisor unknown". The resident
    // supervisor spawns its child without this marker, so it reads as supervised.
    setenv("TALLY_SUPERVISED", "0", 1)
    // AND NO LAUNCH FROM HERE STOPS AT THE RESUME PROMPT EITHER. The supervised spawn suppresses it
    // in the environment it assembles (SupervisorRuntime.swift); these are the same launches with
    // no supervisor in front of them, and leaving them out would make "Tally never asks" true of
    // `tally claude` and false of `tally claude --account X --continue`, which is the shape a person
    // reads as a bug rather than as a policy (owner ruling, 2026-08-10).
    //
    // The one rule, asked of the environment execvp is about to inherit, rather than a second copy
    // of it here: that is also where "a value somebody exported is never overwritten" lives, so an
    // answer at all means this process carries none (ResumePrompt.swift).
    for (key, value) in resumePromptSuppression(ProcessInfo.processInfo.environment) {
        setenv(key, value, 1)
    }
    let argv = [cli] + args
    var cargs: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) }
    cargs.append(nil)
    // Past Tally's PATH shim (ProviderExecutable.swift): every caller of this function has already
    // chosen the account, and the shim, seeing the default home's unset CLAUDE_CONFIG_DIR, would
    // read that as a fresh launch and choose again (session c80ebeb2, 2026-07-26).
    execvp(resolveProviderExecutable(cli), cargs)
    warn("cannot exec `\(cli)`: \(String(cString: strerror(errno)))")
    exit(127)
}

/// The env to launch an account with. The DEFAULT home (~/.claude, ~/.codex) must launch with the
/// variable UNSET: the CLI namespaces its Keychain item by the exact CLAUDE_CONFIG_DIR string, so
/// explicitly setting it to the default path makes the CLI look up a hashed item that doesn't exist
/// ("Not logged in" - verified 2026-07-16).
func launchEnv(_ provider: Provider, home: String) -> (key: String, value: String)? {
    if home == defaultHome(provider) {
        unsetenv(provider.envKey)
        return nil
    }
    return (provider.envKey, home)
}

/// Claude Code's marker for a session it started itself. It is set on the child's environment, so
/// every process that inherits that environment carries it too - including one that is not a child
/// session at all, which is the whole point of the check below.
let childSessionMarker = "CLAUDE_CODE_CHILD_SESSION"

/// Whether this process's environment was INHERITED from a running Claude Code session rather than
/// written by the person at the keyboard. The two arrive as the same variables, and only one of them
/// is a choice.
///
/// The tell is Claude Code's own child marker contradicting itself. It marks the sessions Claude
/// Code spawns, and it spawns them through a pipe; a marker sitting in the environment of a command
/// somebody TYPED (stdout on a terminal) therefore cannot be describing this process. What it does
/// describe is a terminal that was itself started from inside a session and took the whole
/// environment with it, so every window opened afterwards carries that one session's config home
/// and its child marker (owner-reported 2026-08-13).
///
/// Claude only: the marker is Claude Code's, and a codex environment says nothing by carrying it.
///
/// KNOWN EDGE, accepted rather than closed: a pipeline the user assembles THEMSELVES inside a
/// leaked terminal (`tally claude --print | jq`) has its stdout on a pipe too, so it reads as a
/// real child and keeps the leaked home. There is no stronger signal to tell those two apart - a
/// genuine child session arrives as exactly the same marker on exactly the same kind of stdout -
/// and the direction of the mistake is the survivable one: a launch that keeps a home it should
/// have dropped, rather than a session torn off its parent's account halfway through. Same family
/// as the cost the launcher already names for `! tally claude` typed inside a session (main.swift):
/// this test reads the shape of the launch, and a launch can be shaped like the other thing.
func inheritedSessionEnvironment(
    providerID: String, stdoutIsTTY: Bool,
    environment: [String: String] = ProcessInfo.processInfo.environment
) -> Bool {
    providerID == "claude" && stdoutIsTTY && environment[childSessionMarker] != nil
}

/// The provider's own config home (~/.claude, ~/.codex) - where a launch that sets no env var
/// ends up, which is what the bare-CLI fallbacks run under.
func defaultHome(_ provider: Provider) -> String {
    FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(provider.id == "claude" ? ".claude" : ".codex").path
}

/// Whether `home` holds a Claude session for `cwd`: exactly the directory the `claude` CLI
/// resolves `--continue` against (`<home>/projects/<cwd-slug>/*.jsonl`). Scoped to ONE home on
/// purpose - a sibling account having a transcript for this directory does not help, because
/// claude would not find it either.
func hasConversation(home: String, cwd: String = FileManager.default.currentDirectoryPath) -> Bool {
    let dir = URL(fileURLWithPath: home)
        .appendingPathComponent("projects/\(projectSlug(forCwd: cwd))")
    let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
    return files.contains { $0.hasSuffix(".jsonl") }
}

/// Session flags that mean the user already chose how this launch starts. Tally's own injection
/// stands down for any of them; `--print`/`-p` is here because a one-shot run is not a session.
let sessionFlags: Set<String> = ["--continue", "-c", "--resume", "-r", "--print", "-p"]

/// The part of an argument vector that is still OPTIONS: everything before the first bare `--`.
///
/// claude's CLI takes `claude [options] [command] [prompt]` and parses it the POSIX way, so a bare
/// `--` ends the options and everything after it is the prompt. `tally claude -- --print summarise`
/// is therefore an interactive session whose prompt happens to begin with the word `--print`, and
/// every question Tally asks about a launch ("did they opt out", "is this a one-shot run", "can this
/// be carried") has to stop at the same place the CLI stops - otherwise Tally reads a prompt as an
/// instruction about itself.
///
/// Lives here rather than with the readers in LaunchFlags.swift because `sessionFlags` does: this is
/// the vocabulary both files share, and the dependency stays one-way (LaunchFlags reads Snapshot,
/// never the reverse), which is also what keeps the smaller test runners compiling.
func optionsOnly(_ args: [String]) -> [String] {
    guard let end = args.firstIndex(of: "--") else { return args }
    return Array(args[..<end])
}

/// `args` with Tally's own flags inserted where they will be READ: before the first bare `--`, not
/// appended after everything.
///
/// Appending looked equivalent because it usually is - with no `--` there is nothing to be after.
/// With one, the injected flag lands in the PROMPT: claude never parses it, and Tally cannot see it
/// either (every reader stops at the marker), so the launch runs without the default it thinks it
/// applied, `FollowState` reads no `--model` and schedules an adoption for a setting that never
/// changed, and each relaunch stacks another copy onto the end of what the user said.
func injectingOptions(_ args: [String], _ flags: [String]) -> [String] {
    let options = optionsOnly(args)
    return options + flags + args[options.count...]
}

/// `args` with one of Tally's own flags dropped from the OPTIONS only. The same word past the marker
/// is a word in the prompt, and removing it edits what the user said.
func removingOption(_ args: [String], _ flag: String) -> [String] {
    let options = optionsOnly(args)
    return options.filter { $0 != flag } + args[options.count...]
}

/// The value following `flag` in an argument vector (nil when absent or dangling). Read from the
/// OPTIONS only: past a bare `--` the same word is part of the user's prompt, and `--model` there is
/// something they wrote, not something they asked for.
///
/// Lives here with `optionsOnly`, the rule it is an application of, rather than with the launch-flag
/// readers in LaunchFlags.swift: everything that asks what a launch will RUN needs it, including the
/// account pick, which must compile without the supervisor.
func flagValue(_ args: [String], _ flag: String) -> String? {
    let options = optionsOnly(args)
    guard let index = options.firstIndex(of: flag), index + 1 < options.count else { return nil }
    return options[index + 1]
}

/// The model an argument vector will actually run under, in whichever spelling that provider uses
/// (`--model` for claude, `-m` or `--model` for codex).
///
/// Read off the args AFTER `applyLaunchDefaults` has run, which is the whole point: that injection
/// has already settled typed > project > app, so the account pick reads the ANSWER rather than
/// ranking the three sources a second time. A second ranking is a second chance to rank them
/// differently, and it did: `tally claude --model opus` reached the child as opus while the pick
/// went on scoring accounts for the configured default, so a session deliberately launched a tier
/// down was still refused an account whose flagship window was dry.
///
/// nil means the launch declares no model at all (nothing configured and nothing typed) - or that
/// the user typed a dangling `--model` with no value, which suppresses the injection and leaves the
/// CLI to complain about its own flag. Callers fall back to the configured default.
func launchPrimaryModel(_ args: [String], providerID: String) -> String? {
    /// A value that is itself a flag is not a model. Measured 2026-08-06: `tally claude --model`
    /// with no value suppresses the model injection (the axis was typed) and the NEXT injection
    /// lands right behind it, so the vector reads `--model --fallback-model opus …` and a plain
    /// read hands back `--fallback-model` as the model this launch runs. Harmless while that value
    /// only became a flag; it is not harmless now that it also decides which accounts are eligible.
    func declared(_ flag: String) -> String? {
        guard let value = flagValue(args, flag), !value.hasPrefix("-") else { return nil }
        return value
    }
    if providerID == "codex" { return declared("-m") ?? declared("--model") }
    return declared("--model")
}

/// Applies the launch defaults that can be decided BEFORE the account is known - the permission
/// mode, the model, the fallback model and the effort - to a launch's arguments.
///
/// `policy` is the effective policy: the app's defaults with this project's profile already laid
/// over them (ProjectPolicy.swift). Which is why every check here is against what the user TYPED
/// rather than against the app's own values: the rule is one rule at both scopes ("a flag you typed
/// wins"), and a project that declares opus must inject opus exactly as Settings would.
///
/// Both halves of every check stop at the first bare `--`: the question is what the user CHOSE, and
/// the answer goes where it will be read (`optionsOnly`, `injectingOptions`).
func applyLaunchDefaults(_ args: [String], policy: LaunchPolicy, providerID: String) -> [String] {
    var next = args
    let typed = optionsOnly(args)
    if providerID == "claude" {
        if let mode = policy.permissionMode,
           !typed.contains("--dangerously-skip-permissions"),
           !typed.contains("--permission-mode") {
            switch mode {
            case "plan": next = injectingOptions(next, ["--permission-mode", "plan"])
            case "acceptEdits": next = injectingOptions(next, ["--permission-mode", "acceptEdits"])
            case "bypass": next = injectingOptions(next, ["--dangerously-skip-permissions"])
            default: break
            }
        }
        if let model = policy.model, !typed.contains("--model") {
            next = injectingOptions(next, ["--model", model])
        }
        if let fallback = policy.fallbackModel, !typed.contains("--fallback-model") {
            next = injectingOptions(next, ["--fallback-model", fallback])
        }
        if let effort = policy.effort, !typed.contains("--effort") {
            next = injectingOptions(next, ["--effort", effort])
        }
    }
    if providerID == "codex" {
        if let model = policy.model, !typed.contains("-m"), !typed.contains("--model") {
            next = injectingOptions(next, ["-m", model])
        }
        if let effort = policy.effort,
           !typed.contains(where: { $0.contains("model_reasoning_effort") }) {
            next = injectingOptions(next, ["-c", "model_reasoning_effort=\"\(effort)\""])
        }
    }
    return next
}

/// Applies the app's "continue by default" start mode to a launch, given the home it will run
/// under. Returns the args to launch with, plus the one line to print when the injection was
/// suppressed (nil = nothing to say).
///
/// The check is against the launch account's own transcripts because `claude --continue` in a
/// directory that home has never held a session for prints "No conversation found to continue"
/// and exits, turning the first launch in any new project directory into a retype. A hand-typed
/// flag is left exactly as typed: the worktree path strips one, but that is a launch into a
/// directory the user just asked to create, whereas here someone who typed `--continue` deserves
/// the CLI's own error rather than a silently dropped flag.
func applyStartMode(_ args: [String], policy: LaunchPolicy, wantsNew: Bool, home: String,
                    cwd: String = FileManager.default.currentDirectoryPath)
    -> (args: [String], note: String?) {
    guard policy.startMode == "continue", !wantsNew,
          !optionsOnly(args).contains(where: { sessionFlags.contains($0) })
    else { return (args, nil) }
    guard hasConversation(home: home, cwd: cwd) else {
        return (args, "no conversation in this directory yet - starting fresh")
    }
    return (injectingOptions(args, ["--continue"]), nil)
}

func fmt(_ value: Double?) -> String {
    value.map { "\(Int($0.rounded()))%" } ?? "—"
}

/// The transcript-directory slug Claude Code uses for a working directory: "/" and "." become "-",
/// on the fully-resolved path (/tmp → /private/tmp). POSIX realpath, NOT Foundation's
/// resolvingSymlinksInPath - the latter deliberately strips the /private prefix and would produce
/// a slug that doesn't match Claude Code's directory.
func projectSlug(forCwd rawCwd: String) -> String {
    var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
    let cwd = realpath(rawCwd, &buffer).map { String(cString: $0) } ?? rawCwd
    return cwd.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ".", with: "-")
}

func parseISO(_ string: String) -> Date? {
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = fractional.date(from: string) { return date }
    let plain = ISO8601DateFormatter()
    return plain.date(from: string)
}
