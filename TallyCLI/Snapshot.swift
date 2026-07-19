import Darwin
import Foundation

// Snapshot model + account selection + launch plumbing shared by every subcommand.
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
          let policy = file.launch?[providerID] else { return LaunchPolicy() }
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

/// One usage window with its sustainable burn rate: how much quota per hour it can spend until
/// it refreshes. A window about to reset stops being a constraint (its rate soars, and its
/// leftover quota would evaporate unused) - the "burn the dying quota first" intuition; a window
/// with days to go binds hard. Missing reset times assume a full window, so old snapshots
/// degrade to plain headroom ordering instead of gaining a phantom advantage.
struct RatedWindow {
    let name: String
    let remaining: Double
    let resetsAt: Date?
    let rate: Double
}

func ratedWindows(_ account: Snapshot.Account, primaryModel: String?,
                  now: Date = Date()) -> [RatedWindow] {
    func window(_ name: String, _ remaining: Double?, _ resetsAt: Date?,
                fullWindowHours: Double) -> RatedWindow? {
        guard let remaining else { return nil }
        let hours = resetsAt.map { max($0.timeIntervalSince(now) / 3600, 0.05) } ?? fullWindowHours
        return RatedWindow(name: name, remaining: remaining, resetsAt: resetsAt,
                           rate: remaining / hours)
    }
    var windows = [
        window("session", account.sessionRemaining, account.sessionResetsAt, fullWindowHours: 5),
        window("weekly", account.weeklyRemaining, account.weeklyResetsAt, fullWindowHours: 168),
    ].compactMap { $0 }
    // The flagship window only constrains the pick when the declared primary model IS that tier
    // (a sonnet primary doesn't drain the fable window, so a drained fable window must not veto
    // the account). No declared primary = flagship-first, the app's display philosophy.
    let windowModel = account.modelWindowName?.lowercased()
    let primary = primaryModel?.lowercased()
    let modelWindowCounts = primary == nil || windowModel == nil
        || windowModel!.contains(primary!) || primary!.contains(windowModel!)
    if modelWindowCounts,
       let model = window(account.modelWindowName ?? "model", account.modelRemaining,
                          account.modelResetsAt, fullWindowHours: 168) {
        windows.append(model)
    }
    return windows
}

/// An account's score is its TIGHTEST window's rate - the binding constraint. `best()` then picks
/// the account whose binding constraint is loosest, which naturally prefers an account whose low
/// session quota resets in minutes over one hoarding a bigger but slower-refreshing allowance.
func smartScore(_ account: Snapshot.Account, primaryModel: String?, now: Date = Date()) -> Double {
    ratedWindows(account, primaryModel: primaryModel, now: now).map(\.rate).min() ?? -1
}

/// The human reason behind a pick: its binding window, e.g. "weekly 32% · resets 2d".
func pickReason(_ account: Snapshot.Account, primaryModel: String?, now: Date = Date()) -> String {
    guard let binding = ratedWindows(account, primaryModel: primaryModel, now: now)
        .min(by: { $0.rate < $1.rate }) else { return "no usage windows" }
    var text = "\(binding.name) \(Int(binding.remaining.rounded()))%"
    if let resetsAt = binding.resetsAt {
        text += " · resets \(shortETA(resetsAt.timeIntervalSince(now)))"
    }
    return text
}

func shortETA(_ seconds: TimeInterval) -> String {
    let minutes = max(Int((seconds / 60).rounded()), 0)
    if minutes < 60 { return "\(minutes)m" }
    if minutes < 48 * 60 { return "\(minutes / 60)h" }
    return "\(minutes / (24 * 60))d"
}

/// Hysteresis: near-equal scores must not flip the pick. Quota percentages are coarse and
/// refresh-lagged, so the account just used dips a point below its idle sibling - without a
/// margin every new launch would bounce between the two (scattering conversation history
/// across accounts) for zero real gain. A later account only takes the lead by beating the
/// current leader by BOTH gates; ties and noise-level differences stay with the earlier
/// account in the (stable) list order.
///
/// Two gates because one ratio lies at the low end: at 2% vs 3% remaining the relative gap is
/// 50% yet the real difference is one noise-level point - two nearly-drained accounts would
/// ping-pong on it. The absolute gate (~8 weekly points over a full week) keeps them put; a
/// genuinely healthier sibling clears both gates easily. Sticking with a nearly-drained leader
/// is safe: the cap-hit handoff is the net.
let smartPickMargin = 1.15
let smartPickMinGain = 0.05   // %/h

func best(providerID: String, in snapshot: Snapshot, primaryModel: String? = nil,
          now: Date = Date()) -> Snapshot.Account? {
    let candidates = snapshot.accounts.filter { $0.provider == providerID && eligible($0) }
    guard var leader = candidates.first else { return nil }
    var leaderScore = smartScore(leader, primaryModel: primaryModel, now: now)
    for candidate in candidates.dropFirst() {
        let score = smartScore(candidate, primaryModel: primaryModel, now: now)
        if score > leaderScore * smartPickMargin, score > leaderScore + smartPickMinGain {
            leader = candidate
            leaderScore = score
        } else if score >= leaderScore,
                  (candidate.resetCreditsAvailable ?? 0) > (leader.resetCreditsAvailable ?? 0) {
            // Near-tie tie-breaker: a wall with banked resets behind it is SOFTER (capped =
            // redeemable), so burn that account and preserve the one whose wall is terminal.
            // Reads the banked count only - the smart pick never spends a reset.
            leader = candidate
            leaderScore = score
        }
    }
    return leader
}

func warn(_ message: String) {
    FileHandle.standardError.write(Data("[tally] \(message)\n".utf8))
}

/// Replace this process with the provider CLI (never returns on success).
func exec(_ cli: String, args: [String], env: (key: String, value: String)?) -> Never {
    if let env { setenv(env.key, env.value, 1) }
    // Every launch that went through tally is marked, so the status line can show ✦.
    setenv("TALLY_LAUNCHED", "1", 1)
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
