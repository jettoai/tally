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
            : Set(store.discoveredAccounts.compactMap { $0.launchHome != nil ? $0.id : nil })
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
                // Banked rate-limit resets (Codex reset banking): read and shown, never spent -
                // redeeming one is the user's own economic decision, made in the official CLI.
                if let resets = usage.resetCreditsAvailable, resets > 0 {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 9))
                        Text(verbatim: "\(resets) ")
                            + Text(L(resets == 1 ? "reset available" : "resets available"))
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .padding(TallyMetrics.cardPaddingH)
        // maxHeight applies BEFORE the card background so the rounded surface itself stretches; the
        // row bounds the proposal via `.fixedSize(vertical:)`, so infinity here is never unbounded.
        .frame(maxHeight: fillsRowHeight ? .infinity : nil, alignment: .top)
        .tallyCard()
        .onHover { if showsDragHandle { isHovering = $0 } }
        // Click cycles the launch pin: pin this account (Manual), click again for Auto. A plain
        // tap never conflicts with the container's reorder drag (4pt minimum distance) and child
        // buttons still win their own hits. No-op for single-account providers.
        .onTapGesture { toggleLaunchPin() }
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
            if hasSiblings {
                switch launchMode {
                // The pinned card carries a labelled badge (mode legible at a glance, in a colour
                // distinct from the auto badge); the OTHER cards keep the hollow radio as the
                // click-to-choose affordance.
                case .manual: if isPinnedActive { manualBadge } else { pinControl }
                case .auto: if isAutoPick { autoBadge }
                case .off: EmptyView()
                }
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

    /// Card click: pin this account (switching the provider to Manual); clicking the already
    /// pinned card releases back to Auto - one gesture covers the whole choose/release loop.
    private func toggleLaunchPin() {
        guard hasSiblings else { return }
        let policy = LaunchPolicyStore.shared
        if isPinnedActive {
            policy.setMode(usage.providerID, .auto)
        } else {
            let home = UsageStore.shared.discoveredAccounts.first { $0.id == usage.id }?.launchHome
            policy.pin(usage.providerID, accountID: usage.id, home: home)
        }
    }

    /// Manual mode: a radio per card - the filled one is where new sessions launch; click to move it.
    private var pinControl: some View {
        Button {
            let home = UsageStore.shared.discoveredAccounts.first { $0.id == usage.id }?.launchHome
            LaunchPolicyStore.shared.pin(usage.providerID, accountID: usage.id, home: home)
        } label: {
            Image(systemName: isPinnedActive ? "circle.inset.filled" : "circle")
                .font(.caption)
                .foregroundStyle(isPinnedActive ? Color.accentColor : Color.secondary)
        }
        .buttonStyle(.plain)
        .help(L("Set as launch account"))
        .accessibilityLabel(L("Set as launch account"))
    }

    /// Manual mode, pinned card: warm colour + pin glyph, deliberately distinct from the cool
    /// auto badge - a human override should not look like the machine's pick.
    private var manualBadge: some View {
        HStack(spacing: 3) {
            Image(systemName: "pin.fill").font(.system(size: 8))
            Text(L("Pinned")).lineLimit(1)
        }
        .fixedSize()   // a badge must never wrap (a two-line capsule broke the header, 2026-07-18)
        .font(.caption2.weight(.semibold))
        .foregroundStyle(Color.orange)
        .padding(.horizontal, 5).padding(.vertical, 1)
        .background(Capsule().fill(Color.orange.opacity(0.15)))
        .help(L("Manual: every new session uses this account. Click the card to go back to Smart."))
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
