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
    /// Signed out, but the home is still on disk (KnownAccounts.swift). It keeps its home because
    /// that is what the login probe asks about and what "Renew login" acts on - and it must not
    /// keep the right to be LAUNCHED with, because there is no credential in there to run on.
    var isDormant: Bool = false

    /// The home a launch may use: the renewal's home, minus the accounts that have nothing to
    /// launch with. Every surface that steers a launch (the pin, the smart-pick badge, the usage
    /// snapshot the `tally` CLI reads) asks THIS rather than `launchHome`, so a signed-out account
    /// cannot be pinned into a launcher that would then exec a logged-out home.
    var launchableHome: String? { isDormant ? nil : launchHome }
}

/// The result of fetching one account's usage. Never thrown - failures are carried in `error` so one
/// dead account can't blank the whole popover.
struct AccountUsage: Identifiable, Hashable, Sendable {
    var id: String
    var providerID: String
    var accountLabel: String
    var planName: String?
    /// The signed-in email, when the provider can name it without touching a credential (Claude
    /// reads its plain config file, Codex asks its own app-server - `CodexIdentity.swift`). Shown
    /// as the account card's hover tooltip and on the face of the Settings account row, both
    /// through `LoginStatusStore.identityEmail` - never logged, never published to the snapshot.
    var accountEmail: String?
    var metrics: [UsageMetric]
    var refreshedAt: Date
    var error: String?
    /// WHY, WHERE THE PROVIDER COULD TELL, for the hover callout under the same triangle. `error`
    /// is the line the card DRAWS and its width is the card's, so a vendor's own sentence must not
    /// land in it; this is the half a reader asks for by hovering, and it is nil wherever the
    /// failure was already its own explanation (`CodexProvider.detail`).
    var errorDetail: String?
    /// True when these metrics are the last-good snapshot shown because the latest refresh failed.
    /// `error` then carries the reason (for a tooltip) while the numbers stay visible.
    ///
    /// DEBOUNCED BY TWO FAILURES so the badge does not flicker on a single missed poll, which makes
    /// it a statement about what is worth SHOWING rather than about what was fetched. Readers that
    /// need the second question ask `lastRefreshFailed` (`foldLastGood`, Core/LastGoodFold.swift).
    var isStale: Bool = false
    /// Whether this account's LATEST poll failed, set from the first failure with no debounce: the
    /// numbers beside it are then held over from an earlier round however fresh they look. The fact
    /// `isStale` cannot carry, because that one waits for a second failure on purpose.
    var lastRefreshFailed: Bool = false
    /// Whether this account's polls have gone on failing, over the same streak `isStale` waits for.
    ///
    /// THE FACT THAT DOES NOT MENTION NUMBERS, which is why it is not either field above: both of
    /// those describe the numbers on screen, so neither can speak for an account that has never had
    /// any. This one is true of a sustained failure whether or not there was ever a good round
    /// behind it, so it answers "is something wrong with this account" for both kinds at once.
    /// `foldLastGood` sets all three and says why the badge may not be reused for this.
    var pollsKeepFailing: Bool = false
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

    /// A failed poll still carries whatever the provider could establish WITHOUT the poll (Claude
    /// reads plan and email from a local config file), so a card that never fetched still names its
    /// account and a re-signed-in dir corrects itself while showing last-good numbers.
    static func failure(account: ProviderAccount, providerID: String, message: String,
                        planName: String? = nil, accountEmail: String? = nil,
                        errorDetail: String? = nil) -> AccountUsage {
        AccountUsage(id: account.id, providerID: providerID, accountLabel: account.label,
                     planName: planName, accountEmail: accountEmail,
                     metrics: [], refreshedAt: Date(), error: message, errorDetail: errorDetail)
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
