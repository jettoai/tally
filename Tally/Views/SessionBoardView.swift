import SwiftUI

/// Which sessions the board is listing. Not a setting and not persisted: it is a question somebody
/// asks while looking ("what is actually connected to me?"), so it lives with the surface's tab
/// selection, one copy per host (`SurfaceTabState`), and starts at All every launch.
enum SessionFilter: String, CaseIterable, Identifiable {
    /// Every live session on the machine, the ones that cannot report included.
    case all
    /// Only the sessions publishing a state, which is the same thing as "supervised by a build that
    /// can tell me what it is doing".
    case connected
    var id: String { rawValue }
    /// "All sessions" rather than the bare "All" the Tokens tab's range switch uses: `L()` keys ARE
    /// the English string, so sharing that word would hand this control the other one's four
    /// translations - and there it means "all time", not "all of them".
    var label: String { self == .all ? L("All sessions") : L("Connected") }
}

/// THE SESSION BOARD: one card per supervised Claude Code session, saying what it is doing and
/// taking you to its terminal when you click it.
///
/// A TAB OF ITS OWN, beside Usage and Tokens, and the three split the surface the way the questions
/// split: Usage answers "how much is left", Tokens "where did the work go", and this one "what is
/// running right now". It began as a strip wedged into the Usage tab between the fleet gauges and
/// the account cards, which gave every session one truncated line and put everything else in a
/// tooltip nobody hovers.
///
/// CARDS RATHER THAN ROWS, because what is worth saying about a session does not fit on a line: the
/// account and model serving it, the effort it is running at, how big the conversation has grown,
/// how long ago it last moved, and - for one that is waiting - what it is waiting for, in words, on
/// the card. A wait nobody can read is a wait nobody answers, which is the entire point of the
/// board; the whole sentence is a hover away when the card's line runs out (`sessionTooltip`).
///
/// AND EVERY LIVE SESSION GETS ONE, including a supervisor too old to publish a state: the sidecars
/// it does write still name its account, its model and its conversation (`SessionSidecar`), so it
/// is drawn quietly rather than reduced to a number nobody can act on.
extension PopoverRootView {
    /// Colour dot diameter: enough that four states are told apart at a glance, small enough that
    /// the card's first line still reads as a line of text rather than as a bullet list.
    private static let stateDotSize: CGFloat = 7
    /// What a card that cannot report itself is drawn at. Far enough down to read as "this one is
    /// quieter than the others" at a glance, not so far that its own text stops being legible -
    /// the card is still the way to that terminal.
    private static let quietCardOpacity: Double = 0.55
    /// The narrowest a card may be laid out at, which is what decides how many fit. Measured
    /// against the longest line these cards actually carry - an account, a model id and an effort
    /// word ("Claude 5 · fable-5 · high", the model as `displayModelName` prints it) - so a
    /// two-column panel seats the identity line rather than truncating every card on the page. The
    /// figure did not move when that line lost its vendor prefix, because it also fixes the column
    /// counts: the two-column panel (480pt of content) takes exactly two, and the single-column one
    /// takes one.
    private static let compactCardWidth: CGFloat = 210

    @ViewBuilder
    var sessionsPage: some View {
        let roster = SessionRosterStore.shared
        let listed = roster.rows.filter { tabState.sessionFilter == .all || $0.isReporting }
        VStack(alignment: .leading, spacing: TallyMetrics.headerToCard) {
            if roster.rows.isEmpty {
                sessionsEmptyState(L("No supervised sessions are running"))
            } else {
                sessionsFilterPicker
                sessionsSummary(roster)
                if listed.isEmpty {
                    // The filter is holding everything back, which is a different sentence from
                    // "nothing is running" - and saying the wrong one would read as the board
                    // having lost the sessions the summary above is still counting.
                    sessionsEmptyState(L("No sessions are reporting yet"))
                } else {
                    // ONE GRID, AND EVERY CARD THE SAME SIZE IN IT, the waiting ones included. A
                    // waiting card used to take the whole width, which read as hierarchy and cost
                    // more than it bought: beside a column of paired cards it was a band across the
                    // page, and a board with three of them was mostly one shape repeated. What makes
                    // it the card to look at is its red dot, its state in words and its own line
                    // saying what it waits for - not its width.
                    //
                    // THE ORDER IS THE STORE'S (`SessionRosterStore.sorted`, asserted there): what
                    // needs somebody first, so the waiting cards still fill the top of the grid.
                    //
                    // Adaptive rather than a fixed count so one layout serves all three hosts: a
                    // single-column panel seats one, the two-column panel seats two, and the
                    // dashboard window seats as many as it is dragged wide enough for - the same
                    // "ask the display, not the setting" rule the account grid's auto mode follows.
                    // Cells align to the TOP, so a card whose identity line is missing sits under
                    // its neighbours' first lines rather than floating in the middle of its cell.
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: Self.compactCardWidth),
                                                 spacing: 8, alignment: .top)],
                              spacing: 8) {
                        ForEach(listed) { row in
                            sessionCard(row)
                        }
                    }
                }
            }
        }
        // The Tokens tab's insets, so the two pages share a left AND a right edge and the crossfade
        // between them has nothing sliding sideways.
        .padding(12)
        .frame(width: scrollContentWidth, alignment: .leading)
        // The list changes length when the filter does, and the surface is sized to what this page
        // reports: without this the host jumps to the new height in one frame while the cards fade.
        .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: tabState.sessionFilter)
    }

    /// Deliberately the quieter of the two segmented controls on screen, exactly as the Tokens tab's
    /// range switch is: the tab picker above chooses what the window is about, this only narrows
    /// what is already on the page.
    private var sessionsFilterPicker: some View {
        NeutralSegmentedPicker(selection: $tabState.sessionFilter,
                               options: SessionFilter.allCases,
                               size: .small) { $0.label }
            .frame(maxWidth: .infinity, alignment: .trailing)
    }

    /// Nothing to list, said in one quiet line rather than with the app's mark and a headline: this
    /// is a tab somebody switched to on purpose, and an empty board is an ordinary answer to it (as
    /// opposed to `EmptyStateView`, which is a panel that cannot do its job at all).
    private func sessionsEmptyState(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 28)
            // On the pinned panel this page is then nearly all quiet space, and quiet space with
            // nothing to click has to be somewhere a hand can hold (the rule EmptyStateView follows).
            .windowDragSurface()
    }

    /// The whole board in four numbers. ALWAYS THE WHOLE BOARD, never what the filter is listing: it
    /// is read as "what is my machine doing", and a summary that shrank when somebody narrowed the
    /// list below it would be answering a question nobody asked.
    private func sessionsSummary(_ roster: SessionRosterStore) -> some View {
        HStack(spacing: 8) {
            summaryCount(roster.workingCount, L("working"), colour: .secondary)
            // The one that is a call for somebody, so it is the only figure carrying colour - and
            // only when there is one, because a red "0" is an alarm about nothing.
            summaryCount(roster.blockedCount, L("blocked"),
                         colour: roster.blockedCount > 0 ? TallyColor.critical : .secondary)
            summaryCount(roster.idleCount, L("idle"), colour: .secondary)
            summaryCount(roster.notReporting, L("not reporting"), colour: .secondary)
            Spacer(minLength: 0)
        }
        .lineLimit(1)
    }

    private func summaryCount(_ count: Int, _ label: String, colour: Color) -> some View {
        HStack(spacing: 3) {
            Text("\(count)").font(.caption.weight(.semibold).monospacedDigit())
            Text(label).font(.caption2)
        }
        // A zero is not news: the four slots stay in place so the eye can find the one it came for,
        // and the empty ones step back rather than reading as readings.
        .foregroundStyle(count > 0 ? colour : Color.secondary.opacity(0.5))
    }

    /// Whether this is the card that is ASKING for somebody, which is the only difference left
    /// between two of them. It names its state in words, ticks the age of the wait on its first
    /// line, and spends its last line on what the wait is rather than on what the session has
    /// spent; everything else about it - its cell, its width, its line COUNT - is what every card
    /// has.
    private func sessionIsWaiting(_ row: SessionRosterStore.SessionRow) -> Bool {
        row.state == .blocked
    }

    /// One session, one cell of the grid.
    private func sessionCard(_ row: SessionRosterStore.SessionRow) -> some View {
        Button {
            // Detached from the press: the jump can stop for up to two minutes inside the system's
            // "may Tally control this app" question the first time, and the panel must not be
            // frozen behind it.
            Task { await TerminalJump.jump(directory: row.directory, hint: row.title,
                                           childPid: row.childPid) }
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                sessionCardHeadline(row)
                if let identity = sessionIdentityLine(row) {
                    // THE PROVIDER'S MARK LEADS THE LINE, at the size the eight other surfaces
                    // that name an account already lead with it (`ProviderIconView`, 11-16pt);
                    // this card was the one that did not. `SessionRow.providerID` says why the
                    // mark is the only thing on the line that answers "whose model is this".
                    //
                    // DRAWN WHENEVER THE LINE IS, without asking whether the provider was legible:
                    // a mark on some cards and not others would put the identity lines of a grid at
                    // two different left edges, which reads worse than the catalog's generic glyph
                    // on the one card whose account id has no head.
                    HStack(spacing: 4) {
                        ProviderIconView(providerID: row.providerID ?? "", size: 11)
                        Text(identity).font(.caption2).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.tail)
                    }
                }
                // THE LAST LINE, AND ONE OF THEM: the two sentences a card can end on take turns in
                // the same slot rather than stacking. EVERY CARD THE SAME HEIGHT is worth more than
                // the stats are: a waiting card that carried both stood a line taller than the ones
                // beside it, and a grid of those reads as a ragged page rather than as hierarchy. So
                // the wait takes the slot on the card that has one - one line of it, red, where a
                // glance at the grid finds it - and the figures it displaced go to the tooltip along
                // with the whole of the sentence itself (`sessionTooltip`).
                //
                // Written on `sessionIsWaiting` rather than on the reason being there, so the choice
                // is the card's state and not an accident of what got published. A blocked session
                // that named no reason keeps its stats: an empty slot would be the ragged card
                // again, for a sentence nobody wrote.
                if sessionIsWaiting(row), let reason = sessionReason(row) {
                    Text(reason)
                        .font(.caption2)
                        .foregroundStyle(TallyColor.critical)
                        .lineLimit(1)
                        .truncationMode(.tail)
                } else {
                    sessionStats(row)
                }
            }
            .padding(.horizontal, TallyMetrics.cardPaddingH)
            .padding(.vertical, TallyMetrics.cardPaddingV)
            .frame(maxWidth: .infinity, alignment: .leading)
            .tallyCard()
            .contentShape(Rectangle())
            // A session that cannot report itself is still a session and still a way to its
            // terminal, so it is dimmed rather than greyed out: quieter than its neighbours, and
            // every bit as clickable.
            .opacity(row.isReporting ? 1 : Self.quietCardOpacity)
        }
        .buttonStyle(.plain)
        .tallyTooltip(sessionTooltip(row))
    }

    /// The card's first line: what this session is, and - on the waiting card - what it is doing and
    /// for how long. Every other card gives the whole line to the name, which truncates at the tail:
    /// these sit side by side, and a name squeezed between two other things is how a column of cards
    /// stops being scannable. The waiting one spends that room on the two things a wait is read for.
    private func sessionCardHeadline(_ row: SessionRosterStore.SessionRow) -> some View {
        HStack(spacing: 6) {
            stateDot(row)
            Text(row.title).font(.callout).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 6)
            if sessionIsWaiting(row) {
                // Reporting, and red, without asking: `blocked` can only come from a published
                // record (`SessionRow.state`), so the card carrying this word always has one.
                Text(L(row.state.rawValue))
                    .font(.caption2)
                    .foregroundStyle(TallyColor.critical)
                sessionDuration(row)
            }
        }
    }

    /// How long this has been true, ticking.
    ///
    /// THE ONE THING ON THIS CARD THAT MOVES WITHOUT ANYTHING CHANGING. The store deliberately
    /// assigns nothing when a scan finds the board unchanged (a re-render of every surface twice a
    /// second, otherwise), so an age computed in the body would freeze at the last state change and
    /// read as a session stuck at "2m" for an hour. A timeline is the SwiftUI answer to "re-render
    /// because time passed": it drives only this Text, and only while the surface is on screen.
    ///
    /// Nothing at all for a session that has published no state: it has no moment to count from,
    /// and counting from the file's own age would be dating the supervisor rather than the thing on
    /// screen (that card says when it last MOVED instead - see `sessionStatsLine`).
    @ViewBuilder
    private func sessionDuration(_ row: SessionRosterStore.SessionRow) -> some View {
        if let since = row.since {
            TimelineView(.periodic(from: .now, by: 2)) { tick in
                Text(sessionAge(since, now: tick.date))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
    }

    /// Who is serving this session: the account, the model, and the effort it is running at. Each is
    /// optional - a session that has not had a turn yet has no observed model, and a supervisor from
    /// before the effort axis publishes none - and the card reads fine without any of them, so
    /// nothing is drawn as a placeholder.
    ///
    /// THE ACCOUNT IS CALLED WHAT THE USER CALLS IT, through the one function every other surface
    /// that names an account asks (`displayLabel`, fourteen call sites): the account card, the fleet
    /// gauge, the menu bar and the advisor all show a renamed account by its new name, and a board
    /// reading the provider's default straight off the list was the one place a rename did not
    /// reach. A single source of truth that one surface reads around is not one.
    ///
    /// The lookup is still what decides whether there IS a name: an id naming no account this build
    /// can see contributes no segment (`SessionRow.accountName` says why it is not the raw id), and
    /// `displayLabel` is asked only about an account that was found - its `fallback` is for "no
    /// override", not for "no account", and handing it the id would print the id.
    private func sessionIdentityLine(_ row: SessionRosterStore.SessionRow) -> String? {
        let account = row.accountName { id in
            store.orderedAccounts.first { $0.id == id }
                .map { settings.displayLabel(accountID: id, fallback: $0.accountLabel) }
        }
        return joined([account, row.model, row.effort])
    }

    /// What this session has spent, and when it was last true of it, drawn on the cards that are not
    /// waiting. The figure comes from the context sidecar, so a session whose file is missing or
    /// unreadable simply has no last line (`SessionSidecar`).
    ///
    /// Inside a timeline whenever it carries a time, for the reason `sessionDuration` gives: the
    /// store assigns nothing on a tick that finds the board unchanged, so an age computed in the
    /// body would sit frozen at whatever it said when the surface opened.
    @ViewBuilder
    private func sessionStats(_ row: SessionRosterStore.SessionRow) -> some View {
        if sessionTime(row, now: .now) != nil {
            TimelineView(.periodic(from: .now, by: 2)) { tick in
                statsText(sessionStatsLine(row, now: tick.date))
            }
        } else {
            statsText(sessionStatsLine(row, now: .now))
        }
    }

    /// The same sentence in words, so the waiting card can hand it to its tooltip: the card and the
    /// tooltip must not drift into saying the figure two ways.
    private func sessionStatsLine(_ row: SessionRosterStore.SessionRow, now: Date) -> String? {
        let context = row.contextTokens
            .map { UsageFormat.compactCount(Int64($0)) + " " + L("context") }
        return joined([context, sessionTime(row, now: now)])
    }

    @ViewBuilder
    private func statsText(_ text: String?) -> some View {
        if let text {
            Text(text).font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                .lineLimit(1).truncationMode(.tail)
        }
    }

    /// The time the stats line has room to say. An ordinary card has no state word and no duration
    /// on its first line, so its own duration comes here; the waiting card already ticks one up
    /// there and gives this slot to when the conversation last MOVED instead (which is a figure it
    /// reads in its tooltip, its own last line being the wait). A session publishing no state has no
    /// duration to give either way, and answers the same question the only way it can.
    private func sessionTime(_ row: SessionRosterStore.SessionRow, now: Date) -> String? {
        if !sessionIsWaiting(row), let since = row.since { return sessionAge(since, now: now) }
        return row.lastActivity.map { sessionAge($0, now: now) + " " + L("ago") }
    }

    /// The card's own separator, spelled once: the middle dot the panel already uses between an
    /// account and a model, dropping whatever is absent rather than leaving a stray divider.
    private func joined(_ parts: [String?]) -> String? {
        let kept = parts.compactMap { $0 }.filter { !$0.isEmpty }
        return kept.isEmpty ? nil : kept.joined(separator: pickEffortSeparator)
    }

    /// What a blocked session is waiting for. ONLY while it is blocked: `reason` is what Claude Code
    /// said at the moment it asked, and a sentence still standing under a session that has moved on
    /// would be worse than no sentence at all. Its callers ask `sessionIsWaiting` first all the
    /// same, because there the state is what decides which line a card ends on - this guard is the
    /// belt, not the decision.
    private func sessionReason(_ row: SessionRosterStore.SessionRow) -> String? {
        guard sessionIsWaiting(row),
              let reason = row.reason?.trimmingCharacters(in: .whitespacesAndNewlines),
              !reason.isEmpty else { return nil }
        return reason
    }

    /// What the card cannot show: the state IN WORDS - an ordinary card gives that line to the name
    /// and leaves the colour to say it - the WHOLE of what a waiting session is waiting for, the
    /// checkout in full, and what a click does.
    ///
    /// The reason is here because the card's own line is one line: a permission request names a
    /// command, and a command cut off at the width of a cell is the half that says nothing. A wait
    /// nobody can read is a wait nobody answers, so the full sentence has to be somewhere, and under
    /// the pointer is where a card in a grid keeps what it cannot fit.
    ///
    /// And the stats follow it, on that card only: they are what the reason took the slot from
    /// (`sessionCard`). Every other card prints them, so repeating them there would be the tooltip
    /// reading the card back rather than saying what it could not.
    private func sessionTooltip(_ row: SessionRosterStore.SessionRow) -> String {
        var lines = [row.title,
                     row.isReporting ? L(row.state.rawValue) : L("not reporting")]
        if sessionIsWaiting(row), let reason = sessionReason(row) {
            lines.append(reason)
            if let stats = sessionStatsLine(row, now: Date()) { lines.append(stats) }
        }
        lines.append(L("Click to bring its terminal to the front"))
        if let directory = row.directory { lines.append(directory) }
        return lines.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    /// One dot per state, along the axis this board is actually read for: does this one need me?
    /// Red for the session that wants somebody, green for the one that is running and needs nobody,
    /// grey for at rest, and a HOLLOW ring for "cannot say" - which is both the published `unknown`
    /// and a session that has published nothing (the latter reads as `unknown` by construction -
    /// `SessionRow.state`), because both are an absence of information rather than a further
    /// condition. Red against green is the strongest contrasting pair available at 7pt, and those
    /// two are the ends of that question.
    ///
    /// WORKING WAS PURPLE, AND THE PURPLE WAS THE MISPLACED ONE. `TallyColor.ai` means "Tally is
    /// steering this" (the smart pick's badge, the status line's mark), and that is true of EVERY
    /// supervised card on this board, the idle ones drawn in grey included. Spending the identity
    /// accent on one activity state overloaded it, and at 7pt it made the board's one real
    /// distinction two deep warm tones apart.
    ///
    /// The standing objection to green was that the meter palette is one tab away, so a green dot
    /// would read as "this session has room". It does not: the meter's sage fills a bar (a
    /// continuous quantity), this fills a dot in a set of discrete categories, and a session card
    /// carries no quota at all. What had to be avoided was the sage VALUE, which is why this is
    /// `TallyColor.live` rather than `TallyColor.normal`.
    ///
    /// AND COLOUR IS NOT THE ONLY CARRIER, which is the precondition for putting red beside green:
    /// a viewer who cannot separate those two hues still gets the waiting card's state in words and
    /// its reason line, both in red text (`sessionCardHeadline`, `sessionCard`).
    @ViewBuilder
    private func stateDot(_ row: SessionRosterStore.SessionRow) -> some View {
        let size = Self.stateDotSize
        switch row.state {
        case .blocked:
            Circle().fill(TallyColor.critical).frame(width: size, height: size)
        case .working:
            Circle().fill(TallyColor.live).frame(width: size, height: size)
        case .idle:
            Circle().fill(Color.secondary.opacity(0.5)).frame(width: size, height: size)
        case .unknown:
            Circle().strokeBorder(Color.secondary.opacity(0.5), lineWidth: 1)
                .frame(width: size, height: size)
        }
    }

    /// How long this session has been in this state, at a glance: seconds under a minute, then
    /// minutes, then hours and minutes. Not a countdown and not a date - the question it answers is
    /// "how long has this been true", and past a day the answer is "a long time".
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
