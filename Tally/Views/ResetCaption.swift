import SwiftUI

/// A window's reset slot, drawn from the one state function (`UsageFormat.resetState`) so the list
/// row and the card cannot tell different stories. `.compact` is the list row's single-unit caption
/// in a fixed column; `.line` is the card's sentence with the exact time in its tooltip.
struct ResetCaption: View {
    enum Style { case compact, line }

    let state: UsageFormat.ResetState
    let style: Style

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
            if case .countdown = state {
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    Text(verbatim: UsageFormat.resetCompact(state, now: context.date))
                }
            } else {
                Text(verbatim: UsageFormat.resetCompact(state))
            }
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .frame(width: AccountListRowView.resetWidth, alignment: .leading)
    }

    @ViewBuilder
    private var line: some View {
        switch state {
        case .countdown(let date):
            TimelineView(.periodic(from: .now, by: 60)) { context in
                Text(UsageFormat.resetSentence(state, now: context.date) ?? "")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .tallyTooltip(UsageFormat.resetHover(date, now: context.date) ?? "")
            }
        case .passed(let date):
            Text(UsageFormat.resetSentence(state) ?? "")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .tallyTooltip(UsageFormat.resetAbsolute(date) ?? "")
        case .notStarted:
            Text(UsageFormat.resetSentence(state) ?? "")
                .font(.caption2)
                .foregroundStyle(.secondary)
        case .absent:
            EmptyView()
        }
    }
}
