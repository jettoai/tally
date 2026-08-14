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
/// board; the whole sentence is a hover away when the card's line runs out (`SessionCardView`).
///
/// AND EVERY LIVE SESSION GETS ONE, including a supervisor too old to publish a state: the sidecars
/// it does write still name its account, its model and its conversation (`SessionSidecar`), so it
/// is drawn quietly rather than reduced to a number nobody can act on.
extension PopoverRootView {
    /// The narrowest a card may be laid out at, which is what decides how many fit. Measured
    /// against the longest line these cards actually carry - an account, a model id and an effort
    /// word ("Claude 5 · fable-5 · high", the model as `displayModelName` prints it) - so a
    /// two-column panel seats the identity line rather than truncating every card on the page. The
    /// figure did not move when that line lost its vendor prefix, because it also fixes the column
    /// counts: the two-column panel (480pt of content) takes exactly two, and the single-column one
    /// takes one.
    /// Not private: the grid that lays the cards out at this width is the reorder file's
    /// (`sessionsGrid`), and the figure has to stay one number.
    static let compactCardWidth: CGFloat = 210

    @ViewBuilder
    var sessionsPage: some View {
        let roster = SessionRosterStore.shared
        // THE BOARD IS FROZEN WHILE A CARD IS IN FLIGHT. The roster rescans twice a second, and a
        // scan that arrives mid-drag would re-seat (or remove) the very card under the pointer.
        // What is held is the MEMBERSHIP and nothing else: the order stays a pure function of the
        // arrangement, which is exactly what the drag is rewriting, so the cards still spring into
        // their new seats while the hand is down. The board catches up on the next scan after the
        // drop, which is at most half a second later.
        let board = sessionLift?.frozen ?? roster.rows
        // THE SEATS THE BOARD TOOK, THEN WHATEVER THE USER MADE OF THEM
        // (`SessionRosterStore.seat` is already in the rows; `arranged` is the drag's own order).
        // Filtered first, because the arrangement is applied to what is actually on the page: a
        // drag can only mean something about the cards the hand can see. The filter SELECTS and
        // never re-orders: switching to Connected and back leaves every card where it was.
        let listed = SessionRosterStore.arranged(
            board.filter { tabState.sessionFilter == .all || $0.isReporting },
            manualKeys: settings.sessionBoardOrder)
        VStack(alignment: .leading, spacing: TallyMetrics.headerToCard) {
            if board.isEmpty {
                sessionsEmptyState(L("No supervised sessions are running"))
            } else {
                sessionsBoardControls
                sessionsSummary(roster)
                if listed.isEmpty {
                    // The filter is holding everything back, which is a different sentence from
                    // "nothing is running" - and saying the wrong one would read as the board
                    // having lost the sessions the summary above is still counting.
                    sessionsEmptyState(L("No sessions are reporting yet"))
                } else {
                    sessionsGrid(listed, board: board)
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
        // THE SESSION UNDER THE HAND ENDED. The freeze keeps its card on the page, so without this
        // the drag would go on arranging a card that no longer exists and drop it onto a board that
        // has moved on; the scan is also the only thing that can say so, because a session ending
        // moves no pointer and fires no gesture callback.
        .onChange(of: roster.rows) { _, rows in
            if let lift = sessionLift, !rows.contains(where: { $0.id == lift.id }) {
                sessionLift = nil
            }
        }
    }

    /// The board's own line of controls: sort it by status on the left, what the board is listing on
    /// the right.
    ///
    /// ALWAYS DRAWN, unlike the account board's own way back. It used to appear only once there was
    /// an arrangement to leave, which was honest while the board re-sorted itself: with nothing
    /// dragged, a control offering the state sort offered what the board was already doing. The
    /// board now holds the seats it took at launch (`SessionRosterStore.seat`), so "sort by status"
    /// is something it will not do again on its own, and a control for it has to be reachable
    /// whether or not a card was ever dragged.
    private var sessionsBoardControls: some View {
        HStack(spacing: 6) {
            sessionsSortByStateButton
            Spacer(minLength: 0)
            sessionsFilterPicker
        }
    }

    /// Deliberately the quieter of the two segmented controls on screen, exactly as the Tokens tab's
    /// range switch is: the tab picker above chooses what the window is about, this only narrows
    /// what is already on the page.
    private var sessionsFilterPicker: some View {
        NeutralSegmentedPicker(selection: $tabState.sessionFilter,
                               options: SessionFilter.allCases,
                               size: .small) { $0.label }
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
}
