import Foundation

/// The non-secret usage snapshot the app publishes for the `tally` CLI (`~/.tally/snapshot.json`).
///
/// The app is the ONLY poller - the CLI never calls the usage API itself (the Anthropic OAuth usage
/// endpoint rate-limits aggressive polling; one extra poller per shell invocation would trip it).
/// The CLI just reads this file to pick the account with the most proven headroom and launch the
/// provider's own CLI with that account's config home. Percentages and paths only - never tokens.
struct UsageSnapshot: Codable {
    struct Account: Codable {
        var id: String
        var provider: String
        var label: String
        /// Config home to launch with (`CLAUDE_CONFIG_DIR` / `CODEX_HOME`); nil = not launchable.
        var launchHome: String?
        var sessionRemaining: Double?
        var weeklyRemaining: Double?
        /// Remaining % of the headline model-scoped window (e.g. Fable weekly), when reported.
        var modelRemaining: Double?
        /// v2: per-window reset times + the model window's name, so the CLI can pick by
        /// sustainable burn rate (remaining ÷ time-to-reset) instead of raw remaining %.
        var sessionResetsAt: Date?
        var weeklyResetsAt: Date?
        var modelResetsAt: Date?
        var modelWindowName: String?
        /// Codex reset banking: banked rate-limit resets the account can redeem. The smart pick
        /// READS this as a tie-breaker (a wall with an escape hatch is softer) - it never spends.
        var resetCreditsAvailable: Int?
        var isStale: Bool
        var error: String?
    }

    var version = 2
    var generatedAt: Date
    var accounts: [Account]
    /// User preference: the status line renders the full quota line (bars + resets) even when
    /// wrapping a custom status line. Published here because the snapshot is the app→CLI
    /// channel; the CLI reads no defaults.
    var statuslineFullQuota: Bool?
    /// The panel's used/remaining toggle ("used" | "remaining") - the status line follows it.
    var displayMode: String?
    /// Per-provider fleet pool summary (published only while the fleet gauge is on and the
    /// provider has 2+ accounts) - the status line's fleet piece renders from this. Units match
    /// FleetPool: one account's full weekly window = 100.
    struct Fleet: Codable {
        var remaining: Double
        var capacity: Double
        /// When the pool runs dry at the measured pace (nil = sustainable or still measuring).
        var dryAt: Date?
        var sustainable: Bool
    }
    var fleet: [String: Fleet]?

    static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".tally", isDirectory: true)
    static let fileURL = directory.appendingPathComponent("snapshot.json")

    /// Build from the store's merged account list + the per-account launch homes from discovery.
    /// `statuslineFullQuota` is handed in by the caller (SettingsStore is main-actor).
    static func make(accounts: [AccountUsage], launchHomes: [String: String],
                     statuslineFullQuota: Bool = false, displayMode: String? = nil,
                     fleet: [String: Fleet]? = nil, now: Date = Date()) -> UsageSnapshot {
        UsageSnapshot(
            generatedAt: now,
            accounts: accounts.map { usage in
                Account(
                    id: usage.id,
                    provider: usage.providerID,
                    label: usage.accountLabel,
                    launchHome: launchHomes[usage.id],
                    sessionRemaining: usage.metrics.first { $0.kind == .session }?.remainingPercent,
                    weeklyRemaining: usage.metrics.first { $0.kind == .weeklyAll }?.remainingPercent,
                    modelRemaining: usage.headline.flatMap { $0.isModelScoped ? $0.remainingPercent : nil },
                    sessionResetsAt: usage.metrics.first { $0.kind == .session }?.resetsAt,
                    weeklyResetsAt: usage.metrics.first { $0.kind == .weeklyAll }?.resetsAt,
                    modelResetsAt: usage.headline.flatMap { $0.isModelScoped ? $0.resetsAt : nil },
                    modelWindowName: usage.headline.flatMap { $0.isModelScoped ? $0.modelName : nil },
                    resetCreditsAvailable: usage.resetCreditsAvailable,
                    isStale: usage.isStale,
                    error: usage.error
                )
            },
            statuslineFullQuota: statuslineFullQuota,
            displayMode: displayMode,
            fleet: fleet
        )
    }

    /// Atomic write; failures are silently ignored (the snapshot is a convenience export - it must
    /// never break the app's own refresh loop).
    func write() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(self) else { return }
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        try? data.write(to: Self.fileURL, options: .atomic)
    }
}
