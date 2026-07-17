import SwiftUI

/// One account's card: provider + account label + plan, the headline (top-tier) meter prominent,
/// then the remaining windows below. Nested spacing gives the account identity, its headline, and its
/// secondary windows distinct rhythm rather than one flat stack.
struct AccountCardView: View {
    let usage: AccountUsage
    @Bindable var settings: SettingsStore
    /// Show a grip glyph on hover - the drag-affordance for surfaces where the card can be reordered.
    var showsDragHandle: Bool = false
    /// Stretch the card surface to fill the row height, so side-by-side cards read as one aligned row.
    var fillsRowHeight: Bool = false

    @State private var isHovering = false

    private var label: String {
        settings.displayLabel(accountID: usage.id, fallback: usage.accountLabel)
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

    /// A hard error (this account has never loaded) collapses to a compact error + Retry. A stale
    /// account (a failed refresh over previously-good numbers) keeps its metrics readable - the
    /// "Outdated" badge in the header carries the state, so the numbers aren't dimmed away.
    private var isHardError: Bool { usage.error != nil && !usage.isStale }

    /// The plan exposes only a single weekly window (e.g. Codex on ChatGPT Plus) - worth noting so a
    /// missing session/model row doesn't read as a bug.
    private var weeklyOnly: Bool {
        usage.metrics.count == 1 && usage.metrics.first?.kind == .weeklyAll
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if isHardError {
                errorRow
            } else {
                if let headline = usage.headline {
                    MetricRowView(metric: headline, mode: settings.displayMode, prominent: true)
                }
                if !secondaryMetrics.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(secondaryMetrics) { metric in
                            MetricRowView(metric: metric, mode: settings.displayMode)
                        }
                    }
                }
                if weeklyOnly {
                    Text(L("Weekly quota only"))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(TallyMetrics.cardPaddingH)
        // maxHeight applies BEFORE the card background so the rounded surface itself stretches; the
        // row bounds the proposal via `.fixedSize(vertical:)`, so infinity here is never unbounded.
        .frame(maxHeight: fillsRowHeight ? .infinity : nil, alignment: .top)
        .tallyCard()
        .onHover { if showsDragHandle { isHovering = $0 } }
    }

    private var header: some View {
        HStack(spacing: 7) {
            ProviderIconView(providerID: usage.providerID, size: 16)
            Text(label)
                .font(.subheadline.weight(.semibold))
            if let plan = usage.planName {
                Text(plan)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if usage.isStale {
                Label(L("Outdated"), systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(TallyColor.warning)
                    .help(usage.error ?? "")
            }
            Spacer()
            if showsDragHandle {
                Image(systemName: "line.3.horizontal")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .opacity(isHovering ? 1 : 0)
                    .accessibilityLabel(L("Drag to reorder"))
                    .help(L("Drag to reorder"))
            }
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
