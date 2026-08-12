import SwiftUI

/// THE SESSION BOARD: one line per supervised Claude Code session, saying what it is doing and
/// taking you to its terminal when you click it.
///
/// It sits between the advisor strip and the account cards, which is where the panel's own grammar
/// puts it: the strips above are about the FLEET (how much is left, whether the pace fits), the
/// cards below are about ACCOUNTS, and this is about the sessions actually running right now. It
/// renders nothing at all when none are, exactly as the launch summary strip does, so a machine
/// with no session open sees the panel it has always seen.
extension PopoverRootView {
    /// Colour dot diameter: enough that four states are told apart at a glance, small enough that
    /// the row still reads as a line of text rather than as a list of bullets.
    private static let stateDotSize: CGFloat = 7

    @ViewBuilder
    var sessionsSection: some View {
        let roster = SessionRosterStore.shared
        if !roster.rows.isEmpty || roster.notReporting > 0 {
            VStack(alignment: .leading, spacing: 5) {
                sessionsHeader(roster)
                ForEach(roster.rows) { row in
                    sessionRow(row)
                }
                if roster.notReporting > 0 {
                    // The sessions that ARE running and cannot say anything about themselves: a
                    // supervisor older than this feature, or one in the couple of seconds before
                    // its first tick. Named rather than omitted, because a count that quietly
                    // disagreed with the terminals on screen is what makes a board untrustworthy.
                    Text("\(roster.notReporting) " + L("not reporting yet"))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            Divider()
        }
    }

    private func sessionsHeader(_ roster: SessionRosterStore) -> some View {
        HStack(spacing: 6) {
            Text(L("Sessions")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text("\(roster.rows.count + roster.notReporting)")
                .font(.caption).foregroundStyle(.tertiary)
            Spacer(minLength: 0)
            // The count that is the reason to look at this section at all, so it is the one thing
            // on the header row carrying colour.
            if roster.blockedCount > 0 {
                Text("\(roster.blockedCount) " + L("waiting on you"))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(TallyColor.critical)
            }
        }
    }

    private func sessionRow(_ row: SessionRosterStore.SessionRow) -> some View {
        Button {
            // Detached from the press: the jump can stop for up to two minutes inside the system's
            // "may Tally control this app" question the first time, and the panel must not be
            // frozen behind it.
            Task { await TerminalJump.jump(directory: row.directory, hint: row.title,
                                           childPid: row.childPid) }
        } label: {
            HStack(spacing: 6) {
                stateDot(row.state)
                Text(row.title).font(.caption).lineLimit(1)
                if let detail = sessionDetail(row) {
                    Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                Text(L(row.state.rawValue))
                    .font(.caption2)
                    .foregroundStyle(row.state == .blocked ? TallyColor.critical : .secondary)
                // THE ONE THING ON THIS ROW THAT MOVES WITHOUT ANYTHING CHANGING. The store
                // deliberately assigns nothing when a scan finds the board unchanged (a re-render
                // of every surface twice a second, otherwise), so an age computed in the body would
                // freeze at the last state change and read as a session stuck at "2m" for an hour.
                // A timeline is the SwiftUI answer to "re-render because time passed": it drives
                // only this Text, and only while the surface is on screen.
                TimelineView(.periodic(from: .now, by: 2)) { tick in
                    Text(sessionAge(row.since, now: tick.date))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .tallyTooltip(sessionTooltip(row))
    }

    /// The middle of the row: which account it is on, and what it is running. Both are optional -
    /// a session that has not had a turn yet has no observed model - and the row reads fine without
    /// either, so nothing is drawn as a placeholder.
    private func sessionDetail(_ row: SessionRosterStore.SessionRow) -> String? {
        let account = row.accountID.flatMap { id in
            store.orderedAccounts.first { $0.id == id }?.accountLabel
        }
        let parts = [account, row.model].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: pickEffortSeparator)
    }

    private func sessionTooltip(_ row: SessionRosterStore.SessionRow) -> String {
        var lines = [row.title, L("Click to bring its terminal to the front")]
        if let reason = row.reason { lines.insert(reason, at: 1) }
        if let directory = row.directory { lines.append(directory) }
        return lines.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    /// One dot per state, in the panel's own vocabulary: red for the one that wants somebody, the
    /// purple that already means "Tally is steering this" (the status line's own mark, the smart
    /// pick's badge) for work in progress, grey for at rest, and a HOLLOW ring for "cannot say" -
    /// unknown is drawn as an absence of fill rather than as a fourth colour, because it is an
    /// absence of information rather than a fourth condition.
    ///
    /// Deliberately NOT the meter palette (sage / amber / red): those three are quota severities
    /// and they are on screen a centimetre away, so a green dot here would read as "this session
    /// has room" rather than as "this session is working".
    @ViewBuilder
    private func stateDot(_ state: SupervisedState) -> some View {
        let size = Self.stateDotSize
        switch state {
        case .blocked:
            Circle().fill(TallyColor.critical).frame(width: size, height: size)
        case .working:
            Circle().fill(TallyColor.ai).frame(width: size, height: size)
        case .idle:
            Circle().fill(Color.secondary.opacity(0.5)).frame(width: size, height: size)
        case .unknown:
            Circle().strokeBorder(Color.secondary.opacity(0.5), lineWidth: 1)
                .frame(width: size, height: size)
        }
    }

    /// How long this session has been in this state, at a glance: seconds under a minute, then
    /// minutes, then hours and minutes. Not a countdown and not a date - the question the column
    /// answers is "how long has this been true", and past a day the answer is "a long time".
    func sessionAge(_ since: Date, now: Date = Date()) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(since)))
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h \(minutes % 60)m" }
        return "\(hours / 24)d"
    }
}
