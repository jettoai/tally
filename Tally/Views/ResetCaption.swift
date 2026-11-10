import SwiftUI

/// A window's reset slot, drawn from the one state function (`UsageFormat.resetState`) so the list
/// row and the card cannot tell different stories. `.compact` is the list row's single-unit caption
/// in a fixed column; `.line` is the card's sentence with the exact time in its tooltip.
struct ResetCaption: View {
    enum Style { case compact, line }

    let state: UsageFormat.ResetState
    let style: Style
    /// The soonest reset of its column (`UsageFormat.soonestResets`): primary and semibold instead of
    /// secondary. Only a countdown takes it; the compact style alone uses it.
    var emphasized: Bool = false
    /// A colour for the countdown that says something about its window (a spent one, one not yet
    /// started); nil leaves the quiet default.
    var tint: Color? = nil

    private var isCountdown: Bool { if case .countdown = state { true } else { false } }

    var body: some View {
        switch style {
        case .compact: compact
        case .line: line
        }
    }

    private var compact: some View {
        // The width is fixed OUTSIDE the timeline so a minute tick can never move the neighbours;
        // `.absent` keeps the frame so the column stays reserved.
        Group {
            if isCountdown {
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    Text(verbatim: UsageFormat.resetCompact(state, now: context.date))
                }
            } else {
                Text(verbatim: UsageFormat.resetCompact(state))
            }
        }
        .font(PanelStyle.font(11, emphasized && isCountdown ? 600 : 400).monospacedDigit())
        .foregroundStyle(tint ?? (emphasized && isCountdown ? PanelStyle.text : PanelStyle.text2))
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        // Right-aligned: it ends at the bar's right edge under it.
        .frame(width: AccountListRowView.resetWidth, alignment: .trailing)
    }

    @ViewBuilder
    private var line: some View {
        switch state {
        case .countdown(let date):
            TimelineView(.periodic(from: .now, by: 60)) { context in
                sentence(now: context.date, tooltip: UsageFormat.resetHover(date, now: context.date))
            }
        case .passed(let date):
            sentence(tooltip: UsageFormat.resetAbsolute(date))
        case .notStarted:
            Text(UsageFormat.resetSentence(state) ?? "")
                .font(.caption2)
                .foregroundStyle(.secondary)
        case .absent:
            EmptyView()
        }
    }

    private func sentence(now: Date = Date(), tooltip: String?) -> some View {
        Text(UsageFormat.resetSentence(state, now: now) ?? "")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .tallyTooltip(tooltip ?? "")
    }
}
