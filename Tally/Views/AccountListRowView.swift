import SwiftUI

/// One account as a single line, for the panel's compact list density (`PanelDensity.list`): the
/// identity on the left, every usage window as a small bar plus its percentage on the right, and the
/// same launch controls a card carries shrunk to icons in between. Roughly a fifth of a card's
/// height, which is the whole point: past half a dozen accounts the card grid outgrows the display
/// and the panel becomes a scroll rather than a glance.
///
/// It hides words, never facts. Every window a card shows is here (the same `showAllModels` filter
/// decides), every state a card can be in has a mark here, and the words the card spells out (the
/// window's name, how long until its reset and the exact time, what the pin does) move into hover
/// tooltips rather than disappearing (B-650: the countdown is the hover's first words, never a
/// second line that would make the row taller).
struct AccountListRowView: View {
    let usage: AccountUsage
    @Bindable var settings: SettingsStore
    /// Show a grip glyph on hover - the drag-affordance for surfaces where the row can be reordered.
    var showsDragHandle: Bool = false
    /// Full-brightness handle regardless of hover - the floating drag preview sets this, so the grip
    /// never blinks out mid-drag.
    var handleProminent: Bool = false
    /// The width every row of this block gives its identity group, so the meters of every row start
    /// at one x and their tracks come out one length (see `PopoverRootView.rowStack`). Nil lays the
    /// identity at its own width, which is what the floating drag preview does.
    var identityWidth: CGFloat? = nil
    /// How many meter columns this row's block lays out: the most windows any of its rows reports
    /// (`PanelGeometry.meterClusterWidths`). Zero means this row's own count.
    var meterSlots: Int = 0
    /// Reports this row's identity group width, measured at the group's own size, so the block can
    /// take the widest as its shared column.
    var onIdentityWidth: ((CGFloat) -> Void)? = nil

    @State private var isHovering = false
    @State private var redeemBusy = false
    @State private var redeemOutcome: CodexAppServerClient.RedeemOutcome?

    /// The card's own answers, shared rather than re-derived (see `AccountFacts`).
    var facts: AccountFacts { AccountFacts(usage: usage, settings: settings) }

    /// The narrowest a row still reads as one line rather than a squeeze, and so the width of ONE
    /// list column. Built from what a row has to carry: the identity (provider mark, name, plan)
    /// around 150pt, three meter clusters at the 34pt minimum track plus a 32pt figure plus their gaps around
    /// 230pt, the trailing controls (badge slot, pin, grip) around 60pt, and a little slack between
    /// the identity and the meters so a long nickname does not touch the first bar. Checked against
    /// the demo fleet on screen: at 460 the one row carrying a status mark (the warning triangle
    /// travels with the identity) truncated its plan to "Max…", so the slack has to cover a mark
    /// too (2026-08-04).
    static let minComfortableWidth: CGFloat = 480
    /// The gutter between list columns, which is the card grid's own (see `PanelGeometry`).
    static let columnGap: CGFloat = PanelGeometry.columnGap

    /// The SHORTEST a meter track gets. The track itself stretches with the room its row has left
    /// (`PanelGeometry.meterClusterWidths`); this floor is what three windows plus the identity were
    /// fitted to at the panel's list width, and what a very long nickname still leaves the meters.
    nonisolated static let barWidth: CGFloat = 34
    private static let barHeight: CGFloat = 4
    /// The percentage column: "100%" at caption size, so the figures line up down the panel the way
    /// the cards' do.
    nonisolated static let valueWidth: CGFloat = 32
    /// The badge slot, reserved whether or not this row has a badge, so the pin circles stay in one
    /// column instead of stepping left and right with the smart pick.
    private static let badgeWidth: CGFloat = 11

    var body: some View {
        HStack(spacing: 8) {
            identityColumn
            if facts.isRenewingLogin {
                Spacer(minLength: 6)
                renewingTail
            } else if facts.isHardError {
                Spacer(minLength: 6)
                errorTail
            } else {
                // The meters take whatever the identity column and the trailing controls leave, and
                // take it LAST: a long nickname truncates against the meters' minimum rather than
                // pushing them off the row (`MeterSlots`).
                MeterSlots(slots: meterSlots, gap: 8) {
                    ForEach(facts.orderedMetrics) { metric in
                        meterCluster(metric)
                    }
                }
                .layoutPriority(-1)
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

    /// The identity and the marks that travel with it, measured at their own width and padded to
    /// the block's shared column. Measured BEFORE the padding, so the reading is this row's own
    /// width whatever the column is, and a renamed account can widen the column as well as narrow it.
    private var identityColumn: some View {
        HStack(spacing: 8) {
            identity
            // The status marks travel with the IDENTITY, not with the meters, and the identity
            // column is padded to the block's widest, so the meters start at one x. Put after the
            // padding, a row that happens to carry a warning triangle or a reset count would push
            // its own percentages left and break the column the eye reads down (seen on screen,
            // 2026-08-04): in a list the figures lining up IS the feature.
            //
            // The usage marks are drawn on every row, the one that never loaded included: the
            // stale mark needs `isStale`, which a never-loaded row does not have
            // (`AccountFacts.isHardError`), and the reset mark is not a reading, so an account
            // whose first poll failed still shows its "?" (codex review of dcbc04f). The login
            // marks stay outside for their own reason: `lastGood` lives in memory, so after every
            // launch a signed-out account IS the hard-error row until the first good poll, which
            // is precisely when the renewal button is worth having on screen.
            usageMarks
            loginMarks
        }
        .background {
            GeometryReader { proxy in
                Color.clear.onChange(of: proxy.size.width, initial: true) { _, width in
                    onIdentityWidth?(width)
                }
            }
        }
        .frame(minWidth: identityWidth, alignment: .leading)
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
    /// loaded has no stale numbers to mark, and still shows its reset state.
    ///
    /// The stale mark also stands down while an EXPIRED login is the reason
    /// (`AccountFacts.showsStaleMark`), so this row never lights two triangles that mean one thing.
    /// A renewal merely running does not suppress it, for the reason spelled out there. Asked of the
    /// facts rather than spelled out here, so the card answers it identically.
    ///
    /// What the stale mark says under the account's name: the failure's short line and the reason
    /// under it, as the two lines they are.
    ///
    /// The one word the mark itself means is a DEFENSIVE fallback, not a state production reaches:
    /// the mark needs `isStale` (`AccountFacts.showsStaleMark`), which is raised in exactly one
    /// place, the sustained branch of `foldLastGood`, and that branch writes a non-nil `error` in
    /// the same breath. So a mark with nothing to say would mean the fold had changed underneath
    /// this row, and the row says the honest word rather than hovering an empty callout.
    private var staleDetail: String {
        let said = [usage.error, usage.errorDetail].compactMap { $0 }.joined(separator: "\n")
        return said.isEmpty ? L("Outdated") : said
    }

    @ViewBuilder
    private var usageMarks: some View {
        if facts.showsStaleMark {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 9))
                .foregroundStyle(TallyColor.warning)
                // Both halves of the callout, the card's rule at this width: the short line and
                // the reason under it are one answer, and the callout splits an embedded newline
                // into its own lines. Nothing to say at all falls back to the one word the mark
                // itself means (`AccountUsage.errorDetail`).
                .tallyTooltip(facts.markOwner, detail: staleDetail)
                .accessibilityLabel(L("Outdated"))
        }
        if let outcome = redeemOutcome {
            Text(RedeemAction.outcomeMessage(outcome))
                .foregroundStyle(outcome == .redeemed ? TallyColor.normal : .secondary)
                .tallyTooltip(RedeemAction.outcomeDetail(outcome) ?? "")
        } else if case .codexCredits(let resets) = facts.resetOffer {
            redeemButton(resets)
        } else if facts.resetOffer == .codexNone {
            codexResetMark("0", help: L("No banked resets"))
        } else if facts.resetOffer == .codexUnknown {
            codexResetMark("?", help: facts.codexResetUnknownHelp)
        } else if facts.resetOffer == .codexNotReported {
            codexResetMark("\u{2013}", help: L("Resets not reported for this login"))
                .accessibilityLabel(L("Resets not reported for this login"))
        }
    }

    /// A Codex account with nothing to press: "0" banked, "?" unknown, or a dash for a login whose
    /// read has no reset key at all, greyed like every other unavailable mark on this row.
    private func codexResetMark(_ text: String, help: String) -> some View {
        HStack(spacing: 2) {
            Image(systemName: "arrow.counterclockwise").font(.system(size: 8))
            Text(verbatim: text).monospacedDigit()
        }
        .foregroundStyle(.tertiary)
        .tallyTooltip(facts.markOwner, detail: help)
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
            EmptyView()  // Said once, in the meters' place (`renewingTail`).
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
            //
            // WHICH sentence comes from `AccountSignIn`, shared with the Settings row: this mark
            // lights on the probe's verdict, the probe asks every account that has a config home,
            // so a home the user signed out of lights it too and must not be told its login expired
            // (codex review, 2026-08-24).
            .tallyTooltipAroundControl(
                facts.markOwner,
                detail: L(AccountSignIn.detailKey(isDormant: facts.isDormant)))
            .accessibilityLabel(L("Signed out"))
        }
        AccountLoginHealthView(accountID: usage.id, owner: facts.markOwner, canRenew: facts.canRenewLogin,
                               compact: true, showsExpiry: !facts.isLoginExpired && !facts.isRenewingLogin)
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
            // The whole mark turns warning inside 48 hours of the soonest expiry, critical inside 6.
            .foregroundStyle(facts.resetExpiryColor().map(AnyShapeStyle.init)
                             ?? AnyShapeStyle(.secondary))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(redeemBusy || facts.isDormant)
        .tallyTooltipAroundControl(facts.markOwner, detail: redeemHelp)
        .accessibilityLabel([
            "\(resets) " + L(resets == 1 ? "reset available" : "resets available"),
            facts.resetExpiryNote(),
        ].compactMap { $0 }.joined(separator: ", "))
    }

    /// What hovering the banked-reset count says: what pressing does, or why it cannot, and then the
    /// expiry in both cases. A signed-out login still holds its credits, so their deadline still
    /// applies and is still worth reading.
    private var redeemHelp: String {
        if redeemBusy { return L("redeeming…") }
        let action = facts.isDormant
            ? L("Signed out: renew the login to spend a banked reset.")
            : L("Use a reset")
        return [action, facts.resetExpiryNote(), facts.resetExpiryClock()]
            .compactMap { $0 }.joined(separator: " · ")
    }

    /// One window this account reports, as a track plus a figure, in the card's order; the window's
    /// NAME, its reset countdown and the exact time live in the cluster's tooltip, because spelling
    /// them out per window is what makes the card as tall as it is.
    private func meterCluster(_ metric: UsageMetric) -> some View {
        let passed = usage.resetPassed(metric)
        let figure = UsageFormat.percent(metric, mode: settings.displayMode, resetPassed: passed)
        return HStack(spacing: 4) {
            bar(metric, resetPassed: passed)
            Text(figure)
                .font(.caption.monospacedDigit())
                // The figure carries the warning here, unlike on a card. A track this short is too small
                // for its colour alone to be the alarm, and the row has no space for the card's
                // "Limit reached" line. Not while a redeemed reset settles, though: the number is
                // seconds from being replaced, so that is a wait rather than a warning.
                .foregroundStyle(figureColor(metric, resetPassed: passed))
                .frame(width: Self.valueWidth, alignment: .trailing)
        }
        .tallyTooltip(meterHelp(metric))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(L(metric.label)), \(figure)")
    }

    private func figureColor(_ metric: UsageMetric, resetPassed: Bool) -> Color {
        if resetPassed { return .secondary }
        return metric.severity == .critical && !facts.isSettlingReset ? TallyColor.critical : .primary
    }

    /// Used fills from the left, remaining anchors right - the same boundary the card's bars split
    /// at, so the two densities never draw one number two ways. The track takes the cluster's width
    /// (never under `barWidth`), and the fill is measured off the track it is drawn in.
    private func bar(_ metric: UsageMetric, resetPassed: Bool) -> some View {
        let fraction = UsageFormat.fillFraction(metric, mode: settings.displayMode)
        let fillAlignment: Alignment = settings.displayMode == .used ? .leading : .trailing
        return Capsule()
            .fill(.quaternary)
            .frame(minWidth: Self.barWidth, maxWidth: .infinity)
            .frame(height: Self.barHeight)
            .overlay {
                GeometryReader { geo in
                    Capsule()
                        .fill(resetPassed ? Color.clear : metric.severity.color)
                        .frame(width: max(2, geo.size.width * fraction), height: Self.barHeight)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: fillAlignment)
                }
            }
            // The personal account's water line, on the same track and at the same boundary the
            // card draws it (ReserveMark.swift): a density is not a reduced feature set. On the same
            // windows too - the weekly all-models one, the 5h one and the flagship model's, and no
            // other (`PersonalAccount.reserved`).
            .overlay { ReserveMark(reserve: barReserve(metric)) }
    }

    /// The water line this window carries: the account's number where the reserve is held back from
    /// the window, and nothing where it is not, so the hatch and the callout below agree.
    private func barReserve(_ metric: UsageMetric) -> Int {
        PersonalAccount.reserved(metric.kind, isHeadline: metric.id == facts.headlineID)
            ? facts.reservePercent : 0
    }

    /// The window's name and its own reset, countdown and exact time both, the words the card's
    /// own reset hover gives, so hovering a row answers exactly what reading a card does.
    private func meterHelp(_ metric: UsageMetric) -> String {
        let name = L(metric.label)
        var text = name
        if let reset = usage.resetPassed(metric) ? L("Reset passed, awaiting refresh")
            : UsageFormat.resetHover(metric.resetsAt) {
            text += " · \(reset)"
        }
        // What the hatching at the end of the track is. The card can afford to let the mark speak
        // for itself beside a 100pt bar; on a track this short the words have to be somewhere, and this callout is
        // where every other word this row folds away already lives.
        if barReserve(metric) > 0 { text += "\n" + L("Kept for web use") }
        return text
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
        // Air between the last figure and the glyph: without it "61%" and the sparkle touched.
        .padding(.leading, 3)
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

/// A row's meter clusters on the block's shared columns (`PanelGeometry.meterClusterWidths`). Its
/// own minimum is the old fixed width, every window at the shortest track, so the row gives up
/// identity before it gives up meters; anything above that is the room the row has left. It never
/// reports an unbounded width: a nil or infinite proposal answers the minimum.
struct MeterSlots: Layout {
    var slots: Int
    var gap: CGFloat

    /// A cluster at its shortest: minimum track, the 4pt inside the cluster, the figure column.
    static let minimumCluster: CGFloat = AccountListRowView.barWidth + 4 + AccountListRowView.valueWidth

    private func minimumWidth(_ count: Int) -> CGFloat {
        let columns = max(slots, count)
        return CGFloat(columns) * Self.minimumCluster + gap * CGFloat(max(0, columns - 1))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let floor = minimumWidth(subviews.count)
        let width: CGFloat
        if let proposed = proposal.width, proposed.isFinite {
            width = max(proposed, floor)
        } else {
            width = floor
        }
        let height = subviews.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews,
                       cache: inout ()) {
        let widths = PanelGeometry.meterClusterWidths(in: bounds.width, count: subviews.count,
                                                      slots: slots, gap: gap)
        var x = bounds.minX
        for (subview, width) in zip(subviews, widths) {
            subview.place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading,
                          proposal: ProposedViewSize(width: width, height: bounds.height))
            x += width + gap
        }
    }
}
