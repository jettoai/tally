import SwiftUI

/// Which project's activity graph a design capture is holding open (`-TallyTokenGraphPreview
/// atlas`, demo or dev builds only, argument domain so nothing persists): the surface opens on the
/// Tokens tab with that row already unfolded, with no pointer involved.
///
/// It exists for the reason the other capture flags do. The graph is only reachable by clicking a
/// row, so capturing it otherwise means synthesizing mouse events into the app, which takes the
/// user's desktop away from them for as long as the verification runs (the rule and the incident
/// behind it are in ~/.claude/docs/patterns/macos-app-verification.md: a dev-only flag that puts
/// the state on screen IS the sanctioned answer). Same family as `-TallyTooltipPreview`,
/// `-TallyUpdateChip` and `-TallyEmptyStatePreview`. It also makes a marketing capture repeatable:
/// the same command opens the same row every time, where a click depends on where the row landed.
///
/// It names ONE project rather than opening every row, because the capture is of a graph and a
/// surface with fifteen of them stacked is a capture of a scroll view.
enum TokenGraphPreview {
    /// The project the flag names, or nil on any normal launch.
    static var project: String? {
        guard DemoUsage.isActive || BuildVariant.isDev else { return nil }
        let raw = (UserDefaults.standard.string(forKey: "TallyTokenGraphPreview") ?? "")
            .trimmingCharacters(in: .whitespaces)
        return raw.isEmpty ? nil : raw
    }

    /// Whether this is the row the flag names. It matches the name as READ on screen, or the
    /// trailing component of the project's path, because those are the two forms whoever writes the
    /// capture command has in front of them. The pooled row never matches: it does not open at all.
    static func matches(_ row: TokenStatsSummary.ProjectRow) -> Bool {
        guard let target = project?.lowercased(), !row.isOther else { return false }
        return row.name.lowercased() == target
            || row.key.split(separator: "/").last?.lowercased() == target
    }

    /// Whether `-TallyTokenGraphHover` also wants the opened graph's callout on screen: the heaviest
    /// day of the window starts hovered, so a capture shows the hover ring and the callout that a
    /// pointer would have produced.
    ///
    /// The heaviest day rather than a named one, because it is the square a reader's eye goes to
    /// anyway and it needs no second argument to identify; on the demo fixtures it is a fixed day,
    /// so the capture is repeatable. Presence is the switch (any value but a plain "no" turns it
    /// on), and it does nothing on its own: without a row opened by `-TallyTokenGraphPreview` there
    /// is no graph to hover.
    static var hoversPeak: Bool {
        guard project != nil, let raw = UserDefaults.standard.object(forKey: "TallyTokenGraphHover")
        else { return false }
        return !["no", "false", "0", ""].contains(String(describing: raw).lowercased())
    }
}

/// The dashboard's Tokens tab: how many tokens this machine's Claude and Codex sessions actually
/// spent, over a chosen window, split by project.
///
/// This is local history, not a provider quota - it comes from the transcripts on disk, so it
/// covers every account together and keeps working when the usage APIs are down. It is deliberately
/// a separate tab rather than another card on the Usage screen: quota answers "can I keep going",
/// tokens answer "where did the work go", and mixing the two made both harder to read.
struct TokenStatsView: View {
    @Bindable var store: TokenStatsStore
    /// The host window's content width, so the tab is exactly as wide as the Usage tab and
    /// switching between them never resizes the window sideways.
    var width: CGFloat

    private static let valueColumn: CGFloat = 62
    /// Narrow enough to read as an annotation on the value rather than a second figure competing
    /// with it, wide enough for "100%".
    private static let shareColumn: CGFloat = 34
    /// The project name's column. Fixed rather than sized to the text so the bars all start on one
    /// line: a ragged left edge on the bars makes lengths impossible to compare, which is the one
    /// thing the bars are for. Fixed at every window width, too - the extra width of a wide window
    /// goes to the bar, which is the column that reads better long, and not to a name column that
    /// would only stand empty beside names of a dozen characters.
    private static let nameColumn: CGFloat = 132
    /// The disclosure arrow's column. Reserved on every project row, the pooled one included, so
    /// the value column stays on one line whether or not a row can open.
    private static let chevronColumn: CGFloat = 10

    /// Which project rows have their activity graph open, by project key (an absolute path, so it
    /// survives the rebuild a range switch causes). View state on purpose: the graph is something
    /// the reader opened while looking, not a setting, and a closed panel starts clean.
    @State private var expandedProjects: Set<String> = []
    /// A need, not a preference - the same rule the rest of the surface follows.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: TallyMetrics.sectionSpacing) {
            rangePicker
            if isRangeEmpty {
                emptyState
            } else {
                headline
                if !store.summary.providers.isEmpty { providers }
                if !store.summary.projects.isEmpty { projects }
            }
            if store.isScanning { scanningNote }
        }
        // The cards take the whole surface, inset by the same 12pt the account grid uses, so the two
        // tabs share a left edge AND a right edge. An earlier version capped the reading column at
        // 800pt to keep a dozen short names from stretching across a four-column window; what that
        // actually bought was a quarter of that window standing empty on the trailing side. The rows
        // do not stretch anyway: every column but the bar is fixed (see `nameColumn`), so the width
        // lands on the one part of the row that reads better long.
        //
        // Both edges are the account grid's, which is also what keeps the crossfade anchored: the
        // tabs swap in place, so a token column that started anywhere else read as the content
        // sliding sideways.
        .padding(12)
        .frame(width: width, alignment: .leading)
    }

    /// A window with nothing in it, as opposed to a window whose numbers have not arrived yet - the
    /// first paint of a cold app has neither, and showing "no usage" there would be a lie.
    private var isRangeEmpty: Bool { store.hasScanned && store.summary.isEmpty }

    /// Deliberately the quieter of the two segmented controls on screen. The tab picker above it
    /// chooses what the window is about; this one only narrows what is already there, so it is the
    /// compact size and hugs its content at the trailing edge instead of spanning the width.
    private var rangePicker: some View {
        NeutralSegmentedPicker(selection: $store.range,
                               options: TokenStatsRange.allCases,
                               size: .small) { $0.label }
            .frame(maxWidth: .infinity, alignment: .trailing)
    }

    // MARK: Headline

    /// The grand total leads: people quote and compare that sum ("this product burned a billion
    /// tokens"), and ccusage, the de-facto peer tool, headlines the same figure. The four classes
    /// stay one glance away under a rule, because the honest composition (cache reads dominate by
    /// an order of magnitude) is exactly what a single number hides.
    private var headline: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 0) {
                Text(L("Total tokens"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(UsageFormat.compactCount(store.summary.totals.total))
                    .font(.system(size: 26, weight: .semibold))
                    .monospacedDigit()
            }
            Divider()
            HStack(alignment: .top, spacing: 0) {
                column(L("Input"), store.summary.totals.input)
                column(L("Cache write"), store.summary.totals.cacheWrite)
                column(L("Cache read"), store.summary.totals.cacheRead)
                column(L("Output"), store.summary.totals.output)
            }
        }
        .padding(.horizontal, TallyMetrics.cardPaddingH)
        .padding(.vertical, TallyMetrics.cardPaddingV)
        .frame(maxWidth: .infinity, alignment: .leading)
        .tallyCard()
    }

    private func column(_ label: String, _ value: Int64) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            Text(UsageFormat.compactCount(value))
                .font(.callout.weight(.medium))
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Providers

    private var providers: some View {
        VStack(spacing: 7) {
            ForEach(store.summary.providers) { row in
                HStack(spacing: 6) {
                    ProviderIconView(providerID: row.providerID, size: 12)
                    Text(ProviderCatalog.displayName(for: row.providerID))
                        .font(.footnote)
                        .foregroundStyle(Color.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    share(row.share)
                    value(row.totals.total)
                    // A provider row has nothing to unfold, but it still reserves the disclosure
                    // column: the two cards' figures sit on one vertical line, and a column that
                    // existed on only one of them would knock them apart by exactly its width.
                    disclosureSpacer
                }
            }
        }
        .padding(.horizontal, TallyMetrics.cardPaddingH)
        .padding(.vertical, TallyMetrics.cardPaddingV)
        .frame(maxWidth: .infinity, alignment: .leading)
        .tallyCard()
    }

    // MARK: Projects

    /// `name · bar · share · value · disclosure`, the same left-to-right grammar the account meters
    /// use, so the two tabs read as one product. The bar is a share of the total, not a limit, so it
    /// carries no severity colour - nothing here can be "too high" - and the percentage beside it is
    /// the same quantity in figures, for the rows too small to compare by eye. Providers use the
    /// same three trailing columns, the disclosure one reserved but empty, so the numbers line up
    /// across both cards.
    private var projects: some View {
        VStack(alignment: .leading, spacing: TallyMetrics.headerToCard) {
            Text(L("Projects"))
                .font(.caption)
                .foregroundStyle(.secondary)
            VStack(spacing: 7) {
                ForEach(store.summary.projects) { project in
                    projectRow(project)
                }
            }
        }
        .padding(.horizontal, TallyMetrics.cardPaddingH)
        .padding(.vertical, TallyMetrics.cardPaddingV)
        .frame(maxWidth: .infinity, alignment: .leading)
        .tallyCard()
    }

    /// One project: the row itself, and its year of daily activity when it is open.
    ///
    /// The pooled "Other" row is the one that never opens, and shows no arrow to say so. Its
    /// members are whatever fell outside the top of THIS range, so the row is not one subject over
    /// time and a year-long series drawn for it would be a different set of projects every week.
    @ViewBuilder
    private func projectRow(_ project: TokenStatsSummary.ProjectRow) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if project.isOther {
                rowBody(project)
            } else {
                Button { toggle(project.key) } label: { rowBody(project) }
                    .buttonStyle(.plain)
            }
            if isExpanded(project) {
                TokenActivityHeatmapView(dailyTotals: store.dailyTotals(forProject: project.key),
                                         today: LocalDayStamper.today(),
                                         width: cardContentWidth,
                                         // Only the row a capture opened, never one the reader
                                         // opened themselves.
                                         hoverPeak: TokenGraphPreview.hoversPeak
                                                    && TokenGraphPreview.matches(project))
                    .padding(.bottom, 2)
            }
        }
    }

    private func rowBody(_ project: TokenStatsSummary.ProjectRow) -> some View {
        HStack(spacing: 8) {
            Text(project.name)
                .font(.footnote)
                .foregroundStyle(project.isOther ? Color.secondary.opacity(0.7) : Color.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: Self.nameColumn, alignment: .leading)
                .tallyTooltip(project.isOther ? L("Scratch directories and sessions with no project")
                                      : project.key)
            shareBar(project.share)
            share(project.share)
            value(project.totals.total)
            chevron(project)
        }
        // The whole row is the target, not just the arrow: a 10pt glyph is a poor thing to aim at,
        // and every other part of the row belongs to the same project anyway.
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func chevron(_ project: TokenStatsSummary.ProjectRow) -> some View {
        if project.isOther {
            disclosureSpacer
        } else {
            Image(systemName: "chevron.right")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.tertiary)
                .rotationEffect(.degrees(isExpanded(project) ? 90 : 0))
                .frame(width: Self.chevronColumn, alignment: .trailing)
        }
    }

    /// The disclosure column, held open by a row that has nothing to disclose.
    private var disclosureSpacer: some View {
        Color.clear.frame(width: Self.chevronColumn, height: 1)
    }

    /// Whether this row's graph is showing: because the reader opened it, or because a design
    /// capture asked for it (`TokenGraphPreview`).
    private func isExpanded(_ project: TokenStatsSummary.ProjectRow) -> Bool {
        expandedProjects.contains(project.key) || TokenGraphPreview.matches(project)
    }

    private func toggle(_ key: String) {
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) {
            if expandedProjects.contains(key) { expandedProjects.remove(key) }
            else { expandedProjects.insert(key) }
        }
    }

    /// The width inside a card: the surface, less this view's own inset and the card's padding.
    /// The activity graph draws itself to a width rather than to a square size, so it needs the
    /// real figure and not an approximation of it.
    private var cardContentWidth: CGFloat {
        max(120, width - 24 - 2 * TallyMetrics.cardPaddingH)
    }

    /// A track that takes whatever width is left, the same shape the account meters draw, so the
    /// two tabs read as one product and the fill is worth comparing across rows.
    private func shareBar(_ share: Double) -> some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(Color.accentColor.opacity(0.75))
                    .frame(width: max(2, proxy.size.width * min(1, max(0, share))))
            }
        }
        .frame(height: 5)
    }

    private func share(_ value: Double) -> some View {
        Text(UsageFormat.sharePercent(value))
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.tertiary)
            .frame(width: Self.shareColumn, alignment: .trailing)
    }

    private func value(_ tokens: Int64) -> some View {
        Text(UsageFormat.compactCount(tokens))
            .font(.footnote.weight(.semibold).monospacedDigit())
            .frame(width: Self.valueColumn, alignment: .trailing)
    }

    // MARK: Empty and scanning

    /// A window with no sessions in it says so in the space the cards would have used, rather than
    /// drawing a card full of zeros - which reads as a broken scan instead of a quiet week.
    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "chart.bar.xaxis")
                .font(.title3)
                .foregroundStyle(.tertiary)
            Text(L("No token usage recorded in this range."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }

    /// The first sweep reads the whole history, which takes a moment; later ones skip every file
    /// that has not changed and this is gone before it is noticed.
    private var scanningNote: some View {
        Label {
            Text(L("Reading local transcripts…"))
        } icon: {
            ProgressView().controlSize(.small)
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
}
