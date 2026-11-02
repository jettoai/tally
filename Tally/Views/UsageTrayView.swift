import SwiftUI

// THE TRAY PREVIEW LAYOUT (`-TallyUsageLayout tray`, B-2625): one small tile per account, the 5h and
// flagship windows it has as upright bars, the week as a bar along the bottom, and the name, with a
// number only when the tightest window is tight.
// Reached only through the launch flag, so the default panel never draws it.
//
// The tightest window and its severity come from `AccountFacts.bindingWindow` / `bindingSeverity`, the
// same answer the smart pick judges by; this file never takes a minimum or spells a threshold.
// Not draggable by design: this preview mounts no `reorderGesture`.

extension PopoverRootView {
    // Tile size, gap and tiles per row come from UsageLayout.Tray, fitted to the 356pt region (B-3461).
    private static let trayTileWidth = UsageLayout.Tray.tileWidth
    private static let trayTileHeight = UsageLayout.Tray.tileHeight
    private static let trayGap = UsageLayout.Tray.gap

    /// Every provider's heading and tiles, in the order and folding the default layout uses.
    @ViewBuilder
    var trayAccounts: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(accountGroups) { group in trayGroup(group) }
        }
    }

    private func trayGroup(_ group: AccountGroup) -> some View {
        let providerID = group.providerID
        // The same summaries `providerSection` draws its pools from.
        let summaries = fleetSummaries.filter { $0.providerID == providerID && !displayedPools($0).isEmpty }
        let split = summaries.filter { $0.planTier != nil }
        let autoPick = AccountFacts.autoPickID(providerID: providerID)
        let columns = UsageLayout.Tray.columns
        return VStack(alignment: .leading, spacing: 6) {
            trayHeading(group, pool: split.isEmpty ? summaries.first : nil)
            if !group.isFolded {
                if split.count > 1 {
                    // Several plans: one section each, stacked (side by side no tile row fits the
                    // narrowest region), its own pool on top, then its tiles.
                    ForEach(split, id: \.id) { summary in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 5) {
                                (Text(summary.planTier?.name ?? L("Unknown plan")).foregroundStyle(Color.secondary)
                                 + Text(" ×\(summary.accountCount)").foregroundStyle(.tertiary))
                                    .font(.caption).lineLimit(1).fixedSize()
                                trayPool(summary)
                            }
                            trayGrid(group.items.filter { $0.planName == summary.planTier?.name },
                                     columns: columns, autoPick: autoPick)
                        }
                    }
                    // An account on a plan no section names must still be on screen.
                    let named = Set(split.map { $0.planTier?.name })
                    let rest = group.items.filter { !named.contains($0.planName) }
                    if !rest.isEmpty { trayGrid(rest, columns: columns, autoPick: autoPick) }
                } else {
                    trayGrid(group.items, columns: columns, autoPick: autoPick)
                }
            }
        }
    }

    /// Provider identity, the fold chevron, the micro bar legend, and (for an unsplit provider) the
    /// pooled weekly bar at the right. A click anywhere on it folds, as in the default layout.
    private func trayHeading(_ group: AccountGroup, pool: FleetSummary?) -> some View {
        let providerID = group.providerID
        let foldable = pooledProviderIDs.contains(providerID)
        // In the narrowest region the refill does not fit beside the legend: it goes, the level stays.
        return ViewThatFits(in: .horizontal) {
            trayHeadingRow(group, pool: pool, foldable: foldable, showsRefill: true)
            trayHeadingRow(group, pool: pool, foldable: foldable, showsRefill: false)
        }
        .fixedSize(horizontal: false, vertical: true)
        .contentShape(Rectangle())
        .onTapGesture { if foldable { settings.toggleCollapsed(providerID) } }
    }

    private func trayHeadingRow(_ group: AccountGroup, pool: FleetSummary?, foldable: Bool,
                                showsRefill: Bool) -> some View {
        let providerID = group.providerID
        return HStack(spacing: 6) {
            providerLabel(providerID, count: group.items.count).font(.footnote)
            if foldable { foldChevron(providerID) }
            HStack(spacing: 4) {
                // The legend glyph mirrors a tile: two upright bars over one along the bottom.
                VStack(spacing: 1.5) {
                    HStack(spacing: 1.5) {
                        ForEach(0..<2, id: \.self) { _ in
                            RoundedRectangle(cornerRadius: 1).fill(Color.secondary.opacity(0.6))
                                .frame(width: 3, height: 7)
                        }
                    }
                    RoundedRectangle(cornerRadius: 1).fill(Color.secondary.opacity(0.6))
                        .frame(width: 10, height: 2)
                }
                Text(verbatim: LayoutWindows.names.joined(separator: " · "))
                    .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
            }
            .accessibilityHidden(true)
            Spacer(minLength: 6)
            if let pool { trayPool(pool, showsRefill: showsRefill) }
        }
    }

    /// One pool as a short bar, what is left in it and when the next refill lands.
    @ViewBuilder
    private func trayPool(_ summary: FleetSummary, showsRefill: Bool = true) -> some View {
        if let pool = displayedPools(summary).first {
            let remaining = pool.averageRemaining
            let tint = MetricSeverity.fromUsedPercent(100 - remaining).color
            HStack(spacing: 5) {
                ZStack(alignment: .leading) {
                    Capsule().fill(LayoutTint.track)
                    Capsule().fill(tint).frame(width: max(2, 60 * remaining / 100))
                }
                .frame(width: 60, height: 5)
                Text(verbatim: "\(Int(remaining.rounded()))%")
                    .font(.caption2.weight(.semibold).monospacedDigit()).lineLimit(1).fixedSize()
                if showsRefill, let refill = pool.refills.first {
                    Text(verbatim: "↻ " + UsageFormat.countdownBody(refill.at))
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .tallyTooltip(poolDisplayName(pool))
        }
    }

    /// Tiles in rows of `columns`, a short last row padded so the columns keep their lines.
    private func trayGrid(_ accounts: [AccountUsage], columns: Int, autoPick: String?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(rows(accounts, columns: columns)) { row in
                HStack(spacing: Self.trayGap) {
                    ForEach(row.items) { usage in
                        let facts = AccountFacts(usage: usage, settings: settings)
                        TrayTile(facts: facts,
                                 isSmartPick: facts.hasSiblings && facts.launchMode == .auto && autoPick == usage.id,
                                 size: CGSize(width: Self.trayTileWidth, height: Self.trayTileHeight))
                    }
                }
            }
        }
    }
}

/// One account as a tile. Click opens the detail card; the context menu pins or releases it.
private struct TrayTile: View {
    let facts: AccountFacts
    let isSmartPick: Bool
    let size: CGSize

    @State private var showsDetail = false

    var body: some View {
        let severity = facts.bindingSeverity
        let binding = facts.bindingWindow
        let shape = RoundedRectangle(cornerRadius: TallyMetrics.calloutRadius, style: .continuous)
        let windows = LayoutWindows(facts.usage)
        VStack(alignment: .leading, spacing: UsageLayout.Tray.rowGap) {
            HStack(spacing: UsageLayout.Tray.rowSpacing) {
                if !windows.upright.isEmpty { LayoutMicroBars(windows: windows, binding: binding) }
                Text(facts.label).font(.system(size: 12, weight: .medium)).lineLimit(1).minimumScaleFactor(0.8)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                // A number only when the tightest window is tight: a healthy row stays quiet.
                if let binding, severity == .warning || severity == .critical {
                    Text(verbatim: "\(Int(binding.remainingPercent.rounded()))")
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(layoutNumberInk(severity))
                }
            }
            .frame(height: UsageLayout.Tray.rowHeight)
            // The week along the bottom, always drawn: a plan without one, or a tile with no reading at
            // all, gets LayoutBar's dashed outline here, so no tile is ever blank.
            LayoutBar(metric: windows.weekly, length: UsageLayout.Tray.contentWidth,
                      thickness: UsageLayout.Tray.weekThickness,
                      isBinding: LayoutWindows.isBinding(windows.weekly, binding))
        }
        .padding(.horizontal, UsageLayout.Tray.inset)
        .padding(.top, UsageLayout.Tray.topInset)
        .padding(.bottom, UsageLayout.Tray.bottomInset)
        .frame(width: size.width, height: size.height)
        .background(shape.fill(Color.primary.opacity(0.05)))
        .overlay(shape.strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
        .overlay { if isSmartPick { shape.strokeBorder(TallyColor.ai, lineWidth: 1.5) } }
        .overlay(alignment: .topLeading) {
            if isSmartPick {
                Text(verbatim: "\u{2726}").font(.system(size: 8)).foregroundStyle(TallyColor.ai).padding(2)
            }
        }
        .overlay(alignment: .topTrailing) {
            if facts.isPinnedActive {
                Circle().fill(Color.secondary).frame(width: 5, height: 5).padding(4)
            }
        }
        .contentShape(shape)
        .onTapGesture { showsDetail.toggle() }
        .popover(isPresented: $showsDetail) { UsageDetailCard(facts: facts, isSmartPick: isSmartPick) }
        .tallyTooltip(facts.markOwner, detail: facts.identityDetail)
        .contextMenu {
            if facts.hasSiblings {
                Button(facts.isPinnedActive ? L("Pinned. Click again to go back to Smart.")
                                            : L("Set as launch account")) { facts.togglePin() }
                    .disabled(!facts.canTogglePin)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(facts.label)
    }
}
