import Foundation

/// Persisting `UsageStore.lastGood` across launches (Core/LastGoodCache.swift). The two assignments
/// that need the store's private setters stay in UsageStore.swift; everything else is here.
extension UsageStore {
    static let lastGoodCacheKey = "ai.jetto.tally.lastGoodUsage"

    /// Config home per cached account and the rows last written, so a refresh that changed nothing
    /// writes nothing and `forgetAccount` (which has no discovery list) can still rewrite.
    private static var cacheHomes: [String: String] = [:]
    private static var cacheWritten: [LastGoodCache.Row] = []

    /// The rows and last-good readings to start with: last launch's, or nothing. Called once, from
    /// `UsageStore.init`, so the first frame already has the account list. The first refresh round
    /// is user-initiated (every account is probed), replaces each row in place as its probe lands,
    /// and drops any row discovery no longer finds when it commits.
    static func cachedLastGood() -> (rows: [AccountUsage], lastGood: [String: AccountUsage]) {
        guard !DemoUsage.isActive else { return ([], [:]) }
        let settings = SettingsStore.shared
        let seed = LastGoodCache.seed(
            LastGoodCache.decode(UserDefaults.standard.data(forKey: lastGoodCacheKey)), now: Date(),
            // No stat of the homes here: this runs on the main thread inside init (tests/mainio). A row
            // whose account is gone ends at the first refresh commit, which carries over only
            // accounts discovery still lists (`carriedAccountRows`).
            homeExists: { _ in true },
            isShown: { settings.enabledProviders.contains($0) && settings.isAccountEnabled($1) })
        cacheHomes = seed.homes
        cacheWritten = LastGoodCache.rows(seed.lastGood, homes: seed.homes)
        ProbeCadence.log.notice("seeded rows=\(seed.rows.count, privacy: .public) cached=\(seed.lastGood.count, privacy: .public)")
        return (seed.rows, seed.lastGood)
    }

    /// Writes the cache when it changed. `known` refreshes the home table; nil keeps the last one.
    /// On disk only for an app that owns its defaults domain: a build nobody installed carries the
    /// release bundle id and would write into the INSTALLED app's. `Tally Dev.app` has its own
    /// domain (".dev" bundle id), so it is allowed here, unlike KnownAccountsStore, so the restart
    /// behaviour can be checked on it.
    func persistLastGood(_ lastGood: [String: AccountUsage], known: [ProviderAccount]?) {
        guard !DemoUsage.isActive, !BuildVariant.isUnshipped || BuildVariant.isDev else { return }
        if let known {
            Self.cacheHomes = Dictionary(known.compactMap { account in account.launchHome.map { (account.id, $0) } },
                                         uniquingKeysWith: { first, _ in first })
        }
        let rows = LastGoodCache.rows(lastGood, homes: Self.cacheHomes)
        guard rows != Self.cacheWritten,
              let data = LastGoodCache.encode(rows: rows, savedAt: Date()) else { return }
        UserDefaults.standard.set(data, forKey: Self.lastGoodCacheKey)
        Self.cacheWritten = rows
    }
}
