import Darwin
import Foundation

// Snapshot model + account selection + launch plumbing shared by every subcommand.
//
// The CLI NEVER calls a usage API - Tally.app is the only poller (the Anthropic usage endpoint
// rate-limits; see the app's UsageSnapshot.swift). It reads the app's published snapshot
// (~/.tally/snapshot.json), picks the eligible account with the greatest proven headroom
// (max over accounts of min(session, weekly, model remaining)), sets the provider's config-home
// env var, and runs the provider's own CLI. No tokens are read or written, ever.

/// Mirror of the app's `UsageSnapshot` (kept dependency-free).
struct Snapshot: Decodable {
    struct Account: Decodable {
        var id: String
        var provider: String
        var label: String
        var launchHome: String?
        var sessionRemaining: Double?
        var weeklyRemaining: Double?
        var modelRemaining: Double?
        var isStale: Bool
        var error: String?
    }

    var version: Int
    var generatedAt: Date
    var accounts: [Account]
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
        }
        var launch: [String: Policy]?
    }
    guard let data = try? Data(contentsOf: stateURL),
          let file = try? JSONDecoder().decode(StateFile.self, from: data),
          let policy = file.launch?[providerID] else { return LaunchPolicy() }
    return LaunchPolicy(mode: policy.mode ?? "auto",
                        pinnedAccountID: policy.pinnedAccountID,
                        pinnedHome: policy.pinnedHome,
                        permissionMode: policy.permissionMode,
                        startMode: policy.startMode,
                        model: policy.model,
                        fallbackModel: policy.fallbackModel,
                        effort: policy.effort)
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

/// Proven headroom: the tightest of the windows the account actually reports. Any window at 0
/// means the account is capped right now regardless of the others.
func headroom(_ account: Snapshot.Account) -> Double {
    let windows = [account.sessionRemaining, account.weeklyRemaining, account.modelRemaining]
        .compactMap { $0 }
    return windows.min() ?? -1
}

func eligible(_ account: Snapshot.Account) -> Bool {
    account.launchHome != nil && account.error == nil && !account.isStale && headroom(account) > 0
}

func best(providerID: String, in snapshot: Snapshot) -> Snapshot.Account? {
    snapshot.accounts
        .filter { $0.provider == providerID && eligible($0) }
        .max { headroom($0) < headroom($1) }
}

func warn(_ message: String) {
    FileHandle.standardError.write(Data("[tally] \(message)\n".utf8))
}

/// Replace this process with the provider CLI (never returns on success).
func exec(_ cli: String, args: [String], env: (key: String, value: String)?) -> Never {
    if let env { setenv(env.key, env.value, 1) }
    let argv = [cli] + args
    var cargs: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) }
    cargs.append(nil)
    execvp(cli, cargs)
    warn("cannot exec `\(cli)`: \(String(cString: strerror(errno)))")
    exit(127)
}

/// The env to launch an account with. The DEFAULT home (~/.claude, ~/.codex) must launch with the
/// variable UNSET: the CLI namespaces its Keychain item by the exact CLAUDE_CONFIG_DIR string, so
/// explicitly setting it to the default path makes the CLI look up a hashed item that doesn't exist
/// ("Not logged in" - verified 2026-07-16).
func launchEnv(_ provider: Provider, home: String) -> (key: String, value: String)? {
    let defaultHome = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(provider.id == "claude" ? ".claude" : ".codex").path
    if home == defaultHome {
        unsetenv(provider.envKey)
        return nil
    }
    return (provider.envKey, home)
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
