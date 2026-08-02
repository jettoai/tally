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

/// Proven headroom: the tightest of the windows the account actually reports. Any window at 0
/// means the account is capped right now regardless of the others. The flagship window only
/// binds when the declared primary model IS that tier: a sonnet primary does not drain the fable
/// window, so a fable window at 0 must not report the account as capped (same rule as
/// `ratedWindows`, which the score already follows - eligibility was the one place still counting
/// the flagship window unconditionally). No declared primary keeps it flagship-first, the app's
/// display philosophy, and matches the historical behavior for callers that pass nil.
func headroom(_ account: Snapshot.Account, primaryModel: String? = nil) -> Double {
    var windows = [account.sessionRemaining, account.weeklyRemaining].compactMap { $0 }
    let windowModel = account.modelWindowName?.lowercased()
    let primary = primaryModel?.lowercased()
    let modelWindowCounts = primary == nil || windowModel == nil
        || windowModel!.contains(primary!) || primary!.contains(windowModel!)
    if modelWindowCounts, let model = account.modelRemaining { windows.append(model) }
    return windows.min() ?? -1
}

func eligible(_ account: Snapshot.Account, primaryModel: String? = nil) -> Bool {
    account.launchHome != nil && account.error == nil && !account.isStale
        && headroom(account, primaryModel: primaryModel) > 0
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

/// One rated window as the nearly-dry gate (AccountComfort.swift) sees it. One conversion for the
/// whole CLI, so everything that asks the gate about a window weighs it the same way: the account
/// gate below, and the rebalance cycle key, which has to name the window the gate is reacting to.
func comfortWindow(_ window: RatedWindow) -> ComfortWindow {
    ComfortWindow(remaining: window.remaining, resetsAt: window.resetsAt)
}

/// What the nearly-dry gate weighs for a CLI account: exactly the windows `ratedWindows` counts for
/// the declared primary model, so the gate never re-decides which windows an account spends. Shared
/// by both gate policies, so they can differ in what they do with an empty result and in nothing
/// else.
private func comfortWindows(_ account: Snapshot.Account, primaryModel: String?,
                            now: Date) -> [ComfortWindow] {
    ratedWindows(account, primaryModel: primaryModel, now: now).map(comfortWindow)
}

/// The launch-side gate: drops the nearly dry, keeps the field whole when nothing is comfortable.
func preferringComfortable(_ accounts: [Snapshot.Account], primaryModel: String?,
                           now: Date) -> [Snapshot.Account] {
    preferringComfortable(accounts, now: now) {
        comfortWindows($0, primaryModel: primaryModel, now: now)
    }
}

/// Whether ONE account still has room to work in, by exactly the gate the picks apply to candidates
/// (imminent-reset exemption included). Asked of the account a session already RUNS on, which the
/// filtering helpers above cannot answer: they take a field and return a field.
func accountIsComfortable(_ account: Snapshot.Account, primaryModel: String?,
                          now: Date = Date()) -> Bool {
    isComfortable(comfortWindows(account, primaryModel: primaryModel, now: now), now: now)
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
          excluding: Set<String> = [], now: Date = Date()) -> Snapshot.Account? {
    // The nearly-dry gate runs first (AccountComfort.swift): a rate cannot tell "healthy" from
    // "1% left with a close reset", so accounts that are actually dry leave before the ordering.
    let eligibleAccounts = snapshot.accounts.filter {
        $0.provider == providerID && eligible($0, primaryModel: primaryModel)
            && !excluding.contains($0.id)
    }
    let candidates = preferringComfortable(eligibleAccounts, primaryModel: primaryModel, now: now)
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

/// The account a RUNNING session should adopt when its launch-default model changes, with the
/// current account SEEDED as the incumbent leader: a challenger only takes over by clearing BOTH
/// gates (1.15x rate AND an absolute gain) and being eligible for the new model. So a session
/// stays put whenever its account can still serve the new model, and switches only when the
/// incumbent genuinely can't (the 02:22 storm relaunched five sessions onto an account with no
/// room for the new model) or a sibling is decisively healthier. Returns nil only when nothing,
/// incumbent included, is eligible - a dead end the caller must not relaunch into. No banked-reset
/// tie-breaker here: this pick is about NOT churning a serviceable session, not launch economics.
///
/// A CHALLENGER must also clear the nearly-dry gate, which is the one thing this pick was missing:
/// `best` has applied it since it was written, the cap handoff and the idle rebalance both apply it,
/// and this was the last account pick in the repo deciding on a bare rate. A rate has no floor, so a
/// nearly empty window whose reset is close beats a full one whose reset is days away - which is how
/// two sessions moved onto an account with 4% of its week left and 1.2h until it refilled, while a
/// sibling sat at 98% (2026-08-02T06:47Z, reason=follow; measured 3.33 %/h against 0.67 %/h).
///
/// The INCUMBENT is deliberately not gated. Seeding it is the whole design, and dropping a dry
/// incumbent would turn every Settings change into a fleet-wide evacuation of a spent account, with
/// no claim to serialize it - five sessions adopting at once would all land on the one healthy
/// sibling, which is the storm above wearing a different hat. Moving a session off a dying account
/// is the idle rebalance's job (Rebalance.swift), where it happens once per account per drought.
func incumbentSeededBest(providerID: String, in snapshot: Snapshot, incumbentID: String,
                         primaryModel: String?, excluding: Set<String> = [],
                         now: Date = Date()) -> Snapshot.Account? {
    let candidates = snapshot.accounts.filter {
        $0.provider == providerID && eligible($0, primaryModel: primaryModel)
            && !excluding.contains($0.id)
    }
    // The incumbent can't serve the new model (or was quarantined): no incumbent to stabilize, so
    // fall back to the plain best of what remains.
    guard var leader = candidates.first(where: { $0.id == incumbentID }) else {
        return best(providerID: providerID, in: snapshot, primaryModel: primaryModel,
                    excluding: excluding, now: now)
    }
    var leaderScore = smartScore(leader, primaryModel: primaryModel, now: now)
    let challengers = requiringComfortable(candidates.filter { $0.id != incumbentID }, now: now) {
        comfortWindows($0, primaryModel: primaryModel, now: now)
    }
    for candidate in challengers {
        let score = smartScore(candidate, primaryModel: primaryModel, now: now)
        if score > leaderScore * smartPickMargin, score > leaderScore + smartPickMinGain {
            leader = candidate
            leaderScore = score
        }
    }
    return leader
}

/// The account a CAP HANDOFF moves a running session to, or nil to keep waiting on the capped one.
/// Takes the field the supervisor has already narrowed (right provider, eligible for the running
/// model, not the current account, not quarantined) and applies the STRICT half of the nearly-dry
/// gate: unlike a launch, this has a live session to lose, and a thin account is not worth the
/// restart it costs, so an empty field means wait rather than move. Waiting is not giving up: the
/// supervisor keeps polling and hands off the moment a sibling is genuinely usable.
func capHandoffTarget(_ eligibleAccounts: [Snapshot.Account], primaryModel: String?,
                      now: Date = Date()) -> Snapshot.Account? {
    requiringComfortable(eligibleAccounts, now: now) {
        comfortWindows($0, primaryModel: primaryModel, now: now)
    }
    .max { smartScore($0, primaryModel: primaryModel, now: now)
        < smartScore($1, primaryModel: primaryModel, now: now) }
}

/// The account an automatic launch would actually land on: `best` with the live cap quarantine
/// applied, falling back to the unfiltered pick when quarantine empties the field (launching on
/// an account that just capped still beats refusing to launch).
///
/// Every surface that PREDICTS the launch goes through here rather than calling `best` directly,
/// because a prediction that skips an exclusion the launcher applies is simply wrong: on
/// 2026-07-25 the app's smart-pick badge named a quarantined account, and the reader concluded
/// the picker was broken rather than that the badge was. One function, so a display cannot
/// contradict what launching does.
func launchPick(providerID: String, in snapshot: Snapshot, primaryModel: String?,
                quarantined: Set<String>, now: Date = Date()) -> Snapshot.Account? {
    best(providerID: providerID, in: snapshot, primaryModel: primaryModel,
         excluding: quarantined, now: now)
        ?? best(providerID: providerID, in: snapshot, primaryModel: primaryModel, now: now)
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
          !args.contains(where: { sessionFlags.contains($0) }) else { return (args, nil) }
    guard hasConversation(home: home, cwd: cwd) else {
        return (args, "no conversation in this directory yet - starting fresh")
    }
    return (args + ["--continue"], nil)
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
