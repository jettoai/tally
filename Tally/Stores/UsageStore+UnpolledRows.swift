import Foundation

// The rows a refresh lists without polling, split out of UsageStore.swift (line limit): a dormant
// account, and a home signed into another home's Claude account (jettoai/tally#6,
// Core/SharedLogin.swift), which the refresh takes out before it polls.

/// One round's duplicates: duplicate id → kept id, and each duplicate home with what its config
/// file said (plan and email for its row; the login's identity is not kept).
struct SharedLoginRound {
    var kept: [String: String] = [:]
    var homes: [(account: ProviderAccount, plan: String?, email: String?)] = []
    /// Default label of every Claude home read this round, for the message's names.
    var labels: [String: String] = [:]
    /// Homes whose config named nobody when this round split them, so a name the poll found later
    /// is not written to memory before a split has seen it (B-1702; see UsageStore.refresh).
    var unnamedBeforePoll: Set<String> = []
}

extension UsageStore {
    /// A dormant account gets a row rather than a fetch: there is no credential left to fetch
    /// with, and a card is where its "Login expired" chip lives. Kept out of `results` so an
    /// account that stays signed out cannot hold the failure-retry ladder open for as long as
    /// it does.
    func dormantRows(_ dormant: [ProviderAccount], enabledProviders: Set<String>) -> [AccountUsage] {
        dormant
            .filter { enabledProviders.contains($0.providerID) && SettingsStore.shared.isAccountEnabled($0.id) }
            .map { AccountUsage.failure(account: $0, providerID: $0.providerID,
                                        message: L("Login expired")) }
    }

    /// Reads each active Claude home's login before the poll, so a duplicate is neither polled (its
    /// numbers would be the kept account's again) nor handed a launch home: the snapshot then lists
    /// it the way the CLI already reads as not launchable (an error and no home), and the pick,
    /// `tally account`, a pin, every move and the fleet totals skip it without a check of their own.
    func splitSharedLogins(_ active: [ProviderAccount]) async
        -> (active: [ProviderAccount], round: SharedLoginRound) {
        let profiles = await Task.detached(priority: .utility) {
            active.map { account in
                (account, account.launchHome.map { ClaudeAccounts.profile(configDir: $0) }
                    ?? ClaudeAccounts.Profile())
            }
        }.value
        let identities = LoginStatusStore.shared
        let kept = SharedLogin.duplicates(profiles.map { account, profile in
            SharedLogin.Home(id: account.id, identity: profile.accountUUID,
                             rememberedEmail: identities.rememberedEmail(account.id),
                             currentEmail: profile.email)
        })
        // A duplicate's email is the kept account's: written into its memory, the next round would
        // read both homes as unchanged and could hand the kept side to the re-signed home.
        identities.sharedLoginDuplicates = Set(kept.keys)
        var round = SharedLoginRound(kept: kept)
        round.homes = profiles.filter { kept[$0.0.id] != nil }.map { ($0.0, $0.1.plan, $0.1.email) }
        round.labels = Dictionary(active.map { ($0.id, $0.label) }, uniquingKeysWith: { a, _ in a })
        round.unnamedBeforePoll = Set(profiles.filter { $0.1.email == nil }.map(\.0.id))
        return (active.filter { kept[$0.id] == nil }, round)
    }

    /// A duplicate gets a row rather than a fetch, like a dormant account, and stays out of the
    /// last-good fold: numbers held over on it would put the kept account's quota back into every
    /// total. The refresh drops its last-good too, so the first poll after the login is fixed
    /// starts clean.
    func sharedLoginRows(_ round: SharedLoginRound, enabledProviders: Set<String>) -> [AccountUsage] {
        round.homes
            .filter { enabledProviders.contains($0.account.providerID)
                && SettingsStore.shared.isAccountEnabled($0.account.id) }
            .map { home in
                let keptID = round.kept[home.account.id] ?? home.account.id
                var row = AccountUsage.failure(
                    account: home.account, providerID: home.account.providerID,
                    message: Self.sharedLoginMessage(
                        SharedLogin.group(keptID: keptID, duplicates: round.kept),
                        defaultLabel: { round.labels[$0] }),
                    planName: home.plan, accountEmail: home.email,
                    errorDetail: Self.sharedLoginDetail)
                row.sameAccountAs = keptID
                return row
            }
    }

    /// `-TallyDemoSharedLogin YES` (with `-TallyDemoData`): Claude 3 reads as a home signed into
    /// Claude 2's login, shaped by the same row builder a real round uses, so a capture shows both
    /// notices. Off by default: the README grid keeps every card's numbers.
    func demoSharedLogin(_ rows: [AccountUsage]) -> [AccountUsage] {
        let (kept, duplicate) = ("claude:demo-Claude 2", "claude:demo-Claude 3")
        guard UserDefaults.standard.bool(forKey: "TallyDemoSharedLogin"),
              let usage = rows.first(where: { $0.id == duplicate }) else { return rows }
        var round = SharedLoginRound(kept: [duplicate: kept])
        round.homes = [(ProviderAccount(id: duplicate, providerID: usage.providerID,
                                        label: usage.accountLabel, locator: [:], launchHome: nil),
                        usage.planName, usage.accountEmail)]
        round.labels = Dictionary(rows.map { ($0.id, $0.accountLabel) }, uniquingKeysWith: { a, _ in a })
        let shaped = sharedLoginRows(round, enabledProviders: [usage.providerID])
        return rows.map { $0.id == duplicate ? (shaped.first ?? $0) : $0 }
    }

    /// The hover half of both notices: what to do about it.
    static var sharedLoginDetail: String {
        L("Tally counts this login once and launches only on the first of these homes. To use this home's own subscription, run /login in it with that account.")
    }

    /// "AM and GM are signed into the same Claude account", every home of one login by its display
    /// label, kept account first. Shared by the duplicate's row and the kept card's notice.
    static func sharedLoginMessage(_ ids: [String], defaultLabel: (String) -> String?) -> String {
        let labels = ids.map {
            SettingsStore.shared.displayLabel(accountID: $0, fallback: defaultLabel($0) ?? $0)
        }
        let formatter = ListFormatter()
        formatter.locale = AppLocale.current
        let list = formatter.string(from: labels) ?? labels.joined(separator: ", ")
        return String(format: L("%@ are signed into the same Claude account"), list)
    }
}
