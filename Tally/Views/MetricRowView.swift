import SwiftUI

/// One usage window on a single line: `label · bar · value`, so an account stays compact and several
/// accounts fit at a glance. The bar is the sole carrier of urgency colour (green → amber → red); the
/// numeral stays neutral. The headline (top-tier) window is `prominent` - bolder, with a reset/warning
/// line beneath; secondary windows are one clean line each.
struct MetricRowView: View {
    let metric: UsageMetric
    let mode: DisplayMode
    var prominent: Bool = false

    private static let labelWidth: CGFloat = 72

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                // The label is a NAME and names must look identical everywhere - hierarchy is
                // carried by the data instead (the prominent row keeps its larger numeral and
                // thicker bar). No minimumScaleFactor: it silently shrank the label on cards
                // stretched to fill their grid row (probe-verified 2026-07-19); a rare too-long
                // label truncating with an ellipsis is honest, a randomly smaller one is not.
                Text(L(metric.label))
                    .font(.footnote)
                    .foregroundStyle(Color.secondary)
                    .lineLimit(1)
                    .frame(width: Self.labelWidth, alignment: .leading)
                bar
                Text(UsageFormat.percent(metric, mode: mode))
                    .font((prominent ? Font.callout : Font.footnote).weight(.semibold).monospacedDigit())
                    .foregroundStyle(.primary)
                    .frame(width: 46, alignment: .trailing)
            }
            contextLine
        }
    }

    private var bar: some View {
        // Used fills from the left; remaining anchors right, so the two modes split the same track at
        // the same boundary.
        GeometryReader { geo in
            ZStack(alignment: mode == .used ? .leading : .trailing) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(metric.severity.color)
                    .frame(width: max(3, geo.size.width * UsageFormat.fillFraction(metric, mode: mode)))
            }
        }
        .frame(height: prominent ? 7 : 6)
    }

    /// An untouched session window: the provider starts the 5h clock on the first message, so there
    /// is no reset instant yet. The time slot must never sit empty ("% + time" is the product's
    /// promise - a blank reads as a bug), so it states the fact instead.
    private var sessionNotStarted: Bool {
        metric.kind == .session && metric.resetsAt == nil && metric.usedPercent == 0
    }

    /// A tiny line under every window's bar: a critical warning on the left, ITS OWN reset on the
    /// right - per-row so a reset can never be misread as belonging to a neighbouring window.
    /// Clicking the reset flips every reset label between countdown and exact time (the exact time is
    /// one click away instead of a settings entry); hover previews the other format.
    @ViewBuilder
    private var contextLine: some View {
        if metric.severity == .critical || metric.resetsAt != nil || sessionNotStarted {
            HStack(spacing: 6) {
                if metric.severity == .critical {
                    Text(metric.usedPercent >= 100 ? L("Limit reached") : L("Near limit"))
                        .font(.caption2)
                        .foregroundStyle(TallyColor.critical)
                }
                Spacer(minLength: 0)
                if let resetsAt = metric.resetsAt {
                    resetLabel(resetsAt)
                } else if sessionNotStarted {
                    Text(L("5h starts on first use"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func resetLabel(_ resetsAt: Date) -> some View {
        let style = SettingsStore.shared.resetDisplay
        return TimelineView(.periodic(from: .now, by: 60)) { context in
            Button {
                SettingsStore.shared.resetDisplay = style.toggled
            } label: {
                Text(UsageFormat.resetText(resetsAt, style: style, now: context.date) ?? "")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
            .help(UsageFormat.resetText(resetsAt, style: style.toggled, now: context.date) ?? "")
        }
    }
}
