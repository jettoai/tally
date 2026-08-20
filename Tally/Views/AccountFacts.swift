import SwiftUI

/// Everything both account surfaces have to ask about one account: which config home an action
/// would touch, whether the login is still good, who is signed in, which windows to show, and which
/// launch affordances apply. The full card (`AccountCardView`) and the compact list row
/// (`AccountListRowView`) draw very differently but must never ANSWER differently: a row that greys
/// an action the card offers, or marks a different account as the smart pick, is two answers to one
/// question and the user has no way to tell which is the true one.
///
/// A value built on the spot rather than stored state: every property here reads a shared store, so
/// holding one would only be a chance to hold a stale copy.
@MainActor
struct AccountFacts {
    let usage: AccountUsage
    let settings: SettingsStore

    /// The user-facing name: the nickname when there is one, the discovered label otherwise.
    var label: String {
        settings.displayLabel(accountID: usage.id, fallback: usage.accountLabel)
    }

    /// This account as discovery (plus the dormant memory) knows it: where the homes and the
    /// dormancy behind the launch affordances come from.
    var discovered: ProviderAccount? {
        UsageStore.shared.discoveredAccounts.first { $0.id == usage.id }
    }

    /// The account's config home, or nil when Tally has none to act on (a demo fixture, or an
    /// account discovered without a launchable directory) - which is what greys the expiry chip and
    /// both context-menu entries (AccountCardMenu). The RENEWAL home: a signed-out account keeps it,
    /// which is exactly what "Renew login" acts on.
    var configHome: String? { discovered?.launchHome }

    /// Signed out with its config home still on disk: listed and renewable, never launchable.
    var isDormant: Bool { discovered?.isDormant == true }

    /// Who is signed in, for the identity tooltip. The ordering (the probe's live answer first, the
    /// provider's config-derived copy as the fallback) lives in the store, because the Settings row
    /// asks the same question and the two must not drift apart. Empty string, not nil: this feeds a
    /// tooltip, and an absent one is what "nothing to say" looks like there.
    var identityEmail: String { LoginStatusStore.shared.identityEmail(usage) ?? "" }

    /// The second line of that tooltip: the plan and the config home, which is what tells two cards
    /// apart when the address cannot (one ChatGPT address in two workspaces answers with the same
    /// email on both - see `AccountIdentity.detail`, which owns the rule and the reason).
    var identityDetail: String? {
        AccountIdentity.detail(plan: usage.planName, home: identityHome)
    }

    /// The home that line NAMES, which is not the same question as `configHome`: that one is the
    /// home an action would touch, and it is deliberately nil for a demo fixture so every affordance
    /// that would move a real folder stays greyed. Naming one is not touching one, and a marketing
    /// shot of this feature has to show the very thing it is about.
    var identityHome: String? {
        DemoUsage.launchHome(accountID: usage.id) ?? configHome
    }

    /// Hold the identity callout open with no pointer, for a design capture. Exactly ONE fixture,
    /// because every card carries this target and forcing them all would leave the capture showing
    /// whichever the layout traversal reached last (`TallyTooltip.previewForced`).
    var forcesIdentityTooltip: Bool {
        TallyTooltip.previewForced(.identity) && usage.id == DemoUsage.tooltipPreviewAccountID
    }

    /// Whether this is the account the user is also signed into on claude.ai, and the slice of its
    /// WEEK Tally's own choices must leave standing (0 on every other account; which window that
    /// covers is `PersonalAccount.reserved`, and the meters ask it per bar). Both through
    /// `PersonalAccount`, which is where the fixtures and the "Claude only" rule live, so no surface
    /// carries a demo branch of its own.
    var isPersonalAccount: Bool {
        PersonalAccount.isPersonal(accountID: usage.id, home: identityHome)
    }

    var reservePercent: Int {
        PersonalAccount.reserve(accountID: usage.id, home: identityHome)
    }

    /// Non-headline windows. Model-scoped rows are hidden unless "show every model tier" is on, so
    /// by default only the highest-tier model (the headline) is featured.
    var secondaryMetrics: [UsageMetric] {
        let headlineID = usage.headline?.id
        return usage.metrics.filter { metric in
            guard metric.id != headlineID else { return false }
            if metric.isModelScoped && !settings.showAllModels { return false }
            return true
        }
    }

    /// Every window to show, headline first: the order the card reads top to bottom, and the order
    /// the row reads left to right.
    var orderedMetrics: [UsageMetric] {
        (usage.headline.map { [$0] } ?? []) + secondaryMetrics
    }

    /// A hard error (this account has never loaded) collapses to a compact error + Retry. A stale
    /// account (a failed refresh over previously-good numbers) keeps its metrics readable - the
    /// "Outdated" badge carries the state, so the numbers aren't dimmed away.
    var isHardError: Bool { usage.error != nil && !usage.isStale }

    /// The plan exposes only a single weekly window (e.g. Codex on ChatGPT Plus) - worth noting so a
    /// missing session/model row doesn't read as a bug.
    var isWeeklyOnly: Bool {
        usage.metrics.count == 1 && usage.metrics.first?.kind == .weeklyAll
    }

    /// A reset was just redeemed here and the provider is still serving the spent numbers. The rows
    /// then say the reset is landing instead of "Limit reached", which alongside the green "Reset
    /// redeemed" line read as a redeem that did nothing.
    var isSettlingReset: Bool { RedeemPropagationStore.shared.isSettling(usage) }

    // MARK: Launch policy affordances (multi-account providers only)

    /// Sibling count decides whether launch affordances appear at all - with one account there is
    /// nothing to choose.
    var hasSiblings: Bool {
        UsageStore.shared.accounts.filter { $0.providerID == usage.providerID }.count > 1
    }

    var launchMode: LaunchPolicyStore.Mode {
        // Demo fixtures always demonstrate Smart mode (the real policy's pinned ids can never match
        // demo accounts, which would leave every marketing card badge-less).
        DemoUsage.isActive ? .auto : LaunchPolicyStore.shared.mode(usage.providerID)
    }

    var isPinnedActive: Bool {
        LaunchPolicyStore.shared.isPinned(usage.id, providerID: usage.providerID)
    }

    /// Whether auto mode would launch THIS account right now (the panel predicts the CLI).
    ///
    /// AND IT WEIGHS THE RESERVES, because the launcher does: a badge ranking on raw percentages
    /// would sit on the personal account while `tally` spent a sibling instead, which is the drift
    /// this prediction exists not to have. Only reached in auto mode - a pinned card wears the
    /// pinned badge (`AccountCardView`), and nothing on that path asks a reserve anything.
    var isAutoPick: Bool {
        let store = UsageStore.shared
        let launchable = DemoUsage.isActive
            ? Set(store.accounts.map(\.id))   // fixtures are all "launchable" for the demo
            : Set(store.discoveredAccounts.compactMap { $0.launchableHome != nil ? $0.id : nil })
        return LaunchPolicyStore.shared.autoPickID(
            providerID: usage.providerID, accounts: store.accounts, launchable: launchable,
            reserves: PersonalAccount.reserves(store.accounts,
                                               discovered: store.discoveredAccounts)) == usage.id
    }

    /// The one switch both surfaces offer: hollow circle pins this account, checked releases it back
    /// to Smart.
    func togglePin() {
        let policy = LaunchPolicyStore.shared
        if isPinnedActive {
            policy.setMode(usage.providerID, .auto)
        } else {
            policy.pin(usage.providerID, accountID: usage.id, home: discovered?.launchableHome)
        }
    }

    /// A signed-out account cannot BECOME the launch account: pinning is denormalized into the
    /// policy file the CLI reads, so a pinned dormant home would have `tally` exec a logged-out
    /// directory long after the panel forgot why.
    ///
    /// Releasing an existing pin stays available, though - that is the opposite direction. An
    /// account pinned BEFORE it signed out is exactly the one the user needs to unpin, and disabling
    /// the only control that does it left the choice stuck until the login came back.
    var canTogglePin: Bool { !(isDormant && !isPinnedActive) }

    /// What the circle does from where it is now - all four states, because a pinned dormant card is
    /// a real one and reads wrong under either of the other two sentences.
    var pinToggleHelp: String {
        switch (isPinnedActive, isDormant) {
        case (true, true):
            L("Pinned but signed out: launches pick by headroom until the login is renewed. Click to unpin.")
        case (true, false): L("Pinned. Click again to go back to Smart.")
        case (false, true): L("Signed out: renew the login before launching with this account.")
        case (false, false): L("Set as launch account")
        }
    }

    /// The consequence AND the why - the binding quota window and its reset - so the pick never
    /// looks arbitrary.
    var smartPickTooltip: String {
        let base = L("Smart: new sessions start on the account whose quota goes furthest right now.")
        let primary = LaunchPolicyStore.shared.policy(usage.providerID).model
        guard let reason = LaunchPolicyStore.smartReason(usage, primaryModel: primary) else {
            return base
        }
        return base + "\n" + reason
    }

    /// Whether this account can start a login renewal right now (a demo fixture cannot: it has no
    /// config home behind it).
    var canRenewLogin: Bool {
        RenewLoginStore.shared.canRenew(accountID: usage.id, providerID: usage.providerID,
                                        home: configHome)
    }

    var isRenewingLogin: Bool { RenewLoginStore.shared.isRenewing(usage.id) }

    var isLoginExpired: Bool { LoginStatusStore.shared.isExpired(usage.id) }
}
