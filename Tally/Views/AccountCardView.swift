import SwiftUI

/// One account's card: provider + account label + plan, the headline (top-tier) meter prominent,
/// then the remaining windows below. Nested spacing gives the account identity, its headline, and its
/// secondary windows distinct rhythm rather than one flat stack.
struct AccountCardView: View {
    let usage: AccountUsage
    @Bindable var settings: SettingsStore
    /// Show a grip glyph on hover - the drag-affordance for surfaces where the card can be reordered.
    var showsDragHandle: Bool = false
    /// Full-brightness handle regardless of hover - the floating drag preview sets this, so the
    /// grip never blinks out mid-drag.
    var handleProminent: Bool = false
    /// Stretch the card surface to fill the row height, so side-by-side cards read as one aligned row.
    var fillsRowHeight: Bool = false

    @State private var isHovering = false
    @State private var redeemBusy = false
    @State private var redeemOutcome: CodexAppServerClient.RedeemOutcome?

    private var label: String {
        settings.displayLabel(accountID: usage.id, fallback: usage.accountLabel)
    }

    /// This card's account as discovery (plus the dormant memory) knows it: where the homes and the
    /// dormancy behind the launch affordances come from.
    private var discovered: ProviderAccount? {
        UsageStore.shared.discoveredAccounts.first { $0.id == usage.id }
    }

    /// The account's config home, or nil when Tally has none to act on (a demo fixture, or an
    /// account discovered without a launchable directory) - which is what greys the expiry chip
    /// and both context-menu entries (AccountCardMenu) out. The RENEWAL home: a signed-out account
    /// keeps it, which is exactly what "Renew login" acts on.
    var configHome: String? { discovered?.launchHome }

    /// Signed out with its config home still on disk: listed and renewable, never launchable.
    private var isDormant: Bool { discovered?.isDormant == true }

    /// Who is signed in, for the identity tooltip. The ordering (the probe's live answer first, the
    /// provider's config-derived copy as the fallback) lives in the store, because the Settings row
    /// asks the same question and the two must not drift apart. Empty string, not nil: this feeds a
    /// tooltip, and an absent one is what "nothing to say" looks like there.
    private var identityEmail: String {
        LoginStatusStore.shared.identityEmail(usage) ?? ""
    }

    /// Non-headline windows. Model-scoped rows are hidden unless "show every model tier" is on, so by
    /// default only the highest-tier model (the headline) is featured.
    private var secondaryMetrics: [UsageMetric] {
        let headlineID = usage.headline?.id
        return usage.metrics.filter { metric in
            guard metric.id != headlineID else { return false }
            if metric.isModelScoped && !settings.showAllModels { return false }
            return true
        }
    }

    // MARK: Launch policy affordances (multi-account providers only)

    /// Sibling count decides whether launch affordances appear at all - with one account there is
    /// nothing to choose.
    private var hasSiblings: Bool {
        UsageStore.shared.accounts.filter { $0.providerID == usage.providerID }.count > 1
    }

    private var launchMode: LaunchPolicyStore.Mode {
        // Demo fixtures always demonstrate Smart mode (the real policy's pinned ids can never
        // match demo accounts, which would leave every marketing card badge-less).
        DemoUsage.isActive ? .auto : LaunchPolicyStore.shared.mode(usage.providerID)
    }

    private var isPinnedActive: Bool {
        LaunchPolicyStore.shared.isPinned(usage.id, providerID: usage.providerID)
    }

    /// Whether auto mode would launch THIS account right now (the panel predicts the CLI).
    private var isAutoPick: Bool {
        let store = UsageStore.shared
        let launchable = DemoUsage.isActive
            ? Set(store.accounts.map(\.id))   // fixtures are all "launchable" for the demo
            : Set(store.discoveredAccounts.compactMap { $0.launchableHome != nil ? $0.id : nil })
        return LaunchPolicyStore.shared.autoPickID(
            providerID: usage.providerID, accounts: store.accounts, launchable: launchable) == usage.id
    }

    /// A hard error (this account has never loaded) collapses to a compact error + Retry. A stale
    /// account (a failed refresh over previously-good numbers) keeps its metrics readable - the
    /// "Outdated" badge in the header carries the state, so the numbers aren't dimmed away.
    private var isHardError: Bool { usage.error != nil && !usage.isStale }

    /// The plan exposes only a single weekly window (e.g. Codex on ChatGPT Plus) - worth noting so a
    /// missing session/model row doesn't read as a bug.
    private var weeklyOnly: Bool {
        usage.metrics.count == 1 && usage.metrics.first?.kind == .weeklyAll
    }

    /// A reset was just redeemed here and the provider is still serving the spent numbers. The
    /// rows then say the reset is landing instead of "Limit reached", which alongside the green
    /// "Reset redeemed" line read as a redeem that did nothing. It covers every capped window on
    /// the card because a redeem clears the whole account's counters, not one of them.
    private var isSettlingReset: Bool {
        RedeemPropagationStore.shared.isSettling(usage)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if isHardError {
                errorRow
            } else {
                if let headline = usage.headline {
                    MetricRowView(metric: headline, mode: settings.displayMode, prominent: true,
                                  settlingReset: isSettlingReset)
                }
                if !secondaryMetrics.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(secondaryMetrics) { metric in
                            MetricRowView(metric: metric, mode: settings.displayMode,
                                          settlingReset: isSettlingReset)
                        }
                    }
                }
                if weeklyOnly {
                    Text(L("Weekly quota only"))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                // Banked rate-limit resets (Codex reset banking). Redeeming is the user's own
                // economic decision: it only ever happens through THIS explicit click plus a
                // confirmation that spells out the cost - never automatically.
                if let resets = usage.resetCreditsAvailable, resets > 0 {
                    Button {
                        if !DemoUsage.isActive { startRedeem() }
                    } label: {
                        HStack(spacing: 3) {
                            // The redeem round-trips the provider's app server; without a busy
                            // state the click reads as dead until the new quota pops in.
                            if redeemBusy {
                                ProgressView()
                                    .controlSize(.mini)
                                Text(L("redeeming…"))
                            } else {
                                Image(systemName: "arrow.counterclockwise")
                                    .font(.system(size: 9))
                                Text(verbatim: "\(resets) ")
                                    + Text(L(resets == 1 ? "reset available" : "resets available"))
                            }
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    // Dormant accounts keep this row (the count comes from the last good reading)
                    // but cannot act on it: redeeming talks to the provider's app server through
                    // the account's own CLI home, and a signed-out one has no session to spend a
                    // credit in - `RedeemAction.redeem` returns nil there, so the confirmation used
                    // to be followed by nothing at all. The count stays visible, greyed like every
                    // other dormant affordance, because the credits are still banked.
                    .disabled(redeemBusy || isDormant)
                    .help(isDormant
                          ? L("Signed out: renew the login to spend a banked reset.")
                          : L("Use a reset"))
                }
                if let redeemOutcome {
                    Text(RedeemAction.outcomeMessage(redeemOutcome))
                        .font(.caption2)
                        .foregroundStyle(redeemOutcome == .redeemed ? TallyColor.normal : .secondary)
                        .help(RedeemAction.outcomeDetail(redeemOutcome) ?? "")
                }
            }
            // A login is renewing in the background, where the user has nothing else to look at:
            // the browser has the sign-in, and this line is the only thing on screen tying it to
            // THIS account. Outside the error branch on purpose - an account that stopped loading
            // is exactly the one whose login gets renewed.
            if RenewLoginStore.shared.isRenewing(usage.id) {
                HStack(spacing: 3) {
                    ProgressView().controlSize(.mini)
                    Text(L("renewing login…"))
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            } else if LoginStatusStore.shared.isExpired(usage.id) {
                loginExpiredChip
            }
        }
        .padding(TallyMetrics.cardPaddingH)
        // maxHeight applies BEFORE the card background so the rounded surface itself stretches; the
        // row bounds the proposal via `.fixedSize(vertical:)`, so infinity here is never unbounded.
        .frame(maxHeight: fillsRowHeight ? .infinity : nil, alignment: .top)
        .tallyCard()
        // Right-click is where per-account maintenance lives (see AccountCardMenu): renewing this
        // account's login, and its config folder. Deliberately not chrome on the card - both are
        // occasional, and the card's face is already carrying the numbers and the launch controls.
        .contextMenu { cardContextMenu }
        .onHover { if showsDragHandle { isHovering = $0 } }
        // Deliberately NO card-wide tap: it made every stray click a launch-policy change (a
        // redeem-button near-miss re-pinned an account, 2026-07-19). Switching happens only on
        // the explicit header controls: the ◯ pins, the pin badge releases back to Smart.
    }

    /// The provider's own CLI says this account is no longer signed in. In the severity red the
    /// card already speaks in ("Near limit", "Limit reached"), and in the badge shape the header
    /// uses, because unlike those it is a BUTTON: pressing it starts the very renewal the right-
    /// click menu offers, which is the whole point of noticing. It replaces the "renewing login…"
    /// line rather than sitting beside it, so the card shows one login state at a time, and the
    /// next probe after a successful sign-in clears it with nothing left to dismiss.
    private var loginExpiredChip: some View {
        Button { RenewLoginStore.shared.renew(accountID: usage.id) } label: {
            HStack(spacing: 3) {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 8))
                Text(L("Login expired")).lineLimit(1)
            }
            .fixedSize()
            .font(.caption2.weight(.semibold))
            .foregroundStyle(TallyColor.critical)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(Capsule().fill(TallyColor.critical.opacity(0.15)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        // Greyed on a demo fixture, which has no config home behind it - the same rule that greys
        // the menu entry, asked of the same place, so a chip can never look more able than it is.
        .disabled(!RenewLoginStore.shared.canRenew(accountID: usage.id,
                                                   providerID: usage.providerID, home: configHome))
        .help(L("Sign in again to bring this account's usage back."))
    }

    private var header: some View {
        HStack(spacing: 7) {
            // The identity group carries its own tooltip - the signed-in email, so two accounts on
            // the same plan are distinguishable without putting an address on screen (and without
            // covering the trailing controls, which have tooltips of their own). Tally's own callout
            // rather than `.help()`: this is the one the user goes looking for, so it has to arrive
            // fast and look like the app. Combined into one accessibility element first, so the
            // hint the callout carries lands on the identity as a whole rather than on each label.
            HStack(spacing: 7) {
                ProviderIconView(providerID: usage.providerID, size: 16)
                Text(label)
                    .font(.subheadline.weight(.semibold))
                if let plan = usage.planName {
                    Text(plan)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
            .tallyTooltip(identityEmail)
            if usage.isStale {
                Label(L("Outdated"), systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(TallyColor.warning)
                    .help(usage.error ?? "")
            }
            Spacer()
            // Launch affordances live at the TRAILING edge so the identity (name · plan) never
            // gets pushed around: a mode badge (Smart purple / Pinned orange) as the label, and
            // ONE circle as the only switch - hollow = pin me, checked = pinned, click again to
            // release back to Smart (Albert's UX spec, 2026-07-19).
            if hasSiblings, launchMode != .off {
                if launchMode == .manual, isPinnedActive { pinnedBadge }
                if launchMode == .auto, isAutoPick { autoBadge }
                pinToggle
            }
            if showsDragHandle {
                Image(systemName: "line.3.horizontal")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    // Resident but dim: hover-only left a visibly empty slot beside the pin
                    // circle (the space is always reserved so the layout can't jump), which
                    // read as imbalance (2026-07-19). Dim at rest, full on hover.
                    .opacity(isHovering || handleProminent ? 1 : 0.35)
                    .accessibilityLabel(L("Drag to reorder"))
                    .help(L("Drag to reorder"))
            }
        }
    }

    /// ONE circle, two states: hollow = click to pin this account; checked = pinned, click
    /// again to release back to Smart. The same control toggles both ways - no second gesture
    /// to learn, no card-wide tap to mis-hit.
    private var pinToggle: some View {
        Button {
            let policy = LaunchPolicyStore.shared
            if isPinnedActive {
                policy.setMode(usage.providerID, .auto)
            } else {
                policy.pin(usage.providerID, accountID: usage.id, home: discovered?.launchableHome)
            }
        } label: {
            Image(systemName: isPinnedActive ? "checkmark.circle.fill" : "circle")
                .font(.caption)
                .foregroundStyle(isPinnedActive ? Color.orange : Color.secondary)
        }
        .buttonStyle(.plain)
        // A signed-out account cannot BECOME the launch account: pinning is denormalized into the
        // policy file the CLI reads, so a pinned dormant home would have `tally` exec a logged-out
        // directory long after the panel forgot why. The expiry chip beside this is the control
        // that still works there.
        //
        // Releasing an existing pin stays available, though - that is the opposite direction. An
        // account pinned BEFORE it signed out is exactly the one the user needs to unpin, and
        // disabling the only control that does it left the choice stuck until the login came back.
        .disabled(isDormant && !isPinnedActive)
        .help(pinToggleHelp)
        .accessibilityLabel(L("Set as launch account"))
    }

    /// What the circle does from where it is now - all four states, because a pinned dormant card
    /// is a real one and reads wrong under either of the other two sentences.
    private var pinToggleHelp: String {
        switch (isPinnedActive, isDormant) {
        case (true, true):
            L("Pinned but signed out: launches pick by headroom until the login is renewed. Click to unpin.")
        case (true, false): L("Pinned. Click again to go back to Smart.")
        case (false, true): L("Signed out: renew the login before launching with this account.")
        case (false, false): L("Set as launch account")
        }
    }

    /// Manual mode, pinned card: a label-only badge in the warm colour, same shape as the Smart
    /// badge - the mode reads at a glance, the neighbouring checked circle does the switching.
    private var pinnedBadge: some View {
        HStack(spacing: 3) {
            Image(systemName: "pin.fill").font(.system(size: 8))
            Text(L("Pinned")).lineLimit(1)
        }
        .fixedSize()   // a badge must never wrap (a two-line capsule broke the header, 2026-07-18)
        .font(.caption2.weight(.semibold))
        .foregroundStyle(Color.orange)
        .padding(.horizontal, 5).padding(.vertical, 1)
        .background(Capsule().fill(Color.orange.opacity(0.15)))
        .help(L("Manual: every new session uses this account."))
    }

    /// Smart mode: marks the card the next launch would pick. Copy lesson, twice over: "Auto"
    /// read as a per-account mode toggle, "Next" read as an app-restart notice. "Smart pick"
    /// names both the chooser (smart mode) and the meaning (this card is the current pick);
    /// the tooltip spells out the consequence AND the why - the binding quota window and its
    /// reset - so the pick never looks arbitrary.
    private var autoBadge: some View {
        HStack(spacing: 3) {
            Image(systemName: "sparkles").font(.system(size: 8))
            // The short mode word, not "Smart pick": the longer badge squeezed "Claude 2"
            // into a wrapped two-line title at demo widths (2026-07-19 screenshot round).
            Text(L("Smart")).lineLimit(1)
        }
        .fixedSize()
        .font(.caption2.weight(.semibold))
        .foregroundStyle(TallyColor.ai)
        .padding(.horizontal, 5).padding(.vertical, 1)
        .background(Capsule().fill(TallyColor.ai.opacity(0.15)))
        .help(smartPickTooltip)
    }

    private var smartPickTooltip: String {
        let base = L("Smart: new sessions start on the account whose quota goes furthest right now.")
        let primary = LaunchPolicyStore.shared.policy(usage.providerID).model
        guard let reason = LaunchPolicyStore.smartReason(usage, primaryModel: primary) else {
            return base
        }
        return base + "\n" + reason
    }

    // MARK: Reset banking - manual redeem (the only write Tally ever performs, user-confirmed)

    /// Ask through the shared confirmation, then spend through the shared redeem, with the card's
    /// own chrome around it: a spinner while the app server answers (the click reads as dead
    /// otherwise), then the outcome line for a few seconds. The dialog and the write live in
    /// `RedeemAction` because the banked-reset notification opens the very same question.
    private func startRedeem() {
        guard RedeemAction.confirm(usage: usage, label: label) else { return }
        redeemBusy = true
        Task {
            let outcome = await RedeemAction.redeem(usage: usage)
            redeemBusy = false
            guard let outcome else { return }
            redeemOutcome = outcome
            await RedeemAction.followThrough(outcome: outcome, usage: usage)
            try? await Task.sleep(for: .seconds(8))
            redeemOutcome = nil
        }
    }

    private var errorRow: some View {
        HStack(alignment: .top, spacing: 8) {
            Label(usage.error ?? "", systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(TallyColor.warning)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button(L("Retry")) {
                Task { await UsageStore.shared.refresh(userInitiated: true) }
            }
            .buttonStyle(.borderless)
            .font(.caption)
        }
    }
}
