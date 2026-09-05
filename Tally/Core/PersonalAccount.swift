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

    /// Whether a reserve is held back from a window of this kind, so the meters draw the water line
    /// exactly where the launcher applies it.
    ///
    /// ASKED OF THE RULING ITSELF (`AccountRoles.carriesReserve`, Tally/Core/AccountReserve.swift)
    /// rather than re-spelled here as a list of kinds. That file cannot name a `MetricKind` (the CLI
    /// target compiles it and has no such type), so the translation into the app's vocabulary lives
    /// here and the SCOPE stays over there, in the one place both burn-rate mirrors already read it.
    /// A hatch on a window no pick treats as reserved would draw a line nothing enforces - which is
    /// worse than drawing none, the bar being the only place the user ever sees what the number
    /// does.
    ///
    /// THE FLAGSHIP BAR CARRIES ONE WITHOUT THE METER KNOWING WHICH MODEL A PROJECT DECLARED, which
    /// is the one reading here that is not a straight translation. A launch rates that window unless
    /// the project's primary model is another tier, and a project on another tier does not spend the
    /// window either, so the line the hatch promises holds on both branches.
    ///
    /// AND `isHeadline` IS WHY A KIND IS NOT ENOUGH. "Show every model tier" puts the account's
    /// OTHER model windows on the card and in the row (`AccountFacts.secondaryMetrics`), and they
    /// are the same `.weeklyModel` kind as the flagship one. The launcher never sees them: the
    /// snapshot publishes exactly one model window per account, the headline one
    /// (`UsageSnapshot`, `Snapshot.Account.modelWindowName`). So a line drawn on a secondary tier
    /// is a line no pick enforces - the failure this whole reading exists to prevent, arrived at
    /// from the other side (codex review, 2026-09-05).
    ///
    /// ASKED AS A FACT AND NOT READ OFF THE STYLING, which is the trap here: the card marks its
    /// headline row `prominent`, and that flag is one refactor away from meaning something else.
    /// A styling flag that drifts would put the hatch back on unprotected bars silently, so the
    /// caller states the identity (`metric.id == headline?.id`) instead.
    static func reserved(_ kind: MetricKind, isHeadline: Bool) -> Bool {
        AccountRoles.carriesReserve(window: windowName(kind),
                                    isModelWindow: kind == .weeklyModel && isHeadline)
    }

    /// This window's name in the launcher's vocabulary, and nil where it has none: a per-model
    /// window is named after its model, which is why the ruling recognises it by shape instead, and
    /// `other` is a kind the launcher does not rate at all.
    private static func windowName(_ kind: MetricKind) -> String? {
        switch kind {
        case .session: return AccountRoles.sessionWindowName
        case .weeklyAll: return AccountRoles.weeklyWindowName
        case .weeklyModel, .other: return nil
        }
    }

    /// The slice of each shared window Tally's own choices must leave standing, 0 for every account
    /// that is not the marked one.
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
