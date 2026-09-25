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

    /// WHOSE MARK THIS IS, for the first line of a status mark's callout: a triangle hovered in a
    /// list of eight rows has to answer that before its sentence means anything, and the identity
    /// it belongs to is at the far end of the row. The signed-in address when there is one, because
    /// two accounts can share a nickname and never a login; the row's own name otherwise (a demo
    /// fixture, or an account no probe has named yet).
    ///
    /// The line ABOVE the sentence rather than glued to its front, which is the shape every other
    /// callout in the panel already has (`tallyTooltip(_:detail:)`).
    var markOwner: String { identityEmail.isEmpty ? label : identityEmail }

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

    /// Whether this is the account the user is also signed into on claude.ai, and the slice of each
    /// shared window Tally's own choices must leave standing (0 on every other account; which
    /// windows that covers is `PersonalAccount.reserved`, and the meters ask it per bar). Both
    /// through
    /// `PersonalAccount`, which is where the fixtures and the "Claude only" rule live, so no surface
    /// carries a demo branch of its own.
    var isPersonalAccount: Bool {
        PersonalAccount.isPersonal(accountID: usage.id, home: identityHome)
    }

    var reservePercent: Int {
        PersonalAccount.reserve(accountID: usage.id, home: identityHome)
    }

    /// Which window is this account's headline one, asked once for every surface that has to tell
    /// it apart from the rest. Two do: the split below, and the water line - the reserve reaches
    /// the account's FLAGSHIP model window and not the other tiers "show every model tier" reveals
    /// (`PersonalAccount.reserved`), and the flagship one is this.
    var headlineID: String? { usage.headline?.id }

    /// Non-headline windows. Model-scoped rows are hidden unless "show every model tier" is on, so
    /// by default only the highest-tier model (the headline) is featured.
    var secondaryMetrics: [UsageMetric] {
        let headlineID = self.headlineID
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

    /// Whether the "Outdated" mark is this account's to show. An EXPIRED LOGIN is why the numbers
    /// stopped moving, and it already carries a mark of its own beside this one: drawing both puts a
    /// cause and its own symptom side by side, in two shades of the same warning, and leaves the
    /// reader to work out they are one thing (owner's report, 2026-08-24). The login mark wins; this
    /// one stands down and comes back with the login.
    ///
    /// A RENEWAL IN FLIGHT IS NOT THAT, and deliberately does not suppress it (codex review,
    /// 2026-08-24). "Renew login…" is offered on every account with a config home
    /// (`AccountCardMenu`), so a renewal running says nothing about why a reading went stale: a rate
    /// limit or a dropped network is not the login, and hiding the only warning about it would be
    /// hiding a second, unrelated fact. A spinner and a warning triangle side by side is then
    /// exactly right, because two things really are true.
    ///
    /// Here rather than in either surface, like every other answer in this file: a card that spelled
    /// out "Outdated" while the row beside it did not would be two answers to one question.
    var showsStaleMark: Bool { usage.isStale && !isLoginExpired }

    /// The plan exposes only a single weekly window (e.g. Codex on ChatGPT Plus) - worth noting so a
    /// missing session/model row doesn't read as a bug.
    var isWeeklyOnly: Bool {
        usage.metrics.count == 1 && usage.metrics.first?.kind == .weeklyAll
    }

    // MARK: What this account has to spend

    /// Which reset this account carries, if any, asked in one place so the card and the compact row
    /// cannot come to offer different things (`RedeemAction.Offer` states what the two are).
    var resetOffer: RedeemAction.Offer { RedeemAction.offer(for: usage) }

    /// A Claude account whose reset count Tally cannot read and whose control is not offered as a
    /// press (`offersSessionLimitReset`): its mark opens claude.ai's usage page instead. No state
    /// names a count; the "1" it used to draw came from assuming one a week.
    var opensClaudeUsagePage: Bool {
        guard case .claudeSessionLimit(let state) = resetOffer else { return false }
        return state != .used && !offersSessionLimitReset
    }

    /// Whether the control is the "Reset session limit" press rather than the claude.ai pointer:
    /// this login's CLI takes a typed `/limit-reset` and its 5-hour window is full
    /// (`limitResetOffered`). Offered but without a session it is drawn greyed, never as the pointer.
    var offersSessionLimitReset: Bool {
        guard case .claudeSessionLimit(let state) = resetOffer else { return false }
        let session = usage.metrics.first { $0.kind == .session }
        return limitResetOffered(state: state,
                                 pathOpen: LimitResetStore.shared.pressPathOpen(accountID: usage.id),
                                 windowFull: (session?.usedPercent ?? 0) >= 100)
    }

    /// The expiry beside a Codex banked-reset count: "until <date>", "expires in 2d" inside a week,
    /// and "expiry unknown" for any credit nobody dated (never read as "no expiry").
    func resetExpiryNote(now: Date = Date()) -> String? {
        var parts: [String] = []
        if let expiry = usage.resetCreditsNextExpiry {
            let left = expiry.timeIntervalSince(now)
            parts.append(ResetExpiryUrgency.of(expiry, now: now) == .distant
                ? String(format: L("until %@"), UsageFormat.absoluteBody(expiry))
                : String(format: L("expires in %@"), UsageFormat.durationBody(max(60, left))))
        }
        if usage.resetCreditsExpiryUnknown { parts.append(L("expiry unknown")) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Warning colour inside 48 hours of the soonest expiry, critical inside 6.
    func resetExpiryColor(now: Date = Date()) -> Color? {
        switch ResetExpiryUrgency.of(usage.resetCreditsNextExpiry, now: now) {
        case .soon: return TallyColor.warning
        case .final: return TallyColor.critical
        case .unknown, .distant, .thisWeek: return nil
        }
    }

    /// Hover text for a Codex account whose resets could not be read this round.
    var codexResetUnknownHelp: String { L("Couldn't read resets this round") }

    /// The "signed in as" line under a claude.ai pointer: the browser may be signed in to a
    /// different Claude account than this card's.
    private var claudeAccountLine: String {
        identityEmail.isEmpty ? "" : "\n" + String(format: L("This card is %@."), identityEmail)
    }

    /// When this account's weekly session-limit reset comes back, where a sentence named a date.
    var limitResetNextAt: Date? { LimitResetStore.shared.nextAvailableAt(accountID: usage.id) }

    /// The supervised session Tally would type `/limit-reset` into, or nil when there is none.
    var limitResetSession: LimitResetTarget? { LimitResetStore.shared.target(accountID: usage.id) }

    /// Whether pressing the session-limit control would actually do anything.
    ///
    /// THREE THINGS HAVE TO BE TRUE and each of them fails visibly rather than silently: the press
    /// has to be offered (`offersSessionLimitReset`), there has to be a session to type it into (the
    /// command is interactive-only), and no press already in flight. A demo fixture is excluded on
    /// the rule the whole file keeps - it has no session, so every such affordance stays greyed.
    var canResetSessionLimit: Bool {
        limitResetPressable(offered: offersSessionLimitReset, hasSession: limitResetSession != nil,
                            busy: isResettingSessionLimit, demo: DemoUsage.isActive)
    }

    var isResettingSessionLimit: Bool { LimitResetStore.shared.pending.contains(usage.id) }

    /// What the last press came to, for the few seconds a card shows it.
    var limitResetOutcome: LimitResetStore.LimitResetSpend? {
        LimitResetStore.shared.lastOutcome[usage.id]
    }

    /// The one line the control shows. An offered press says what it does and names no count.
    /// Otherwise `available`, `notEnabled` and `unknown` share one line that names no number: Tally
    /// has no trustworthy read of the count in any of them. That press opens claude.ai's usage page,
    /// the one place those resets are listed.
    func limitResetLabel(_ state: LimitResetState) -> String {
        if offersSessionLimitReset { return L("Reset session limit") }
        switch state {
        case .used:
            guard let back = limitResetNextAt else { return L("Reset used") }
            return L("Reset used") + " · " + String(format: L("back %@"),
                                                    AppLocale.shortDateTime(back))
        case .available, .notEnabled, .unknown:
            return L("Reset status unknown · Check on Claude")
        }
    }

    /// What hovering it says: that a used reset is spent, or, for every other state, why Tally names
    /// no count and which account to check on claude.ai.
    func limitResetHelp(_ state: LimitResetState) -> String {
        if offersSessionLimitReset {
            return limitResetSession == nil
                ? L("Open a session on this account to use its reset")
                : L("Clears this account's 5-hour session limit now. Claude Code says it counts toward the weekly limit. This cannot be undone.")
        }
        switch state {
        case .used:
            return L("This account has already used its reset this week.")
        case .available, .notEnabled, .unknown:
            return L("Tally can't read how many resets this account has or when they expire.")
                + "\n" + L("claude.ai is a separate sign-in in your browser. Check which account it shows before you use a reset there.")
                + claudeAccountLine
        }
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

    var sessionLoginProblems: [LoginHealthSession] { LoginHealthStore.shared.problems(usage.id) }
    var loginExpiryState: ClaudeLoginExpiry.State { LoginHealthStore.shared.expiryState(usage.id) }

    var isLoginExpired: Bool { LoginStatusStore.shared.isExpired(usage.id) }
}
