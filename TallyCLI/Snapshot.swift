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
    struct Account: Decodable {
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
    }

    var version: Int
    var generatedAt: Date
    var accounts: [Account]
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
}

let providers = [
    Provider(id: "claude", cli: "claude", envKey: "CLAUDE_CONFIG_DIR"),
    Provider(id: "codex", cli: "codex", envKey: "CODEX_HOME"),
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
