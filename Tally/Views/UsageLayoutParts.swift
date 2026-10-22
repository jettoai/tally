import SwiftUI

// THE PIECES BOTH PREVIEW LAYOUTS DRAW WITH (`UsageLayout`), so the two cannot come to disagree about
// what a bar, a colour or a detail card is. Nothing here is reached without the launch flag.
//
// THRESHOLDS LIVE IN ONE PLACE: a bar's colour is `MetricSeverity.fromUsedPercent` and the tightest
// window is `AccountFacts.bindingWindow`, so this file never spells 50 or 20 and never takes a
// minimum of its own (tests/usagelayout locks both).

/// A tint that reads the product's severity ramp, optionally calm when nothing is wrong.
enum LayoutTint {
    /// A healthy bar in the ledger is neutral, so the eye is pulled to amber and red alone.
    private static let calm = dynamic(dark: NSColor(srgbRed: 0.847, green: 0.855, blue: 0.875, alpha: 1),
                                      light: NSColor(srgbRed: 0.369, green: 0.388, blue: 0.420, alpha: 1))
    /// The empty part of a bar.
    static let track = dynamic(dark: NSColor(white: 1, alpha: 0.10), light: NSColor(white: 0, alpha: 0.08))

    static func fill(_ severity: MetricSeverity, calmWhenHealthy: Bool) -> Color {
        severity == .normal && calmWhenHealthy ? calm : severity.color
    }

    private static func dynamic(dark: NSColor, light: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }
}

/// The three windows an account can report, in the order both layouts read them (5h, week,
/// flagship). A window the plan does not have is nil, which draws differently from an empty one.
struct LayoutWindows {
    let session: UsageMetric?
    let weekly: UsageMetric?
    let flagship: UsageMetric?

    init(_ usage: AccountUsage) {
        let columns = UsageMetric.columns(usage.metrics)
        session = columns.session
        weekly = columns.weekly
        flagship = usage.headline.flatMap { $0.isModelScoped ? $0 : nil }
    }

    /// The column names, in that order. Computed, not stored: the app language can change at runtime.
    static var names: [String] { [L("5h"), L("Week"), L("Flagship")] }

    var all: [(name: String, metric: UsageMetric?)] {
        zip(Self.names, [session, weekly, flagship]).map { (name: $0, metric: $1) }
    }
}

/// One window as a bar showing what is LEFT. 0% keeps a 1pt line of its colour and no data draws a
/// dashed outline, so "empty" and "unknown" never look alike. The window the account's one printed
/// number belongs to wears a 1pt ring in its own colour (`isBinding`).
struct LayoutBar: View {
    enum Axis { case horizontal, vertical }

    let metric: UsageMetric?
    var axis: Axis = .horizontal
    var length: CGFloat
    var thickness: CGFloat
    var isBinding = false
    var calmWhenHealthy = false

    private var radius: CGFloat { axis == .horizontal ? thickness / 2 : 1.5 }
    private var size: CGSize {
        axis == .horizontal ? CGSize(width: length, height: thickness)
                            : CGSize(width: thickness, height: length)
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        ZStack(alignment: axis == .horizontal ? .leading : .bottom) {
            if let metric {
                let tint = LayoutTint.fill(MetricSeverity.fromUsedPercent(metric.usedPercent),
                                           calmWhenHealthy: calmWhenHealthy)
                let filled = max(1, length * metric.remainingPercent / 100)
                shape.fill(LayoutTint.track)
                shape.fill(tint)
                    .frame(width: axis == .horizontal ? filled : thickness,
                           height: axis == .horizontal ? thickness : filled)
                if isBinding {
                    shape.strokeBorder(tint, lineWidth: 1).padding(-1.5)
                        .frame(width: size.width, height: size.height)
                }
            } else {
                shape.strokeBorder(Color.secondary, style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
            }
        }
        .frame(width: size.width, height: size.height)
        .accessibilityHidden(true)
    }
}

/// The account's three windows as three upright bars, bottom aligned, in 5h / week / flagship order.
struct LayoutMicroBars: View {
    let windows: LayoutWindows
    let binding: UsageMetric?

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(Array(windows.all.enumerated()), id: \.offset) { _, window in
                LayoutBar(metric: window.metric, axis: .vertical, length: 18, thickness: 4,
                          isBinding: window.metric != nil && window.metric?.id == binding?.id)
            }
        }
    }
}

/// What the layouts leave out of sight, one click or hover away: the account and its plan, every
/// window with what is left and when it comes back (the tightest in bold), the banked resets, and
/// why the smart pick sits here. The lines come in the same order as the bars.
struct UsageDetailCard: View {
    let facts: AccountFacts
    var isSmartPick = false

    private var windows: LayoutWindows { LayoutWindows(facts.usage) }

    var body: some View {
        let binding = facts.bindingWindow
        let now = Date()
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(facts.label).font(.system(size: 12, weight: .semibold))
                if let plan = facts.usage.planName {
                    Text(plan).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            ForEach(Array(windows.all.enumerated()), id: \.offset) { _, window in
                if let metric = window.metric {
                    windowLine(window.name, metric, tightest: metric.id == binding?.id, now: now)
                }
            }
            if case .codexCredits(let resets) = facts.resetOffer {
                Text(verbatim: "\(resets) " + L(resets == 1 ? "reset available" : "resets available"))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if isSmartPick,
               let reason = LaunchPolicyStore.smartReason(
                   facts.usage, primaryModel: LaunchPolicyStore.shared.policy(facts.usage.providerID).model) {
                Label(reason, systemImage: "sparkles")
                    .font(.system(size: 11)).foregroundStyle(TallyColor.ai)
            }
        }
        .padding(10)
        .fixedSize()
        .accessibilityElement(children: .combine)
    }

    private func windowLine(_ name: String, _ metric: UsageMetric, tightest: Bool, now: Date) -> some View {
        HStack(spacing: 8) {
            Text(name).frame(width: 52, alignment: .leading)
            Text(String(format: L("%@ left"), "\(Int(metric.remainingPercent.rounded()))%"))
                .monospacedDigit().frame(width: 64, alignment: .leading)
            if let resetsAt = metric.resetsAt {
                Text(verbatim: "↻ " + UsageFormat.countdownBody(resetsAt, now: now)).foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 11, weight: tightest ? .semibold : .regular))
    }
}
