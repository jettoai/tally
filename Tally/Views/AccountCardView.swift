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

    /// Every derived answer about this account - the homes, the login state, which windows to show,
    /// which launch affordances apply - shared with the compact list row so the two surfaces can
    /// never disagree about any of them (see `AccountFacts`).
    private var facts: AccountFacts { AccountFacts(usage: usage, settings: settings) }

    private var label: String { facts.label }

    /// The account's config home, or nil when Tally has none to act on. Named at card level because
    /// the context-menu extension reads it (AccountCardMenu).
    var configHome: String? { facts.configHome }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if facts.isHardError {
                errorRow
            } else {
                if let headline = usage.headline {
                    MetricRowView(metric: headline, mode: settings.displayMode, prominent: true,
                                  settlingReset: facts.isSettlingReset,
                                  reserve: facts.reservePercent)
                }
                if !facts.secondaryMetrics.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(facts.secondaryMetrics) { metric in
                            MetricRowView(metric: metric, mode: settings.displayMode,
                                          settlingReset: facts.isSettlingReset,
                                          reserve: facts.reservePercent)
                        }
                    }
                }
                if facts.isWeeklyOnly {
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
                    .disabled(redeemBusy || facts.isDormant)
                    .tallyTooltipAroundControl(facts.isDormant
                          ? L("Signed out: renew the login to spend a banked reset.")
                          : L("Use a reset"))
                }
                if let redeemOutcome {
                    Text(RedeemAction.outcomeMessage(redeemOutcome))
                        .font(.caption2)
                        .foregroundStyle(redeemOutcome == .redeemed ? TallyColor.normal : .secondary)
                        .tallyTooltip(RedeemAction.outcomeDetail(redeemOutcome) ?? "")
                }
            }
            // A login is renewing in the background, where the user has nothing else to look at:
            // the browser has the sign-in, and this line is the only thing on screen tying it to
            // THIS account. Outside the error branch on purpose - an account that stopped loading
            // is exactly the one whose login gets renewed.
            if facts.isRenewingLogin {
                HStack(spacing: 3) {
                    ProgressView().controlSize(.mini)
                    Text(L("renewing login…"))
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            } else if facts.isLoginExpired {
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
        .disabled(!facts.canRenewLogin)
        .tallyTooltipAroundControl(L("Sign in again to bring this account's usage back."))
    }

    private var header: some View {
        HStack(spacing: 7) {
            // The identity group carries its own tooltip - the signed-in email over the plan and
            // config home, so two accounts are distinguishable without putting an address on screen
            // (and without covering the trailing controls, which have tooltips of their own). The
            // second line is not decoration: one ChatGPT address signed in twice, in a personal
            // workspace and a team's, is the SAME email on both cards, and the home is then the only
            // thing on this machine that separates them. Tally's own callout
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
            // Forced open on ONE fixture for a design capture, never on a real account: every card
            // carries this target, and forcing them all would leave the capture showing whichever
            // the layout traversal reached last (TallyTooltip.previewForced).
            .tallyTooltip(facts.identityEmail, detail: facts.identityDetail,
                          forced: facts.forcesIdentityTooltip)
            // Not while an EXPIRED login is the reason: the expiry chip at the foot of this card
            // already says why the numbers stopped, and "Outdated" up here is only its symptom
            // (`AccountFacts.showsStaleMark`, shared with the compact row so the two agree). A
            // renewal in flight is not a reason and leaves this standing, as that rule explains.
            if facts.showsStaleMark {
                Label(L("Outdated"), systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(TallyColor.warning)
                    .tallyTooltip(usage.error ?? "", detail: usage.errorDetail)
            }
            Spacer()
            // Launch affordances live at the TRAILING edge so the identity (name · plan) never
            // gets pushed around: a mode badge (Smart purple / Pinned orange) as the label, and
            // ONE circle as the only switch - hollow = pin me, checked = pinned, click again to
            // release back to Smart (Albert's UX spec, 2026-07-19).
            if facts.hasSiblings, facts.launchMode != .off {
                if facts.launchMode == .manual, facts.isPinnedActive { pinnedBadge }
                if facts.launchMode == .auto, facts.isAutoPick { autoBadge }
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
                    .tallyTooltip(L("Drag to reorder"))
            }
        }
    }

    /// ONE circle, two states: hollow = click to pin this account; checked = pinned, click
    /// again to release back to Smart. The same control toggles both ways - no second gesture
    /// to learn, no card-wide tap to mis-hit.
    private var pinToggle: some View {
        Button { facts.togglePin() } label: {
            Image(systemName: facts.isPinnedActive ? "checkmark.circle.fill" : "circle")
                .font(.caption)
                .foregroundStyle(facts.isPinnedActive ? Color.orange : Color.secondary)
        }
        .buttonStyle(.plain)
        .disabled(!facts.canTogglePin)
        .tallyTooltipAroundControl(facts.pinToggleHelp)
        .accessibilityLabel(L("Set as launch account"))
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
        .tallyTooltip(L("Manual: every new session uses this account."))
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
        .tallyTooltip(facts.smartPickTooltip)
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
            // The line stays the app's own short sentence and the REASON hovers: a vendor's error
            // is written for a log, and one of them in this row would set the card's width from
            // outside the app (`AccountUsage.errorDetail`, `CodexProvider.detail`).
            Label(usage.error ?? "", systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(TallyColor.warning)
                .fixedSize(horizontal: false, vertical: true)
                .tallyTooltip(usage.error ?? "", detail: usage.errorDetail)
            Spacer(minLength: 4)
            Button(L("Retry")) {
                Task { await UsageStore.shared.refresh(userInitiated: true) }
            }
            .buttonStyle(.borderless)
            .font(.caption)
        }
    }
}
