import SwiftUI

/// One account as a single 40pt line, for the Detailed density (`PanelDensity.list`): the identity
/// on the left (name, plan pill, and the marks and launch controls a card carries, shrunk to icons),
/// every usage window as a small bar plus its percentage and reset on a fixed block of meter cells
/// on the right. Roughly a fifth of a card's height, which is the whole point: past half a dozen
/// accounts the card grid outgrows the display and the panel becomes a scroll rather than a glance.
/// An account at its limit lies on a faint red band with a red edge bar, so it is found without
/// reading.
///
/// It hides words, never facts. Every window a card shows is here (the same `showAllModels` filter
/// decides), every state a card can be in has a mark here, and the words the card spells out (the
/// window's name, the exact reset time, what the pin does) move into hover tooltips rather than
/// disappearing (B-650: the row never gets a second line). The reset countdown sits on the line
/// itself, one unit wide (B-3511).
struct AccountListRowView: View {
    let usage: AccountUsage
    @Bindable var settings: SettingsStore
    /// Show a grip glyph on hover - the drag-affordance for surfaces where the row can be reordered.
    var showsDragHandle: Bool = false
    /// Full-brightness handle regardless of hover - the floating drag preview sets this, so the grip
    /// never blinks out mid-drag.
    var handleProminent: Bool = false
    /// The meter columns of this row's block (`MeterColumns.displayBlock`): each window stands in the
    /// column of its kind, so a kind keeps one x down the block. Empty means this row's own windows.
    var meterColumns: [MeterColumnKey] = []
    /// Whether this row is the provider's auto pick, answered once for the whole block by its list
    /// (`AccountFacts.autoPickID`). Nil asks on its own, which is what the floating drag preview does.
    var isAutoPick: Bool? = nil
    /// The columns whose reset countdown is the soonest of this row's provider, answered once for the
    /// whole block by the grid. Empty lights nothing, which is what the floating
    /// drag preview does.
    var soonestResets: Set<MeterColumnKey> = []
    /// Draw the provider's mark before the name: for a card that holds several providers' rows, where
    /// nothing above the rows says whose they are.
    var showsProviderIcon: Bool = false

    @State private var isHovering = false
    @State private var redeemBusy = false
    @State private var redeemOutcome: CodexAppServerClient.RedeemOutcome?

    /// The card's own answers, shared rather than re-derived (see `AccountFacts`).
    var facts: AccountFacts { AccountFacts(usage: usage, settings: settings) }

    /// The gap between the meter columns.
    static let meterGap: CGFloat = PanelStyle.meterGap

    /// The SHORTEST a meter track gets. The track takes the full width of the cell it is in (72pt
    /// for up to three windows, `PanelStyle.meterCellWidth`); this floor is what a fourth window
    /// squeezes the cells to.
    nonisolated static let barWidth: CGFloat = 14
    static let barHeight: CGFloat = PanelStyle.barHeight
    /// The gap between a cell's figure line and its track.
    nonisolated static let clusterGap: CGFloat = 5
    /// The percentage: "100%" at 13.5pt 650 with tabular digits (40.7pt). It may scale to 0.8 when a
    /// fourth window squeezes the cell.
    nonisolated static let valueWidth: CGFloat = 41
    /// The reset countdown column: one unit ("29d", "23h", "59m") at 11pt (24.6pt at the widest,
    /// semibold), a fixed width so a minute tick never moves the figure beside it.
    nonisolated static let resetWidth: CGFloat = 26
    /// The badge slot, reserved whether or not this row has a badge, so the pin circles stay in one
    /// column instead of stepping left and right with the smart pick.
    static let badgeWidth: CGFloat = 11

    /// Each of this row's windows by the column it belongs in, and the columns it lays them on.
    private var ownKeys: [MeterColumnKey] { facts.meterKeys }
    private var columnKeys: [MeterColumnKey] { meterColumns.isEmpty ? MeterColumns.displayBlock([ownKeys]) : meterColumns }

    var body: some View {
        HStack(spacing: Self.meterGap) {
            identityColumn.frame(maxWidth: .infinity, alignment: .leading)
            if facts.isRenewingLogin {
                renewingTail
            } else if facts.isHardError {
                errorTail
            } else {
                // The meters take a fixed block (`PanelStyle.meterBlockWidth`), the same on the
                // card's column titles, so a window keeps one x down the card. The identity takes
                // whatever is left: a long nickname truncates rather than pushing a meter off the row.
                MeterSlots(columns: columnKeys.count, gap: Self.meterGap) {
                    ForEach(Array(zip(facts.orderedMetrics, ownKeys)), id: \.0.id) { metric, key in
                        meterCluster(metric, emphasized: soonestResets.contains(key))
                            .layoutValue(key: MeterColumn.self, value: columnKeys.firstIndex(of: key))
                    }
                }
                .frame(width: PanelStyle.meterBlockWidth(columns: columnKeys.count))
                .anchorPreference(key: PanelHintTargetKey.self, value: .bounds) { [usage.id: $0] }
            }
        }
        .padding(.horizontal, PanelStyle.rowInsetH)
        .frame(height: PanelStyle.rowHeight)
        .font(.caption2)
        .lineLimit(1)
        .background {
            if isAtLimit {
                RoundedRectangle(cornerRadius: PanelStyle.rowRadius, style: .continuous).fill(PanelStyle.hotRow)
            }
        }
        .overlay(alignment: .leading) {
            if isAtLimit {
                // Inside the wash's rounded end rather than on its edge.
                UnevenRoundedRectangle(bottomTrailingRadius: 3, topTrailingRadius: 3, style: .continuous)
                    .fill(PanelStyle.red)
                    .frame(width: PanelStyle.wallBarWidth)
                    .padding(.vertical, 7)
                    .padding(.leading, 2)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .leading) {
            if showsDragHandle {
                ReorderHandle(bright: true)
                    .font(.system(size: 8))
                    .opacity(isHovering || handleProminent ? 1 : 0)
                    .padding(.leading, 2)
            }
        }
        .contentShape(Rectangle())
        .onHover { if showsDragHandle { isHovering = $0 } }
        // Same menu the card right-clicks to, from the same values: the row is a density, not a
        // reduced feature set.
        .contextMenu {
            AccountActionsMenu(accountID: usage.id, providerID: usage.providerID,
                               label: facts.label, home: facts.configHome)
        }
    }

    /// Some window is spent and has not reset yet. Not while a redeemed reset settles: the number is
    /// seconds from being replaced, so that is a wait rather than a wall.
    private var isAtLimit: Bool {
        !facts.isSettlingReset && facts.orderedMetrics.contains { $0.usedPercent >= 100 && !usage.resetPassed($0) }
    }

    /// The identity and the marks that travel with it. The marks stay on the identity side (not the
    /// meters') so a row that happens to carry a warning triangle never pushes its own figures.
    private var identityColumn: some View {
        HStack(spacing: 6) {
            identity
            // The usage marks are drawn on every row, the one that never loaded included: the
            // stale mark needs `isStale`, which a never-loaded row does not have
            // (`AccountFacts.isHardError`), and the reset mark is not a reading, so an account
            // whose first poll failed still shows its "?" (codex review of dcbc04f). The login
            // marks stay outside for their own reason: `lastGood` survives a launch only for readings
            // under a day old (LastGoodCache), so a signed-out account with none IS the hard-error
            // row until the first good poll, which is precisely when the renewal button is worth
            // having on screen.
            Group {
                usageMarks
                loginMarks
                trailingControls
            }
            .layoutPriority(1)
        }
        .overlay(alignment: .trailing) { hoverPin }
    }

    /// Name and plan pill, carrying the same identity callout (signed-in address over plan and
    /// config home), because two accounts that answer with one address are exactly as
    /// indistinguishable here as they are on a card.
    private var identity: some View {
        // The room beside the meters is about 110pt: the plan pill is the first thing to give it up
        // when the whole name and the pill do not fit together, the name truncating only after that.
        ViewThatFits(in: .horizontal) {
            identityLine(showsPlan: usage.planName != nil, fixesName: true)
            identityLine(showsPlan: false, fixesName: false)
        }
        .accessibilityElement(children: .combine)
        .tallyTooltip(facts.identityEmail, detail: facts.identityDetail,
                      forced: facts.forcesIdentityTooltip)
    }

    private func identityLine(showsPlan: Bool, fixesName: Bool) -> some View {
        HStack(spacing: 6) {
            if showsProviderIcon {
                ProviderIconView(providerID: usage.providerID, size: 12)
            }
            Text(facts.label)
                .font(PanelStyle.font(13.5, 600))
                .foregroundStyle(PanelStyle.text)
                .lineLimit(1)
                .fixedSize(horizontal: fixesName, vertical: false)
            if showsPlan, let plan = usage.planName {
                PlanBadge(text: plan, providerID: usage.providerID)
            }
        }
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
                .font(.system(size: 11))
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
                .foregroundStyle(outcome == .redeemed ? TallyColor.normal : PanelStyle.text2)
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
        .foregroundStyle(PanelStyle.text2)
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
                    .font(.system(size: 11))
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
                .font(.system(size: 11))
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
                             ?? AnyShapeStyle(PanelStyle.text2))
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
    ///
    /// The badge is there only on the row that carries one (the smart pick, the pinned account), and
    /// the pin circle only while the row is pinned or hovered: 110pt is all the room a name and its
    /// plan pill have beside the meter cells, and a circle on every row at rest took it from them.
    /// On hover the circle is laid OVER the end of the identity (`identityColumn`) rather than into
    /// it, so a pointer crossing the rows never reflows a name or drops a plan pill.
    @ViewBuilder
    private var trailingControls: some View {
        if facts.hasSiblings, facts.launchMode != .off {
            if facts.isPinnedActive || carriesBadge { badgeSlot }
            if facts.isPinnedActive { pinToggle }
        }
    }

    private var carriesBadge: Bool {
        facts.launchMode == .auto && (isAutoPick ?? facts.isAutoPick)
    }

    @ViewBuilder
    private var hoverPin: some View {
        if isHovering, facts.hasSiblings, facts.launchMode != .off, !facts.isPinnedActive {
            pinToggle
                .padding(.horizontal, 3)
                .background(Capsule().fill(PanelStyle.cardSolid))
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
