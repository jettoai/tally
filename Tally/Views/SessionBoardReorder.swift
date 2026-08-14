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
    /// Adaptive rather than a fixed count so one layout serves all three hosts: a single-column
    /// panel seats one, the two-column panel seats two, and the dashboard window seats as many as
    /// it is dragged wide enough for - the same "ask the display, not the setting" rule the account
    /// grid's auto mode follows. Cells align to the TOP, so a card whose identity line is missing
    /// sits under its neighbours' first lines rather than floating in the middle of its cell.
    func sessionsGrid(_ listed: [SessionRosterStore.SessionRow],
                      board: [SessionRosterStore.SessionRow]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: Self.compactCardWidth),
                                     spacing: 8, alignment: .top)],
                  spacing: 8) {
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
                        boardKeys: board.compactMap(SessionRosterStore.orderKey),
                        manualKeys: settings.sessionBoardOrder)
                else { return }
                withAnimation(CardMotion.spring) { settings.sessionBoardOrder = next }
                Haptics.snap()
            }
            .onEnded { _ in sessionLift = nil }
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

    /// SORT BY STATUS, ONCE. An action rather than a mode, which is why it is drawn whether or not
    /// anything has been dragged (`sessionsBoardControls`): the board takes its seats from the state
    /// sort at the first scan of a launch and then holds them, so this is how somebody asks for that
    /// reading again after an hour of sessions changing what they are doing.
    ///
    /// IT DOES BOTH HALVES, because either alone leaves the board somewhere nobody asked for: it
    /// forgets the arrangement (`SettingsStore.sortSessionBoardByState`) AND has the roster take its
    /// seats again from what is running now (`SessionRosterStore.resortByState`). Clearing the
    /// arrangement alone would drop the board back onto seats taken at launch, which is neither what
    /// the user arranged nor what the sessions are doing.
    ///
    /// It ERASES rather than remembering: the board has one arrangement, the one somebody dragged
    /// it into, and an app that quietly kept the old one would owe the user a second control to get
    /// back to it. Dragging any card starts a new arrangement from what is on screen at that
    /// moment, so nothing is lost that a hand cannot redo.
    var sessionsSortByStateButton: some View {
        // The cards travel on the grid's own spring, which is watching the order they are in
        // (`sessionsGrid`), so both halves are plain assignments: wrapping them would be a second
        // animation over the one already carrying it.
        Button {
            settings.sortSessionBoardByState()
            SessionRosterStore.shared.resortByState()
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "arrow.up.arrow.down")
                Text(L("Sort by status"))
            }
            .font(.caption)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .tallyTooltip(L("Sort the board by status now and forget the arrangement"))
    }
}
