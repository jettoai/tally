import SwiftUI

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
    /// thing the bars are for.
    private static let nameColumn: CGFloat = 132
    /// The widest the reading column gets. The window follows the account grid's column choice and
    /// can reach 1108pt, which no table of a dozen short names has anything to do with; past this
    /// the rows are just stretched.
    private static let contentWidth: CGFloat = 800

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
        // The reading column is capped and centred in whatever width the account grid chose, so a
        // four-column window does not stretch a dozen short project names across 1108pt. The tab
        // itself still fills the window, so switching tabs never resizes it sideways.
        .frame(width: min(width - 24, Self.contentWidth))
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .frame(width: width)
    }

    /// A window with nothing in it, as opposed to a window whose numbers have not arrived yet - the
    /// first paint of a cold app has neither, and showing "no usage" there would be a lie.
    private var isRangeEmpty: Bool { store.hasScanned && store.summary.isEmpty }

    /// Deliberately the quieter of the two segmented controls on screen. The tab picker above it
    /// chooses what the window is about; this one only narrows what is already there, so it is the
    /// compact size and hugs its content at the trailing edge instead of spanning the width.
    private var rangePicker: some View {
        Picker("", selection: $store.range) {
            ForEach(TokenStatsRange.allCases) { range in
                Text(range.label).tag(range)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .fixedSize()
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
                }
            }
        }
        .padding(.horizontal, TallyMetrics.cardPaddingH)
        .padding(.vertical, TallyMetrics.cardPaddingV)
        .frame(maxWidth: .infinity, alignment: .leading)
        .tallyCard()
    }

    // MARK: Projects

    /// `name · bar · share · value`, the same left-to-right grammar the account meters use, so the
    /// two tabs read as one product. The bar is a share of the total, not a limit, so it carries no
    /// severity colour - nothing here can be "too high" - and the percentage beside it is the same
    /// quantity in figures, for the rows too small to compare by eye. Providers use the same two
    /// trailing columns, so the numbers line up across both cards.
    private var projects: some View {
        VStack(alignment: .leading, spacing: TallyMetrics.headerToCard) {
            Text(L("Projects"))
                .font(.caption)
                .foregroundStyle(.secondary)
            VStack(spacing: 7) {
                ForEach(store.summary.projects) { project in
                    HStack(spacing: 8) {
                        Text(project.name)
                            .font(.footnote)
                            .foregroundStyle(project.isOther ? Color.secondary.opacity(0.7) : Color.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(width: Self.nameColumn, alignment: .leading)
                            .help(project.isOther ? L("Scratch directories and sessions with no project")
                                                  : project.key)
                        shareBar(project.share)
                        share(project.share)
                        value(project.totals.total)
                    }
                }
            }
        }
        .padding(.horizontal, TallyMetrics.cardPaddingH)
        .padding(.vertical, TallyMetrics.cardPaddingV)
        .frame(maxWidth: .infinity, alignment: .leading)
        .tallyCard()
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
