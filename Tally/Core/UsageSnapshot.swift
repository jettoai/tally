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
        /// The plan this account is subscribed to ("Max 20x", "Pro", "Team"), as the provider names
        /// it; nil when it does not say. Not a secret, and the CLI needs it: the usage advisor
        /// counts demand per plan tier, because one account-week of a $200 seat and of a $20 seat
        /// are not the same quantity.
        var plan: String?
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
        /// When THESE NUMBERS were fetched, which is not when the file was written: a republish
        /// rebuilds the document from the cached accounts and stamps `generatedAt` with the moment
        /// of the rewrite, so a settings toggle produces a brand-new file full of old readings
        /// (`republishSnapshot`, UsageStorePublishing.swift). A supervisor deciding whether a
        /// reading describes the wall its session just hit has to ask the account, not the file
        /// (`accountReadingPostdatesCap`, TallyCLI/CapDetection.swift).
        ///
        /// Carried straight off `AccountUsage.refreshedAt`, so it means the LAST SUCCESSFUL fetch:
        /// a failed poll keeps the last-good copy untouched (`applyLastGood`, UsageStore.swift),
        /// which is exactly the reading it dates.
        ///
        /// Optional because the schema only ever gains fields: a snapshot written by an older app
        /// decodes with nil, and a reader that needs the stamp treats nil as "cannot tell".
        var refreshedAt: Date?
        /// Whether THIS ACCOUNT's latest poll failed, published from the first failure with no
        /// debounce (`foldLastGood`, Core/LastGoodFold.swift). True means every number in this row
        /// is held over from an earlier round, however recent `refreshedAt` reads.
        ///
        /// Deliberately not `isStale`, which waits for a second consecutive failure so the badge
        /// does not flicker: the interval between the two failures publishes a row that reads as
        /// freshly fetched and is not, and the supervisor deciding inside it is the reader this
        /// field exists for (`accountIsSpent`, TallyCLI/AccountPick.swift).
        ///
        /// Optional, and false is written out rather than folded into nil: nil means the app that
        /// wrote this predates the field and cannot answer, which is a different sentence from "the
        /// last poll succeeded" and is read differently by anyone deciding on it.
        var lastRefreshFailed: Bool?
        /// When the soonest banked reset expires; nil when none is dated (see the next field).
        var resetCreditsNextExpiry: Date?
        /// True when at least one banked reset has no reported expiry; nil when the provider
        /// lists no credits at all. Never read "no date" as "no expiry".
        var resetCreditsExpiryUnknown: Bool?
        /// The account's reset state: "available", "used", "notSupported" or "unknown"
        /// (`ResetOffer.stateName`). nil from an app that predates the field.
        var resetState: String?
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
    /// provider has 2+ accounts) - `tally status`'s fleet line renders from this. Units match
    /// FleetPool: one account's full weekly window = 100.
    struct Fleet: Codable {
        var remaining: Double
        var capacity: Double
        /// When the pool runs dry at the measured pace (nil = sustainable or still measuring).
        var dryAt: Date?
        var sustainable: Bool
        /// Which pool this is when the gauge focus leads with a model pool ("Fable"); nil = the
        /// weekly pool. The CLI names the pool from this - the bare word "pool" silently
        /// changing meaning with the focus read as a wrong number. Added in 0.16.1 (optional, so
        /// older CLIs decode fine - the snapshot schema only ever gains fields).
        var poolName: String?
        /// The plan this pool covers when the provider's accounts are split by plan ("Pro"; "unknown"
        /// for accounts whose plan could not be read); nil = the whole provider. Optional, so older
        /// CLIs decode fine (the snapshot schema only ever gains fields).
        var plan: String? = nil
        /// One account of this pool's plan, in units of the vendor's lowest paid plan
        /// (`PlanWeight`); nil from an app that predates the field.
        var capacityWeight: Double? = nil
        /// How `capacityWeight` was established: "detected", "config" or "assumed".
        var weightSource: String? = nil
    }
    var fleet: [String: Fleet]?
    /// The panel's ordered pool list per provider (gauge focus applied app-side): every pool the
    /// fleet gauge shows, leading pool first - so `tally status` reports the same pools as the
    /// panel instead of just the headline. Added in 0.17 (optional; `fleet` keeps publishing the
    /// single headline pool for older CLIs - the snapshot schema only ever gains fields).
    var fleetPools: [String: [Fleet]]?
    /// Each provider's weekly remaining across all its plans, weighted by plan capacity
    /// (`FleetMath.weighted`): the one number to draw a provider's remaining from. Published for
    /// single-account providers too and whatever the gauge switch says; absent for a provider with
    /// no fresh weekly reading, and from apps that predate it (the schema only ever gains fields).
    struct Weighted: Codable {
        var remainingPercent: Double
        var weightSource: String
    }
    var fleetWeighted: [String: Weighted]?
    /// The account ids in the order the PANEL renders them, which is the user's own drag order
    /// (`SettingsStore.orderedAccountIDs`) and not the order `accounts` is written in.
    ///
    /// PUBLISHED BESIDE THE ACCOUNTS RATHER THAN APPLIED TO THEM, and that is a deliberate second
    /// best. Sorting `accounts` itself would have been one line and one source of truth - but that
    /// array's order is load-bearing for readers that resolve NEAR-TIES by taking the first
    /// candidate (`smartPick`, TallyCLI/AccountPick.swift, replaces its leader only on a margin),
    /// so reordering it would quietly change which account a launch lands on for a fleet whose
    /// scores are close. A surface that wants to mirror the panel applies this; everything else is
    /// untouched. Added in 0.38.7 (optional; older CLIs decode fine and keep snapshot order - the
    /// schema only ever gains fields).
    var accountOrder: [String]?

    static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".tally", isDirectory: true)
    static let fileURL = directory.appendingPathComponent("snapshot.json")

    /// Build from the store's merged account list + the per-account launch homes from discovery.
    /// `statuslineFullQuota` is handed in by the caller (SettingsStore is main-actor).
    static func make(accounts: [AccountUsage], launchHomes: [String: String],
                     statuslineFullQuota: Bool = false, displayMode: String? = nil,
                     fleet: [String: Fleet]? = nil, fleetPools: [String: [Fleet]]? = nil,
                     fleetWeighted: [String: Weighted]? = nil,
                     accountOrder: [String]? = nil, resetStates: [String: String] = [:],
                     now: Date = Date()) -> UsageSnapshot {
        UsageSnapshot(
            generatedAt: now,
            accounts: accounts.map { usage in
                Account(
                    id: usage.id,
                    provider: usage.providerID,
                    label: usage.accountLabel,
                    plan: usage.planName,
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
                    error: usage.error,
                    refreshedAt: usage.refreshedAt,
                    lastRefreshFailed: usage.lastRefreshFailed,
                    resetCreditsNextExpiry: usage.resetCreditsNextExpiry,
                    resetCreditsExpiryUnknown: usage.resetCredits == nil && usage.resetCreditsAvailable == nil
                        ? nil : usage.resetCreditsExpiryUnknown,
                    resetState: resetStates[usage.id]
                )
            },
            statuslineFullQuota: statuslineFullQuota,
            displayMode: displayMode,
            fleet: fleet,
            fleetPools: fleetPools,
            fleetWeighted: fleetWeighted,
            accountOrder: accountOrder
        )
    }

    /// Serial, so writes land in the order they were issued and a later snapshot is never
    /// overwritten by an earlier one.
    private static let writeQueue = DispatchQueue(label: "ai.jetto.tally.snapshot-write", qos: .utility)

    /// Atomic write; failures are silently ignored (the snapshot is a convenience export - it must
    /// never break the app's own refresh loop). Encoding and file IO run on a serial background
    /// queue because a mkdir on the main thread once stalled refresh for 2 seconds on a busy disk
    /// (TALLY-1G).
    func write() {
        let snapshot = self
        Self.writeQueue.async {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            guard let data = try? encoder.encode(snapshot) else { return }
            try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
            try? data.write(to: Self.fileURL, options: .atomic)
        }
    }
}
