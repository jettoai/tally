import SwiftUI

extension MetricKind {
    /// The column role a window of this kind takes in a list row (`MeterColumns`).
    var meterRole: MeterWindowRole {
        switch self {
        case .weeklyModel: .model
        case .session: .session
        case .weeklyAll: .weekly
        case .other: .other
        }
    }
}

extension AccountFacts {
    /// Each of this account's windows by the meter column it belongs in, in `orderedMetrics` order.
    var meterKeys: [MeterColumnKey] { MeterColumns.keys(orderedMetrics.map(\.kind.meterRole)) }
}

/// The list row's meter clusters (track, figure, water line, hover text), split out of AccountListRowView for file size.
extension AccountListRowView {
    /// One window this account reports, as a track, a figure and a one-unit reset countdown, in the
    /// card's order; the window's NAME and the exact reset time live in the cluster's tooltip,
    /// because spelling them out per window is what makes the card as tall as it is.
    func meterCluster(_ metric: UsageMetric, emphasized: Bool = false) -> some View {
        let passed = usage.resetPassed(metric)
        let figure = UsageFormat.percent(metric, mode: settings.displayMode, resetPassed: passed)
        let reset = UsageFormat.resetState(metric, resetPassed: passed)
        return HStack(spacing: Self.clusterGap) {
            bar(metric, resetPassed: passed)
            Text(figure)
                .font(PanelStyle.font(12, 600).monospacedDigit())
                // The figure carries the warning here, unlike on a card. A track this short is too small
                // for its colour alone to be the alarm, and the row has no space for the card's
                // "Limit reached" line. Not while a redeemed reset settles, though: the number is
                // seconds from being replaced, so that is a wait rather than a warning.
                .foregroundStyle(figureColor(metric, resetPassed: passed))
                .frame(width: Self.valueWidth, alignment: .trailing)
            ResetCaption(state: reset, style: .compact, emphasized: emphasized,
                         tint: resetTint(metric, reset: reset, resetPassed: passed))
        }
        .tallyTooltip(meterHelp(metric, reset: reset))
        .accessibilityElement(children: .combine)
        .accessibilityLabel([L(metric.label), figure, UsageFormat.resetSentence(reset)].compactMap { $0 }
            .joined(separator: ", "))
    }

    func figureColor(_ metric: UsageMetric, resetPassed: Bool) -> Color {
        if resetPassed { return PanelStyle.text2 }
        return metric.severity == .critical && !facts.isSettlingReset ? PanelStyle.red : PanelStyle.text
    }

    /// A spent window's countdown is red (it is what the reader is waiting for), and a window that has
    /// not started its clock yet says so in green.
    private func resetTint(_ metric: UsageMetric, reset: UsageFormat.ResetState, resetPassed: Bool) -> Color? {
        if case .notStarted = reset { return PanelStyle.green }
        return metric.usedPercent >= 100 && !resetPassed && !facts.isSettlingReset ? PanelStyle.red : nil
    }

    /// Used fills from the left, remaining anchors right - the same boundary the card's bars split
    /// at, so the two densities never draw one number two ways. The track takes the cluster's width
    /// (never under `barWidth`), and the fill is measured off the track it is drawn in.
    func bar(_ metric: UsageMetric, resetPassed: Bool) -> some View {
        let fraction = UsageFormat.fillFraction(metric, mode: settings.displayMode)
        let fillAlignment: Alignment = settings.displayMode == .used ? .leading : .trailing
        return Capsule()
            .fill(PanelStyle.track)
            .frame(minWidth: Self.barWidth, maxWidth: .infinity)
            .frame(height: Self.barHeight)
            .overlay {
                GeometryReader { geo in
                    Capsule()
                        .fill(resetPassed ? Color.clear : PanelStyle.tint(metric.severity))
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
    func barReserve(_ metric: UsageMetric) -> Int {
        PersonalAccount.reserved(metric.kind, isHeadline: metric.id == facts.headlineID)
            ? facts.reservePercent : 0
    }

    /// The window's name and its own reset, countdown and exact time both, the words the card's
    /// own reset hover gives, so hovering a row answers exactly what reading a card does.
    func meterHelp(_ metric: UsageMetric, reset: UsageFormat.ResetState) -> String {
        var text = L(metric.label)
        if let help = UsageFormat.resetHelp(reset) {
            text += " · \(help)"
        }
        // What the hatching at the end of the track is. The card can afford to let the mark speak
        // for itself beside a 100pt bar; on a track this short the words have to be somewhere, and this callout is
        // where every other word this row folds away already lives.
        if barReserve(metric) > 0 { text += "\n" + L("Kept for web use") }
        return text
    }
}
