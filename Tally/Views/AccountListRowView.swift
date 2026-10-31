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
    /// Whether this row is the provider's auto pick, answered once for the whole block by its list
    /// (`AccountFacts.autoPickID`). Nil asks on its own, which is what the floating drag preview does.
    var isAutoPick: Bool? = nil

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
    static let barHeight: CGFloat = 4
    /// The percentage column: "100%" at caption size, so the figures line up down the panel the way
    /// the cards' do.
    nonisolated static let valueWidth: CGFloat = 32
    /// The badge slot, reserved whether or not this row has a badge, so the pin circles stay in one
    /// column instead of stepping left and right with the smart pick.
    static let badgeWidth: CGFloat = 11

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
            // marks stay outside for their own reason: `lastGood` survives a launch only for readings
            // under a day old (LastGoodCache), so a signed-out account with none IS the hard-error
            // row until the first good poll, which is precisely when the renewal button is worth
            // having on screen.
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
        if let notice = facts.sharedLoginNotice {
            Image(systemName: "person.2.fill")
                .font(.system(size: 9))
                .foregroundStyle(TallyColor.warning)
                .tallyTooltip(notice, detail: UsageStore.sharedLoginDetail,
                              forced: DemoUsage.isActive && TallyTooltip.previewForced(.sharedlogin))
                .accessibilityLabel(notice)
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

    /// The launch affordances, in the card's order and with the card's rules: the mode badge as a
    /// bare glyph (its words move to the tooltip), then the one circle that pins and unpins.
    @ViewBuilder
    private var trailingControls: some View {
        if facts.hasSiblings, facts.launchMode != .off {
            badgeSlot
            pinToggle
        }
        if showsDragHandle {
            ReorderHandle(bright: isHovering || handleProminent)
        }
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
