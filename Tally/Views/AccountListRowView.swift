import SwiftUI

/// One account as a single line, for the panel's compact list density (`PanelDensity.list`): the
/// identity on the left, every usage window as a small bar plus its percentage on the right, and the
/// same launch controls a card carries shrunk to icons in between. Roughly a fifth of a card's
/// height, which is the whole point: past half a dozen accounts the card grid outgrows the display
/// and the panel becomes a scroll rather than a glance.
///
/// It hides words, never facts. Every window a card shows is here (the same `showAllModels` filter
/// decides), every state a card can be in has a mark here, and the words the card spells out (the
/// window's name, its reset, what the pin does) move into hover tooltips rather than disappearing.
/// What it does drop is the card's own spacing and its per-window reset line, because those are the
/// height.
struct AccountListRowView: View {
    let usage: AccountUsage
    @Bindable var settings: SettingsStore
    /// Show a grip glyph on hover - the drag-affordance for surfaces where the row can be reordered.
    var showsDragHandle: Bool = false
    /// Full-brightness handle regardless of hover - the floating drag preview sets this, so the grip
    /// never blinks out mid-drag.
    var handleProminent: Bool = false

    @State private var isHovering = false
    @State private var redeemBusy = false
    @State private var redeemOutcome: CodexAppServerClient.RedeemOutcome?

    /// The card's own answers, shared rather than re-derived (see `AccountFacts`).
    private var facts: AccountFacts { AccountFacts(usage: usage, settings: settings) }

    /// The narrowest a row still reads as one line rather than a squeeze, and so the width of ONE
    /// list column. Built from what a row has to carry: the identity (provider mark, name, plan)
    /// around 150pt, three meter clusters at 34pt of track plus a 32pt figure plus their gaps around
    /// 230pt, the trailing controls (badge slot, pin, grip) around 60pt, and a little slack between
    /// the identity and the meters so a long nickname does not touch the first bar. Checked against
    /// the demo fleet on screen: at 460 the one row carrying a status mark (the warning triangle
    /// travels with the identity) truncated its plan to "Max…", so the slack has to cover a mark
    /// too (2026-08-04).
    static let minComfortableWidth: CGFloat = 480
    /// The gutter between list columns, which is the card grid's own (see `PanelGeometry`).
    static let columnGap: CGFloat = PanelGeometry.columnGap

    /// The meter track. Narrow enough that three windows plus the identity fit one row at the
    /// panel's list width, wide enough that a fill still reads as a proportion rather than a dot.
    private static let barWidth: CGFloat = 34
    private static let barHeight: CGFloat = 4
    /// The percentage column: "100%" at caption size, so the figures line up down the panel the way
    /// the cards' do.
    private static let valueWidth: CGFloat = 32
    /// The badge slot, reserved whether or not this row has a badge, so the pin circles stay in one
    /// column instead of stepping left and right with the smart pick.
    private static let badgeWidth: CGFloat = 11

    var body: some View {
        HStack(spacing: 8) {
            identity
            // The status marks travel with the IDENTITY, not with the meters, and the slack sits
            // between the two groups. Put after the slack, a row that happens to carry a warning
            // triangle or a reset count would push its own percentages left and break the column
            // the eye reads down (seen on screen, 2026-08-04): in a list the figures lining up IS
            // the feature.
            //
            // Only the marks ABOUT USAGE answer to the error branch, because those are the ones a
            // row with no reading has nothing to say about. The login marks stay outside it, the
            // same way the card keeps its login state outside its own error branch: `lastGood`
            // lives in memory, so after every launch a signed-out account IS the hard-error row
            // until the first good poll, which is precisely when the renewal button is worth
            // having on screen.
            if !facts.isHardError { usageMarks }
            loginMarks
            Spacer(minLength: 6)
            if facts.isHardError {
                errorTail
            } else {
                meters
            }
            trailingControls
        }
        .padding(.horizontal, TallyMetrics.cardPaddingH)
        .padding(.vertical, 5)
        .font(.caption2)
        .lineLimit(1)
        .contentShape(Rectangle())
        .onHover { if showsDragHandle { isHovering = $0 } }
        // Same menu the card right-clicks to, from the same values: the row is a density, not a
        // reduced feature set.
        .contextMenu {
            AccountActionsMenu(accountID: usage.id, providerID: usage.providerID,
                               label: facts.label, home: facts.configHome)
        }
    }

    /// Provider mark, name, plan - the card header's leading group at row scale, carrying the same
    /// identity callout (signed-in address over plan and config home), because two accounts that
    /// answer with one address are exactly as indistinguishable here as they are on a card.
    private var identity: some View {
        HStack(spacing: 6) {
            ProviderIconView(providerID: usage.providerID, size: 14)
            Text(facts.label)
                .font(.footnote.weight(.semibold))
                .lineLimit(1)
            if let plan = usage.planName {
                Text(plan)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    // The plan is the first thing to give up when the row runs short: the name
                    // identifies the account, the plan only qualifies it, and the callout still
                    // carries it in full.
                    .layoutPriority(-1)
            }
        }
        .accessibilityElement(children: .combine)
        .tallyTooltip(facts.identityEmail, detail: facts.identityDetail,
                      forced: facts.forcesIdentityTooltip)
    }

    /// The states a card spells out in words about this account's READING, as glyphs: numbers that
    /// have gone stale, and banked resets waiting to be spent. Each keeps its card sentence as a
    /// tooltip, under a first line naming the account, because a glyph in a list of eight rows is
    /// the one place a sentence cannot say "this account" and be understood. A row that never
    /// loaded shows none of them, which is what the error branch in the body decides.
    ///
    /// The stale mark also stands down while the login is the reason (`AccountFacts.showsStaleMark`),
    /// so this row never lights two triangles that mean one thing. Asked of the facts rather than
    /// spelled out here, so the card answers it identically.
    @ViewBuilder
    private var usageMarks: some View {
        if facts.showsStaleMark {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 9))
                .foregroundStyle(TallyColor.warning)
                .tallyTooltip(facts.markOwner, detail: usage.error ?? L("Outdated"))
                .accessibilityLabel(L("Outdated"))
        }
        if let outcome = redeemOutcome {
            Text(RedeemAction.outcomeMessage(outcome))
                .foregroundStyle(outcome == .redeemed ? TallyColor.normal : .secondary)
                .tallyTooltip(RedeemAction.outcomeDetail(outcome) ?? "")
        } else if let resets = usage.resetCreditsAvailable, resets > 0 {
            redeemButton(resets)
        }
    }

    /// The login's own two states, at row scale: renewing right now, or expired and offering the
    /// renewal. One either/or, exactly like the card's, so the row shows one login state at a time.
    /// Shown whatever the reading says, for the reason spelled out where the body places it. The
    /// expiry names its account on the callout's first line, the same way the stale mark above
    /// does: this is the mark that asks for a sign-in, and which login to sign back into is the
    /// whole question.
    @ViewBuilder
    private var loginMarks: some View {
        if facts.isRenewingLogin {
            ProgressView()
                .controlSize(.mini)
                .tallyTooltip(L("renewing login…"))
        } else if facts.isLoginExpired {
            // A button, exactly like the card's chip: noticing the expiry is only useful next to
            // the thing that fixes it.
            Button { RenewLoginStore.shared.renew(accountID: usage.id) } label: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(TallyColor.critical)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!facts.canRenewLogin)
            // Says what PRESSING IT does, not just what happened: on a card the same state is a
            // chip with "Login expired" written on it, and here it is a 9pt triangle that happens
            // to be a button. If the callout does not say the click signs you back in, nothing on
            // the row does.
            .tallyTooltipAroundControl(facts.markOwner,
                                       detail: L("Login expired. Click to sign in again."))
            .accessibilityLabel(L("Login expired"))
        }
    }

    /// Banked rate-limit resets, as the count and nothing else. Redeeming stays what it is on the
    /// card: this click only opens the confirmation that spells out the cost, never spends.
    private func redeemButton(_ resets: Int) -> some View {
        Button {
            if !DemoUsage.isActive { startRedeem() }
        } label: {
            HStack(spacing: 2) {
                if redeemBusy {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "arrow.counterclockwise").font(.system(size: 8))
                    Text(verbatim: "\(resets)").monospacedDigit()
                }
            }
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(redeemBusy || facts.isDormant)
        .tallyTooltipAroundControl(facts.isDormant
              ? L("Signed out: renew the login to spend a banked reset.")
              : L("Use a reset"))
        .accessibilityLabel(L(resets == 1 ? "reset available" : "resets available"))
    }

    /// Every window this account reports, headline first, in the card's order. Each is a track plus
    /// a figure; the window's NAME and its reset live in the cluster's tooltip, because spelling
    /// both out per window is what makes the card as tall as it is.
    private var meters: some View {
        HStack(spacing: 8) {
            ForEach(facts.orderedMetrics) { metric in
                meterCluster(metric)
            }
        }
    }

    private func meterCluster(_ metric: UsageMetric) -> some View {
        HStack(spacing: 4) {
            bar(metric)
            Text(UsageFormat.percent(metric, mode: settings.displayMode))
                .font(.caption.monospacedDigit())
                // The figure carries the warning here, unlike on a card. A 34pt track is too small
                // for its colour alone to be the alarm, and the row has no space for the card's
                // "Limit reached" line. Not while a redeemed reset settles, though: the number is
                // seconds from being replaced, so that is a wait rather than a warning.
                .foregroundStyle(metric.severity == .critical && !facts.isSettlingReset
                                 ? TallyColor.critical : Color.primary)
                .frame(width: Self.valueWidth, alignment: .trailing)
        }
        .tallyTooltip(meterHelp(metric))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(L(metric.label)), \(UsageFormat.percent(metric, mode: settings.displayMode))")
    }

    /// Used fills from the left, remaining anchors right - the same boundary the card's bars split
    /// at, so the two densities never draw one number two ways.
    private func bar(_ metric: UsageMetric) -> some View {
        let fraction = UsageFormat.fillFraction(metric, mode: settings.displayMode)
        return Capsule()
            .fill(.quaternary)
            .frame(width: Self.barWidth, height: Self.barHeight)
            .overlay(alignment: settings.displayMode == .used ? .leading : .trailing) {
                Capsule()
                    .fill(metric.severity.color)
                    .frame(width: max(2, Self.barWidth * fraction), height: Self.barHeight)
            }
            // The personal account's water line, on the same track and at the same boundary the
            // card draws it (ReserveMark.swift): a density is not a reduced feature set. On the same
            // window too - the weekly all-models one and no other (`PersonalAccount.reserved`).
            .overlay { ReserveMark(reserve: barReserve(metric)) }
    }

    /// The water line this window carries: the account's number where the reserve is held back from
    /// the window, and nothing where it is not, so the hatch and the callout below agree.
    private func barReserve(_ metric: UsageMetric) -> Int {
        PersonalAccount.reserved(metric.kind) ? facts.reservePercent : 0
    }

    /// The window's name and its own reset, in the same words the card prints under the bar and in
    /// the user's chosen reset style, so hovering a row answers exactly what reading a card does.
    private func meterHelp(_ metric: UsageMetric) -> String {
        let name = L(metric.label)
        var text = name
        if let reset = UsageFormat.resetText(metric.resetsAt, style: settings.resetDisplay) {
            text += " · \(reset)"
        }
        // What the hatching at the end of the track is. The card can afford to let the mark speak
        // for itself beside a 100pt bar; at 34pt the words have to be somewhere, and this callout is
        // where every other word this row folds away already lives.
        if barReserve(metric) > 0 { text += "\n" + L("Kept for web use") }
        return text
    }

    /// An account that has never loaded: the reason, then the retry, in place of the meters it has
    /// none of.
    private var errorTail: some View {
        HStack(spacing: 6) {
            Text(usage.error ?? "")
                .foregroundStyle(TallyColor.warning)
                .lineLimit(1)
            Button(L("Retry")) {
                Task { await UsageStore.shared.refresh(userInitiated: true) }
            }
            .buttonStyle(.borderless)
            .font(.caption2)
        }
    }

    /// The launch affordances, in the card's order and with the card's rules: the mode badge as a
    /// bare glyph (its words move to the tooltip), then the one circle that pins and unpins.
    @ViewBuilder
    private var trailingControls: some View {
        if facts.hasSiblings, facts.launchMode != .off {
            badgeSlot
            pinToggle
        }
        if showsDragHandle {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.tertiary)
                .opacity(isHovering || handleProminent ? 1 : 0.35)
                .accessibilityLabel(L("Drag to reorder"))
                .tallyTooltip(L("Drag to reorder"))
        }
    }

    /// Always the same width, badge or no badge: the pin circles have to stand in one column, and a
    /// slot that collapses when the smart pick moves would shuffle every row beside it.
    private var badgeSlot: some View {
        ZStack {
            // Something real has to hold the slot open: a branch that matches nothing resolves to an
            // EmptyView, which is layout-transparent - a `.frame` on it reserves nothing at all, and
            // the rows carrying a badge sat a badge's width left of the rest (seen on screen,
            // 2026-08-04).
            Color.clear.frame(width: Self.badgeWidth, height: Self.badgeWidth)
            if facts.launchMode == .manual, facts.isPinnedActive {
                Image(systemName: "pin.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(Color.orange)
                    .tallyTooltip(L("Manual: every new session uses this account."))
                    .accessibilityLabel(L("Pinned"))
            } else if facts.launchMode == .auto, facts.isAutoPick {
                Image(systemName: "sparkles")
                    .font(.system(size: 9))
                    .foregroundStyle(TallyColor.ai)
                    .tallyTooltip(facts.smartPickTooltip)
                    .accessibilityLabel(L("Smart"))
            }
        }
        .frame(width: Self.badgeWidth)
    }

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

    /// Ask through the shared confirmation, then spend through the shared redeem - the same two
    /// calls the card makes, so the question and the write have one implementation. The outcome
    /// takes the badge's place for a few seconds, which is the row's version of the card's outcome
    /// line: there is no second line to put it on.
    private func startRedeem() {
        guard RedeemAction.confirm(usage: usage, label: facts.label) else { return }
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
}
