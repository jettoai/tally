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
/// board; a sentence longer than the card's line is truncated there and read in full in the
/// terminal the card is the way to, because nothing on this board answers a hover (`SessionCardView`).
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

    /// THE WIDEST A SESSION CARD IS LAID OUT AT, which is what stops the other end of the same
    /// arithmetic: the cards divide up the room the surface gives them (`sessionsBoardWidth`), and
    /// without a ceiling a board of one in a four-column panel would be a single 1084pt band across
    /// the page - the shape the count was added to get rid of (Albert, 2026-08-17).
    ///
    /// 480 is the comfortable width this app already reads a line of text at
    /// (`AccountListRowView.minComfortableWidth`), which is the closest thing the repo has to a
    /// ruling on how long a line may get before it stops being easy to come back to. What a cap
    /// leaves over stays empty rather than being handed to the cards.
    static let defaultSessionCardCap: CGFloat = 480

    /// The cap in force for this launch, which is the constant above unless a capture asked for
    /// another one: `open Tally.app --args -TallySessionCardCap 356` lays the board out at a
    /// different ceiling so two of them can be photographed side by side and judged on screen
    /// rather than argued about in a diff (Albert, 2026-08-18).
    ///
    /// Gated on the demo data or a dev build, exactly as `-TallyPanelCapture` and `-TallyAppearance`
    /// are: it must never be reachable in a release instance somebody is actually using, whatever
    /// arguments reach its defaults. Read once, because a launch argument cannot change under a
    /// running app, and never written anywhere: the volatile argument domain is the whole of its
    /// life, the same as `-TallyDemoData`.
    static let sessionCardCap: CGFloat = {
        let asked = UserDefaults.standard.double(forKey: "TallySessionCardCap")
        guard DemoUsage.isActive || BuildVariant.isDev,
              asked > PopoverRootView.compactCardWidth
        else { return PopoverRootView.defaultSessionCardCap }
        return CGFloat(asked)
    }()

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
        // ONE ORDER GOVERNS AT A TIME, and the switch says which (`sessionsSortByStateToggle`).
        // While it is on the seats in the rows ARE the state sort, taken as this board was opened
        // and held still by the roster until it is opened again
        // (`SessionRosterStore.seatingOnOpen`), and the arrangement is held rather than applied: it
        // is remembered for the moment the switch comes off, and a page layering one order over the
        // other would draw one nobody chose. The drag turns the switch off on the first card it
        // moves (`sessionsReorderGesture`).
        //
        // Filtered first, because the arrangement is applied to what is actually on the page: a
        // drag can only mean something about the cards the hand can see. The filter SELECTS and
        // never re-orders: switching to Connected and back leaves every card where it was.
        let listed = SessionRosterStore.arranged(
            board.filter { tabState.sessionFilter == .all || $0.isReporting },
            manualKeys: settings.sessionBoardSortsByState ? [] : settings.sessionBoardOrder)
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
        // AND THE SEATS ARE TAKEN WHEN THIS PAGE APPEARS, which is what "the board is opened" means:
        // a surface can have been up for an hour on another tab, and the seats it was handed then
        // answered a question nobody had asked yet. The root counts SURFACES, for the scanning that
        // every page needs (`PopoverRootView`); this counts the surfaces actually showing the board,
        // which is the count the state sort is asked about (`SessionRosterStore.seatingOnOpen`). A
        // second host already on the board still changes nothing: the first look may re-seat, every
        // look after it is somebody's reading in progress.
        .onAppear { SessionRosterStore.shared.beginViewingBoard() }
        .onDisappear { SessionRosterStore.shared.endViewingBoard() }
        // AND AUTO'S COUNT IS TAKEN AT THE SAME MOMENT, for the same reason the seats are: auto
        // means "as many columns as there are cards", and a board that answered that question live
        // would re-flow itself under somebody's eyes every time a session started somewhere else on
        // the machine. Frozen here, a session arriving mid-read is appended to the board it finds;
        // the count is taken again the next time this page is opened (`sessionsAutoColumns`).
        //
        // TAKEN FROM THE FIRST BOARD THAT HAS ANYTHING ON IT, not from the first frame. The roster
        // scans on its own clock, so a surface opening for the first time appears with an empty
        // board and fills a moment later: a count taken there is a one-column reading of a machine
        // running eight sessions, which is what auto measured on the dev instance before this line
        // said "first board with cards" rather than "first board". Until it is taken the live count
        // answers (`sessionColumnCount`), so the first frame with cards is already the right shape
        // and the freeze changes nothing about it.
        .onAppear { sessionsAutoColumns = listed.isEmpty ? nil : listed.count }
        .onChange(of: listed.count) { _, count in
            if sessionsAutoColumns == nil, count > 0 { sessionsAutoColumns = count }
        }
        // THE FOOTPRINT NUMBERS ARE READ ONLY WHILE THIS PAGE IS UP, and this is the page saying so.
        // On the page rather than on the root the roster is switched from (`PopoverRootView`): that
        // one serves the menu bar's blocked dot and the durations on every surface, while walking
        // the process table serves exactly one line on exactly these cards. A surface sitting on the
        // Usage tab pays nothing for it (`ProcessFootprintStore`).
        .onAppear { ProcessFootprintStore.shared.beginViewing() }
        .onDisappear { ProcessFootprintStore.shared.endViewing() }
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

    /// The board's own line of controls: which order it is in on the left, what it is listing on
    /// the right.
    ///
    /// ALWAYS DRAWN, unlike the account board's own way back. It used to appear only once there was
    /// an arrangement to leave, which cannot be right for a switch: a control that says which of two
    /// orders is governing has to be readable in both of them, and a board sorted by status is
    /// exactly where somebody looks to find out whether it still is.
    private var sessionsBoardControls: some View {
        HStack(spacing: 6) {
            sessionsSortByStateToggle
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
            // THE ONE SLOT THAT IS NOT ALWAYS THERE, and the exception is the point: the four
            // above are the states a session is always in one of, so they keep their places and a
            // zero steps back rather than disappearing. This one is normally zero on a machine
            // where nothing has changed, and a permanent "0 updating" would spend a slot on the
            // reading's uninteresting answer for ever (Albert, 2026-08-23).
            if roster.updatingCount > 0 {
                summaryCount(roster.updatingCount, L("updating"), colour: .secondary)
            }
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
