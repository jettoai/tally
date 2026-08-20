import Foundation

/// WHICH ACCOUNT IS THE PERSONAL ONE, asked by every surface through here.
///
/// Three of them ask: the Settings row that carries the marking and its stepper, the account card's
/// meters, and the compact list row's. They must never ANSWER differently - a bar drawing a water
/// line for an account the pane says is not marked is two answers to one question, and the user has
/// no way to tell which is the true one (the reasoning `AccountFacts` opens with, one level down).
///
/// AND IT IS WHERE THE FIXTURES LIVE, which is the other reason it is one function rather than three
/// call sites: a demo launch has no config homes at all (`DemoUsage.launchHome` is the only thing
/// that names one), so every surface would otherwise need its own demo branch, and the capture that
/// shows this feature would show it on whichever surfaces happened to get one.
///
/// A demo launch NEVER WRITES, the same rule the rest of the fixtures follow: the marking lives in
/// `~/.tally/state.json`, which is the file the real `tally` CLI steers launches by.
@MainActor
enum PersonalAccount {
    /// The config home a marking would be stored under, or nil when Tally has none to name.
    ///
    /// The IDENTITY home rather than the one an action touches: a demo fixture deliberately has no
    /// launchable directory (so every affordance that would move a real folder stays greyed), and
    /// naming one is not touching one.
    static func home(accountID: String, launchHome: String?) -> String? {
        DemoUsage.launchHome(accountID: accountID) ?? launchHome
    }

    /// Whether this account is the one the user browses claude.ai on.
    static func isPersonal(accountID: String, home: String?) -> Bool {
        if DemoUsage.isActive { return accountID == DemoUsage.personalAccountID }
        return LaunchPolicyStore.shared.isPersonalAccount(home: home)
    }

    /// The slice of its quota Tally's own choices must leave standing, 0 for every account that is
    /// not the marked one.
    static func reserve(accountID: String, home: String?) -> Int {
        if DemoUsage.isActive {
            return accountID == DemoUsage.personalAccountID ? DemoUsage.personalReserve : 0
        }
        return LaunchPolicyStore.shared.reserve(home: home)
    }

    /// Every account's reserve keyed by ACCOUNT ID, which is what the smart-pick badge ranks the
    /// fleet with (`LaunchPolicyStore.autoPickID`). The join lives here rather than at the badge,
    /// because this is already the file that knows how to answer the question for a fixture as well
    /// as for a real account - so the capture shows the badge the same rules put it on.
    ///
    /// THE LAUNCHABLE HOME, matching what the app publishes to the snapshot the CLI reads
    /// (`UsageStore`): a signed-out account is not a launch target, and steering by a home nothing
    /// can launch is the mismatch the badge exists to avoid. Accounts reserving nothing are left out
    /// entirely, so an unmarked fleet hands the pick an empty map and computes what it always did.
    static func reserves(_ accounts: [AccountUsage],
                         discovered: [ProviderAccount]) -> [String: Double] {
        var homes: [String: String] = [:]
        for account in discovered where account.launchableHome != nil {
            homes[account.id] = account.launchableHome
        }
        var byID: [String: Double] = [:]
        for usage in accounts {
            let percent = reserve(accountID: usage.id, home: homes[usage.id])
            if percent > 0 { byID[usage.id] = Double(percent) }
        }
        return byID
    }

    /// Whether the marking can be offered at all.
    ///
    /// CLAUDE ONLY, because both things hanging off the marking are: artifacts are a Claude Code
    /// tool, and a Codex account has no browser session sharing its quota (the reserve's whole
    /// premise). A row offering it for Codex would be a control that changes nothing.
    ///
    /// And it needs a home to store the marking under - which a demo fixture has, since `home` above
    /// names one, so a capture shows this row exactly as a real machine draws it.
    static func canMark(providerID: String, home: String?) -> Bool {
        providerID == "claude" && home?.isEmpty == false
    }

    /// Mark this account, or unmark it when it already holds the marking. One control, both
    /// directions, like the pin circle it sits beside in spirit.
    static func toggle(accountID: String, home: String?) {
        // A capture must never edit the machine it is photographing.
        guard !DemoUsage.isActive, let home else { return }
        let policy = LaunchPolicyStore.shared
        policy.setPersonalAccount(policy.isPersonalAccount(home: home) ? nil : home)
    }
}
