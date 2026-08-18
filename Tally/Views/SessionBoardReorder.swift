import SwiftUI

/// DRAG-TO-REORDER FOR THE SESSION BOARD: the grid the cards are laid out in, the one gesture that
/// arranges them, the floating copy that follows the pointer, and the way back to the state sort.
///
/// Split out of SessionBoardView for the reason the account cards' own reorder is split out of
/// PopoverRootView (see PopoverCardGrid.swift): the page is one thing to read, the drag is another,
/// and both files stay short enough to hold in the head.
///
/// IT IS THE ACCOUNT CARDS' DRAG, POINTED AT ANOTHER BOARD. The same in-view machinery
/// (CardReorder.swift): each card records its frame, the pointer is hit-tested against those
/// frames, and a floating copy tracks the hand while the order mutates live under it. Nothing here
/// re-implements any of that; what IS this board's own is what a move means - the account board
/// arranges accounts, and this one arranges PROJECTS, because a session is gone by tomorrow and a
/// checkout is not (`SessionBoardOrder`).
extension PopoverRootView {

    /// The card a session drag is carrying: which card it is, which project it arranges, the row
    /// to draw it with, and where the hand has it.
    ///
    /// IT ALSO HOLDS THE BOARD IT STARTED ON. The roster rescans twice a second and the drag must
    /// not have cards appear, vanish or re-sort under the pointer (see `sessionsPage`), so the
    /// membership travels with the lift and the page draws that until the hand lets go.
    struct SessionLift {
        /// The supervisor pid, which is what the card is identified by on the page.
        let id: String
        /// The directory this card is ARRANGED by, resolved once at the grab: a card with none
        /// cannot be lifted at all, so everything downstream has a key without asking again.
        let key: String
        let row: SessionRosterStore.SessionRow
        let sourceFrame: CGRect
        let touchOffset: CGPoint
        var location: CGPoint
        /// The whole board as it stood when the hand closed, filter and all, unfiltered.
        let frozen: [SessionRosterStore.SessionRow]

        /// Where the floating copy's centre sits. The single source for BOTH the rendered position
        /// and the hit-test probe, exactly as `CardLift.previewCentre` is: two spellings of this
        /// would let reordering stop matching what the user sees.
        var previewCentre: CGPoint {
            CGPoint(x: location.x - touchOffset.x + sourceFrame.width / 2,
                    y: location.y - touchOffset.y + sourceFrame.height / 2)
        }
    }

    /// The cards, in whatever order the board is in, each registering its frame for the drag.
    ///
    /// ONE GRID, AND EVERY CARD THE SAME SIZE IN IT, the waiting ones included. A waiting card used
    /// to take the whole width, which read as hierarchy and cost more than it bought: beside a
    /// column of paired cards it was a band across the page, and a board with three of them was
    /// mostly one shape repeated. What makes it the card to look at is its red dot, its state in
    /// words and its own line saying what it waits for - not its width, and now not its position
    /// either once somebody has arranged the board by hand.
    ///
    /// WHAT THE COLUMN PICKER SAYS IS WHAT THIS BOARD LAYS OUT, and it used to be adaptive
    /// regardless: a picker reading "1" opened a panel one column wide and this grid quietly seated
    /// two 210pt cards in it, the control saying one thing and the page doing another (Albert,
    /// 2026-08-15).
    ///
    /// A COUNT IS A PROMISE ABOUT THE READING, NEVER ABOUT THE WINDOW. The count is the board's own
    /// (`sessionsColumnChoice`) and it is spent here, on how many columns the cards are read in and
    /// how wide they are laid out: at most that many columns, dividing up the room the surface gives
    /// them, held against the leading edge (`sessionsBoardWidth`). The surface itself is the same on
    /// all three pages, because a width that followed the page resized the window on every tab
    /// switch (see `PopoverRootView.popoverWidth`), so a count the width cannot seat steps down to
    /// what fits (`PanelGeometry.boardColumns`) - a card never goes below the width the whole board's
    /// column arithmetic is built on (`compactCardWidth`), nor past the width a line stops being
    /// comfortable to read at (`sessionCardCap`).
    ///
    /// Cells align to the TOP, so a card whose identity line is missing sits under its neighbours'
    /// first lines rather than floating in the middle of its cell.
    func sessionsGrid(_ listed: [SessionRosterStore.SessionRow],
                      board: [SessionRosterStore.SessionRow]) -> some View {
        // Resolved once for the whole pass, and the cells and the run are both laid out from it:
        // two readings of the count are two chances for the grid and its width to disagree, which
        // is the defect this pair was split apart to prevent (`sessionsBoardWidth`).
        let columns = sessionColumnCount(cards: listed.count)
        return LazyVGrid(columns: sessionGridItems(columns: columns),
                         spacing: Self.sessionCardGap) {
            ForEach(listed) { row in
                sessionCard(row)
                    // The card being carried is drawn by the floating copy instead, at the pointer
                    // (`sessionLiftPreview`); its seat stays empty until it is put down.
                    .opacity(sessionLift?.id == row.id ? 0 : 1)
                    // Where this card is, for the drag to hit-test against. The account cards'
                    // registry, shared: the two boards live on different tabs and are keyed by
                    // different ids (a supervisor pid here, an account id there), so one
                    // coordinate space serves both and each drag reads only the ids it was handed.
                    .cardFrame(id: row.id, in: Self.reorderSpace)
            }
        }
        // Only as wide as the cards it is laying out, against the leading edge: what a card cap
        // leaves over is the surface's, not the board's (`sessionsBoardWidth`).
        .frame(maxWidth: sessionsBoardWidth(columns: columns), alignment: .leading)
        // Cards glide to their new seats rather than teleporting, on the same spring the account
        // cards move on: a card moved by hand and a card displaced by that move travel alike.
        .animation(reduceMotion ? nil : CardMotion.spring,
                   value: listed.map(\.id).joined(separator: "|"))
        // ON THE GRID, NEVER ON A CARD, for the reason the account grid's own comment gives: a live
        // reorder tears the moved card's view down, and SwiftUI CANCELS (not ends) a gesture whose
        // view that diff removed - lift state parked there would leak a floating preview forever.
        // The grid itself survives every reorder.
        //
        // HIGH PRIORITY, AND THE CARDS ARE STILL BUTTONS. The drag only recognises after 4pt of
        // travel, so a press that stays put is still the card's own click through to its terminal;
        // this is the arrangement the account cards have shipped with since the drag existed, and
        // their pin, renew and retry buttons sit under the very same gesture.
        .highPriorityGesture(sessionsReorderGesture(listed: listed, board: board))
        // Cancellation safety net, mirroring the account grid: @GestureState resets on cancel as
        // well as on end, which is the only hook a cancelled gesture guarantees.
        .onChange(of: isSessionDragActive) { _, active in if !active { sessionLift = nil } }
        .onDisappear { sessionLift = nil }
    }

    /// The gutter between two session cards, across and down. One number, so a grid that steps a
    /// column down is measured against the gap it will actually be laid out with.
    static let sessionCardGap: CGFloat = 8

    /// What this page was asked for: an explicit count, or nil where nobody has picked one.
    ///
    /// THE BOARD'S OWN SETTING (`SettingsStore.sessionsColumns`), not the account pages'. It used to
    /// read whichever count the density picker was editing, which made one number serve two pages
    /// that are read for different questions - a board sorted into two columns while the accounts
    /// were read one per row could not be said at all (Albert, 2026-08-17).
    ///
    /// Read here rather than inside the grid so that the count and the width the cards are laid out
    /// at answer to one reading of the setting: a board laying out two cards in a run sized for one
    /// is the exact defect this pair exists to prevent.
    var sessionsColumnChoice: Int? {
        (1 ... SettingsStore.maxSessionsColumns).contains(settings.sessionsColumns)
            ? settings.sessionsColumns : nil
    }

    /// HOW WIDE THE BOARD ITSELF IS LAID OUT: its columns of cards and the gutters between them,
    /// where each card has taken its share of the room the surface offers, up to the width a line
    /// stops being comfortable to read at (`sessionCardCap`).
    ///
    /// WHAT A CAP LEAVES OVER STAYS EMPTY on the trailing side rather than being handed to the
    /// cards, which is what keeps a board of one from stretching a lone session card across a
    /// four-column panel - the complaint the count was added for (Albert, 2026-08-17) - without the
    /// surface having to change width to say it. What the count no longer does is FREEZE the card at
    /// a width borrowed from the account ladder: a chosen "1" in a 504pt panel was a 263pt card
    /// beside 217pt of nothing, and the room belongs to the cards up to the point where a longer
    /// line stops being worth reading (Albert, 2026-08-18).
    ///
    /// Never wider than what it is offered: the count inside it has already been stepped down to
    /// what the surface can seat (`sessionColumnCount`), so the two cannot disagree about how many
    /// cards are on the page.
    func sessionsBoardWidth(columns: Int) -> CGFloat {
        PanelGeometry.flexibleRunWidth(inGridOf: sessionsGridWidth, columns: columns,
                                       gap: Self.sessionCardGap,
                                       minimum: Self.compactCardWidth,
                                       cap: Self.sessionCardCap)
    }

    /// The width the board divides between its cards: the surface, less the page's own padding.
    var sessionsGridWidth: CGFloat { scrollContentWidth - 2 * PanelGeometry.contentPadding }

    /// How many columns this board lays its cards out in (see `PanelGeometry.boardColumns`, which
    /// says why an explicit count is a maximum and what auto resolves to).
    ///
    /// Bounded by the width it is being laid out in, which is the surface's and not this page's: a
    /// count the panel cannot seat steps down to the one it can, rather than the grid promising a
    /// column the surface never had the room for. Auto asks for the number of cards the board was
    /// opened with, held in `sessionsAutoColumns` until the page is opened again, so the answer is
    /// the same for the whole of one reading.
    func sessionColumnCount(cards: Int) -> Int {
        PanelGeometry.boardColumns(chosen: sessionsColumnChoice,
                                   cards: sessionsAutoColumns ?? cards,
                                   in: sessionsGridWidth,
                                   minimum: Self.compactCardWidth,
                                   gap: Self.sessionCardGap)
    }

    /// The grid's columns: that many equal flexible cells, which divide up the width the board is
    /// capped to above and so come out at `PanelGeometry.flexibleCardWidth` apiece.
    private func sessionGridItems(columns: Int) -> [GridItem] {
        Array(repeating: GridItem(.flexible(minimum: Self.compactCardWidth),
                                  spacing: Self.sessionCardGap, alignment: .top),
              count: columns)
    }

    /// One drag for the whole board. The grabbed card is locked in from the drag's START location
    /// exactly once - later frames must never re-hit-test it, or the live reorder could silently
    /// swap which card is in the hand.
    ///
    /// A DRAG THAT NEVER REACHES A TARGET CHANGES NOTHING, which is what "let go over the gap, or
    /// off the page" means here: the arrangement is written only when a card is actually displaced,
    /// so a board that was sorting itself by state is still doing so afterwards. A drag that HAS
    /// displaced cards has already committed them, on purpose: the spring under the hand is the
    /// feedback, and taking it back on release would be a board that lied about what it was doing.
    func sessionsReorderGesture(listed: [SessionRosterStore.SessionRow],
                                board: [SessionRosterStore.SessionRow]) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named(Self.reorderSpace))
            .updating($isSessionDragActive) { _, state, _ in state = true }
            .onChanged { value in
                if sessionLift == nil {
                    guard let grabbed = cardFrames
                            .first(where: { $0.value.contains(value.startLocation) }),
                          let row = listed.first(where: { $0.id == grabbed.key }),
                          // A session that has published no directory has nothing to arrange BY,
                          // so it cannot be carried. It keeps its seat at the end of the board,
                          // which is where an unarranged card belongs anyway.
                          let key = SessionRosterStore.orderKey(row)
                    else { return }
                    sessionLift = SessionLift(
                        id: row.id, key: key, row: row, sourceFrame: grabbed.value,
                        touchOffset: CGPoint(x: value.startLocation.x - grabbed.value.minX,
                                             y: value.startLocation.y - grabbed.value.minY),
                        location: value.location, frozen: board)
                }
                guard var lift = sessionLift else { return }   // the grab began between two cards
                lift.location = value.location
                sessionLift = lift
                let boardKeys = board.compactMap(SessionRosterStore.orderKey)
                // Hit-tested with the LIFTED CARD'S CENTRE (previewCentre - exactly where the copy
                // renders), never with the pointer: a card grabbed near its edge would otherwise
                // keep the pointer inside every target's dead zone for the whole drag, and the
                // order would never change even while the preview visually covers the target.
                guard let targetID = reorderTarget(at: lift.previewCentre, frames: cardFrames,
                                                   excluding: lift.id,
                                                   orderedIDs: listed.map(\.id)),
                      let target = listed.first(where: { $0.id == targetID }),
                      let targetKey = SessionRosterStore.orderKey(target),
                      // Two sessions of ONE project share one seat: dropping either onto the other
                      // is not a move, it is the same card twice (`SessionBoardOrder`).
                      let next = SessionBoardOrder.manualOrder(
                        moving: lift.key, onto: targetKey,
                        listedKeys: listed.compactMap(SessionRosterStore.orderKey),
                        boardKeys: boardKeys,
                        manualKeys: sessionsDragBaseline(boardKeys))
                else { return }
                // THE HAND TAKES THE BOARD BACK THE INSTANT IT MOVES A CARD. Written beside the
                // arrangement rather than at the drop so the two can never disagree: a cancelled
                // drag has still displaced what it displaced, and an arrangement under a switch
                // that says "sorted by status" is a board with two owners. A drag that never
                // reached a target never gets this far (the guard above returns first), which is
                // how a board sorting by status survives one.
                settings.sessionBoardSortsByState = false
                withAnimation(CardMotion.spring) { settings.sessionBoardOrder = next }
                Haptics.snap()
            }
            .onEnded { _ in sessionLift = nil }
    }

    /// WHAT THE DRAG IS WRITING ON TOP OF: the arrangement while the hand owns the board, the board
    /// itself while the switch does.
    ///
    /// THE ORDER ON SCREEN IS THE ONLY HONEST BASELINE. With the switch on, the arrangement on disk
    /// governs nothing (`sessionsPage` holds it back), so writing from it moves cards the hand never
    /// touched: a board seated `[X, C, A, B]` with the filter hiding X, dragged C past A, was
    /// written from a remembered `[A, B, C, X]` and flung X to the far end. Written from the board
    /// it stays where it is (`[X, A, C, B]`).
    ///
    /// THE REMEMBERED KEYS FOLLOW rather than being dropped: a project whose sessions have ended is
    /// on nobody's board and cannot jump anywhere, and it is keyed by directory precisely so it
    /// finds its seat when it comes back (`SessionBoardOrder`). Behind the live board is where it
    /// queues, which is where an unarranged project already goes.
    private func sessionsDragBaseline(_ boardKeys: [String]) -> [String] {
        settings.sessionBoardSortsByState ? boardKeys + settings.sessionBoardOrder
            : settings.sessionBoardOrder
    }

    /// The floating copy of the card being carried: the very view the grid draws, lifted off the
    /// page with a shadow and following the pointer. Non-interactive, so it never swallows the drag
    /// and its own button can never be pressed by the hand that is holding it.
    @ViewBuilder
    var sessionLiftPreview: some View {
        if let lift = sessionLift {
            sessionCard(lift.row, handleProminent: true)
                .liftedCard(width: lift.sourceFrame.width, centre: lift.previewCentre,
                            following: lift.location)
        }
    }

    /// SORT BY STATUS, EVERY TIME THE BOARD IS OPENED. A switch rather than a button (2026-08-15,
    /// owner's ruling): the old control sorted once and was finished, so a session that started
    /// waiting an hour later sat where it happened to sit and the board had to be asked again by
    /// hand. A switch that says the board is sorted by status has to go on being true of every
    /// board the user is handed, which is why the roster reads it at each opening
    /// (`SessionRosterStore.seatingOnOpen`) instead of being pushed an order once.
    ///
    /// AND NOT WHILE ONE IS BEING READ (2026-08-17, owner's report). It did follow the states scan
    /// by scan, which is right about the board and wrong about the person: clicking a card wakes
    /// its session, so the board re-sorted itself between one click and the next and the card that
    /// was going to be clicked second had moved. The states still show, on the cards themselves.
    ///
    /// TURNING IT ON RE-SEATS NOW rather than at the next opening (`resortByState`), because the
    /// flick is the question and a board that answered it half a second later would read as a
    /// control that did not take. Turning it OFF does nothing at all: the seats the sort last left
    /// are where the board already is (`seat`), and any arrangement is applied over them by the
    /// page (`sessionsPage`). Nothing is erased in either direction - the switch is a changeover,
    /// and the hand's own order is still there to come back to.
    ///
    /// NO CALLOUT UNDER THE POINTER, as nothing on this board has (`SessionCardView`): the label
    /// says what it does, and the pointer rests here between jumps.
    var sessionsSortByStateToggle: some View {
        // The cards travel on the grid's own spring, which is watching the order they are in
        // (`sessionsGrid`), so this is a plain assignment: wrapping it would be a second animation
        // over the one already carrying them.
        Toggle(isOn: Binding(get: { settings.sessionBoardSortsByState },
                             set: { on in
                                 settings.sessionBoardSortsByState = on
                                 if on { SessionRosterStore.shared.resortByState() }
                             })) {
            Text(L("Sort by status")).font(.caption)
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
        .foregroundStyle(.secondary)
    }
}
