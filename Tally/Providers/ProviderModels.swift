import Foundation

/// The kind of usage window a metric represents.
enum MetricKind: String, Sendable, Codable, Hashable {
    case session      // rolling short window (e.g. Claude 5h)
    case weeklyAll    // 7-day window across all models
    case weeklyModel  // 7-day window scoped to one model tier (e.g. Opus/Fable)
    case other
}

/// Provider-reported severity. Preferring the provider's own value over a local threshold means
/// the colour matches exactly what the vendor's dashboard shows.
enum MetricSeverity: String, Sendable, Codable, Hashable {
    case normal, warning, critical, unknown

    init(apiValue: String?) {
        switch apiValue?.lowercased() {
        case "normal", "ok": self = .normal
        case "warning", "warn", "near_limit": self = .warning
        case "critical", "exceeded", "over": self = .critical
        default: self = .unknown
        }
    }

    /// Severity by how much is left: under 20% remaining is critical (red), under 50% is warning
    /// (amber). Keyed on remaining so the thresholds read the way a user thinks about a quota.
    static func fromUsedPercent(_ percent: Double) -> MetricSeverity {
        let remaining = 100 - percent
        if remaining < 20 { return .critical }
        if remaining < 50 { return .warning }
        return .normal
    }
}

/// One normalized usage window. Every provider maps its response into these so the UI is
/// provider-agnostic. `usedPercent` is the source of truth; `remainingPercent` is derived, so the
/// used/remaining display toggle never needs a recompute in the mapper.
struct UsageMetric: Identifiable, Hashable, Sendable, Codable {
    var id: String
    var kind: MetricKind
    var label: String
    var modelName: String?
    var usedPercent: Double
    var severity: MetricSeverity
    var resetsAt: Date?
    /// The provider marked this as the limit currently binding the account (Claude `is_active`).
    var isActive: Bool

    var remainingPercent: Double { max(0, 100 - usedPercent) }
    var isModelScoped: Bool { kind == .weeklyModel }
}

extension Array where Element == UsageMetric {
    /// Guarantee unique ids so a SwiftUI `ForEach` never sees duplicate `Identifiable` ids (which
    /// produce undefined rendering). Degenerate provider responses (e.g. two model windows with no
    /// name) can otherwise collide on a derived id.
    func uniquingIDs() -> [UsageMetric] {
        var counts: [String: Int] = [:]
        return map { metric in
            let seen = counts[metric.id, default: 0]
            counts[metric.id] = seen + 1
            guard seen > 0 else { return metric }
            var copy = metric
            copy.id = "\(metric.id)#\(seen + 1)"
            return copy
        }
    }
}

/// A discovered account of a provider. `locator` is opaque provider-specific addressing (for Claude:
/// keychain service + config dir) so the UI never needs provider internals.
struct ProviderAccount: Identifiable, Hashable, Sendable {
    var id: String
    var providerID: String
    var label: String
    var locator: [String: String]
    /// The CLI config home to launch this account with (`CLAUDE_CONFIG_DIR` / `CODEX_HOME`) -
    /// exported in the usage snapshot so the `tally` CLI can pick and launch the best account.
    var launchHome: String?
}

/// The result of fetching one account's usage. Never thrown - failures are carried in `error` so one
/// dead account can't blank the whole popover.
struct AccountUsage: Identifiable, Hashable, Sendable {
    var id: String
    var providerID: String
    var accountLabel: String
    var planName: String?
    var metrics: [UsageMetric]
    var refreshedAt: Date
    var error: String?
    /// True when these metrics are the last-good snapshot shown because the latest refresh failed.
    /// `error` then carries the reason (for a tooltip) while the numbers stay visible.
    var isStale: Bool = false
    /// Codex reset banking: how many banked rate-limit resets the account can still redeem
    /// (nil = the provider doesn't report the concept).
    var resetCreditsAvailable: Int?
    /// When the soonest available banked reset expires (context for the redeem dialog).
    var resetCreditsNextExpiry: Date?

    /// The single metric to feature at a glance: the binding model-scoped window if the provider
    /// flags one, else any model-scoped window, else the unified weekly, else session. This is the
    /// "預設顯示最高級模型" headline.
    var headline: UsageMetric? {
        if let active = metrics.first(where: { $0.isActive && $0.isModelScoped }) { return active }
        if let scoped = metrics.first(where: { $0.isModelScoped }) { return scoped }
        if let weekly = metrics.first(where: { $0.kind == .weeklyAll }) { return weekly }
        return metrics.first
    }

    static func failure(account: ProviderAccount, providerID: String, message: String) -> AccountUsage {
        AccountUsage(id: account.id, providerID: providerID, accountLabel: account.label,
                     planName: nil, metrics: [], refreshedAt: Date(), error: message)
    }
}

/// A usage source. Implementations live under `Providers/<Name>/`.
protocol UsageProvider: Sendable {
    var id: String { get }
    var displayName: String { get }
    /// Local, cheap, no network: which accounts of this provider exist on this machine.
    func discoverAccounts() -> [ProviderAccount]
    /// Fetch live usage for one account. Must not throw - return `AccountUsage.failure` on error.
    ///
    /// `userInitiated` is true only when the user explicitly asked (clicked refresh). Providers use it
    /// to decide whether a credential read may raise an interactive prompt: background refreshes must
    /// not re-prompt a user who already declined, so they skip credential reads that previously failed.
    func fetchUsage(for account: ProviderAccount, userInitiated: Bool) async -> AccountUsage
}
