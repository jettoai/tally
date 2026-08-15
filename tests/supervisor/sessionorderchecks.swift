import Foundation

// THE ORDER THE SESSION BOARD IS DRAWN IN, which is two rules over one sort:
//
//   1. THE SEATING (SessionRosterStore.seat): the state sort decides where the cards sit at the
//      first scan of a launch, and from then on the board holds those seats. A card whose session
//      changes state, or whose neighbour ends, does not move. This is what makes the board something
//      a hand can learn: it was re-sorting itself twice a second before 2026-08-14.
//   2. THE ARRANGEMENT (Tally/Core/SessionBoardOrder.swift, SessionRosterStore.arranged): written in
//      project directories, replacing that seating outright until the user says otherwise.
//
// AND A SWITCH SAYS WHICH OF THEM IS GOVERNING (SettingsStore.sessionBoardSortsByState, 2026-08-15).
// On, rule 1 is asked again on every scan instead of once per launch, and rule 2 is held back; off,
// the board holds its seats and the arrangement is applied over them. Moving a card turns the switch
// off, because the hand that arranges the board is the one that owns it. Nothing erases the
// arrangement in either direction: the switch is a changeover, not a reset.
//
// Pure throughout, both rules: string algebra plus one stable sort, so every case can be stated
// here without an app around it. The things that are not pure - the board freezing while a card is
// in flight, the switch and what the drag does to it, and the roster holding its seating between
// scans - are asserted by reading the source, which is what every other suite in this family does
// with a rule that only exists inside a SwiftUI body or a live store.

func runSessionBoardOrderChecks() {
    let t0 = Date(timeIntervalSince1970: 1_786_571_200)

    let atlas = "/Users/u/code/atlas"
    let beacon = "/Users/u/code/beacon"
    let cinder = "/Users/u/code/cinder"
    let dune = "/Users/u/code/dune"

    /// One card: which session it is, what it is doing, where it runs, and how long that has been
    /// true (the state sort's own tie-break, so the fixtures can be aged apart deliberately).
    func row(_ id: String, _ state: SupervisedState, in directory: String?,
             age: TimeInterval = 0) -> SessionRosterStore.SessionRow {
        SessionRosterStore.SessionRow(
            id: id,
            record: SessionStateRecord(state: state.rawValue, since: t0.addingTimeInterval(age),
                                       updatedAt: t0, directory: directory))
    }

    // MARK: what the board does before anybody touches it

    // One scan, as the roster hands it over: ascending supervisor pid, whatever the states are.
    let scan = [row("11", .idle, in: atlas), row("12", .working, in: beacon),
                row("13", .blocked, in: cinder)]
    let board = SessionRosterStore.sorted(scan)
    check("the state sort puts what needs somebody first",
          board.map(\.id) == ["13", "12", "11"])

    // MARK: the seats the board takes at the first scan, and holds

    let seeded = SessionRosterStore.seat(scan, seating: nil)
    check("the first scan of a launch seats the board by state",
          seeded.rows.map(\.id) == ["13", "12", "11"] && seeded.seating == ["13", "12", "11"])

    // THE WHOLE POINT. Before this, a session going idle re-sorted the board under the pointer, and
    // no arrangement of cards could be learned because none of them stayed put.
    let moved = [row("11", .blocked, in: atlas),      // was idle, now asking for somebody
                 row("12", .idle, in: beacon),        // was working, now at rest
                 row("13", .working, in: cinder)]
    check("…and a session changing state after that does not move its card",
          SessionRosterStore.seat(moved, seating: seeded.seating).rows.map(\.id)
              == ["13", "12", "11"])
    check("…nor does it re-seat the board on any later scan",
          SessionRosterStore.seat(scan, seating: seeded.seating).seating == ["13", "12", "11"])

    // A card that appeared while the user was reading has to go somewhere it cannot displace what
    // they were looking at, and "waiting" is not an exception: the red dot says that, not the seat.
    let arrived = SessionRosterStore.seat(
        scan + [row("14", .blocked, in: dune), row("15", .idle, in: "/Users/u/code/elm")],
        seating: seeded.seating)
    check("a session that starts later joins at the end, in the order the scan hands it over",
          arrived.rows.map(\.id) == ["13", "12", "11", "14", "15"]
              && arrived.seating == ["13", "12", "11", "14", "15"])

    let ended = SessionRosterStore.seat([row("11", .idle, in: atlas),
                                         row("13", .blocked, in: cinder)],
                                        seating: seeded.seating)
    check("a session that ends leaves its seat and moves nobody else",
          ended.rows.map(\.id) == ["13", "11"] && ended.seating == ["13", "11"])

    // An empty board has no seats to protect, so the sessions that appear after one are sorted
    // rather than seated: an app started before any session still gets its first sort.
    let nothing = SessionRosterStore.seat([], seating: nil)
    check("a scan that finds nothing seats nobody",
          nothing.rows.isEmpty && nothing.seating == nil)
    check("…and the board that appears after it is sorted by state, not by the scan's order",
          SessionRosterStore.seat(scan, seating: nothing.seating).rows.map(\.id)
              == ["13", "12", "11"])
    check("…which is what the board's own way of asking again does too (`resortByState`)",
          SessionRosterStore.seat(moved, seating: nil).rows.map(\.id) == ["11", "13", "12"])

    // MARK: the switch that keeps that sort live

    // ON IS A MODE, NOT A PRESS. The same sort, asked again on every scan, so a session that starts
    // waiting an hour after the board was seated goes to the front where somebody will see it -
    // which a control that sorted once could only do if it was pressed again at that moment.
    check("with the switch on, a scan seats the board from the states now",
          SessionRosterStore.seat(moved, seating: seeded.seating, sortsByState: true)
              .rows.map(\.id) == ["11", "13", "12"])
    // The seating it leaves behind is that board, which is what makes turning the switch off a
    // freeze rather than a jump: the cards stay where the user was looking at them, rather than
    // dropping back onto seats taken hours ago.
    check("…and the seats it leaves behind are the board it just drew",
          SessionRosterStore.seat(moved, seating: seeded.seating, sortsByState: true)
              .seating == ["11", "13", "12"])
    check("…while the same scan with the switch off holds the seats it was handed",
          SessionRosterStore.seat(moved, seating: seeded.seating, sortsByState: false)
              .rows.map(\.id) == ["13", "12", "11"])
    // A board with nothing on it is nobody's arrangement in either mode.
    check("…and neither mode seats anybody on an empty scan",
          SessionRosterStore.seat([], seating: seeded.seating, sortsByState: true).seating == nil)

    // The filter SELECTS, it never re-orders: a subset of a seated board is that board's order.
    check("narrowing the board to what is reporting leaves the seats it kept",
          SessionRosterStore.seat(scan, seating: seeded.seating).rows
              .filter { $0.id != "12" }.map(\.id) == ["13", "11"])
    // An empty arrangement IS the state sort, which is what makes the way back a plain erase.
    check("…and an arrangement nobody has made leaves that exactly as it was",
          SessionRosterStore.arranged(board, manualKeys: []).map(\.id) == ["13", "12", "11"]
              && SessionRosterStore.arranged(board, manualKeys: [""]).map(\.id)
                  == ["13", "12", "11"])
    check("…which is what the board asks before it draws its way back",
          !SessionBoardOrder.isManual([]) && !SessionBoardOrder.isManual([""])
              && SessionBoardOrder.isManual([atlas]))

    // MARK: what an arrangement does to it

    // OUTRIGHT, THE WAITING CARD INCLUDED. A blocked card already carries a red dot, its state in
    // words and its reason line; making its POSITION a fourth marker would mean the board could
    // re-seat the card under the pointer, which is not an arrangement at all.
    check("an arrangement replaces the state sort, the waiting card included",
          SessionRosterStore.arranged(board, manualKeys: [atlas, beacon, cinder]).map(\.id)
              == ["11", "12", "13"])

    let pair = SessionRosterStore.sorted([row("21", .idle, in: atlas),
                                          row("22", .blocked, in: atlas),
                                          row("23", .working, in: beacon)])
    check("two sessions of one project share a seat and keep the board's seating between them",
          SessionRosterStore.arranged(pair, manualKeys: [beacon, atlas]).map(\.id)
              == ["23", "22", "21"])

    let joined = SessionRosterStore.sorted([row("31", .blocked, in: cinder),
                                            row("32", .idle, in: atlas),
                                            row("33", .working, in: beacon)])
    // A session started in a checkout the arrangement has never seen has to appear SOMEWHERE, and
    // anywhere but the end is the board rearranging itself around a card nobody touched.
    check("a project nobody has arranged sits last, in the order the board had it",
          SessionRosterStore.arranged(joined, manualKeys: [atlas]).map(\.id)
              == ["32", "31", "33"])

    // MARK: the card there is nothing to remember about

    let nameless = SessionRosterStore.SessionRow(id: "40", record: nil,
                                                 session: SessionSidecar(updatedAt: t0))
    check("a session that has published no directory has nothing to be arranged by",
          SessionRosterStore.orderKey(nameless) == nil
              && SessionRosterStore.orderKey(row("41", .idle, in: "   ")) == nil
              && SessionRosterStore.orderKey(row("42", .idle, in: atlas)) == atlas)
    check("…so it sits with the unarranged, at the end",
          SessionRosterStore.arranged([row("43", .idle, in: nil), row("44", .idle, in: atlas)],
                                      manualKeys: [atlas]).map(\.id) == ["44", "43"])

    // MARK: one card dropped on another

    let three = [atlas, beacon, cinder]
    // PAST THE TARGET WHEN MOVING FORWARD, BEFORE IT WHEN MOVING BACKWARD: inserting AT the
    // target's index would make a forward drop onto the very next card a no-op.
    check("a card dropped forward lands past the one it was dropped on",
          SessionBoardOrder.manualOrder(moving: atlas, onto: beacon, listedKeys: three,
                                        boardKeys: three, manualKeys: []) == [beacon, atlas, cinder])
    check("…and dropped backward it lands in front of it",
          SessionBoardOrder.manualOrder(moving: cinder, onto: atlas, listedKeys: three,
                                        boardKeys: three, manualKeys: []) == [cinder, atlas, beacon])
    // THE FIRST DRAG STARTS FROM WHAT IS ON SCREEN, which is the state sort: the card in the hand
    // moves and nothing else does.
    check("the first drag arranges the board that was being looked at",
          SessionBoardOrder.manualOrder(moving: cinder, onto: beacon,
                                        listedKeys: board.compactMap(SessionRosterStore.orderKey),
                                        boardKeys: board.compactMap(SessionRosterStore.orderKey),
                                        manualKeys: []) == [beacon, cinder, atlas])
    check("dropping a card onto its own project is not a move",
          SessionBoardOrder.manualOrder(moving: atlas, onto: atlas, listedKeys: three,
                                        boardKeys: three, manualKeys: three) == nil)
    check("…and neither is a target the page is not showing",
          SessionBoardOrder.manualOrder(moving: atlas, onto: dune, listedKeys: three,
                                        boardKeys: three, manualKeys: three) == nil)

    // MARK: the parts of the board the drag could not see

    // The filter is holding beacon back. A drag among what is left says nothing about where beacon
    // belongs, so beacon must come back to the seat it had.
    check("a drag inside the filtered board is written back into the whole of it",
          SessionBoardOrder.manualOrder(moving: cinder, onto: atlas, listedKeys: [atlas, cinder],
                                        boardKeys: [atlas, beacon, cinder],
                                        manualKeys: [atlas, beacon, cinder])
              == [cinder, beacon, atlas])
    // Keyed by the directory precisely so this holds: the sessions end, the arrangement does not.
    check("a project whose sessions have all ended keeps its place",
          SessionBoardOrder.manualOrder(moving: atlas, onto: cinder, listedKeys: [atlas, cinder],
                                        boardKeys: [atlas, cinder],
                                        manualKeys: [atlas, beacon, cinder])
              == [cinder, beacon, atlas])
    check("a project seen for the first time joins at the end rather than in the middle",
          SessionBoardOrder.manualOrder(moving: beacon, onto: atlas,
                                        listedKeys: [atlas, beacon, dune],
                                        boardKeys: [atlas, beacon, dune],
                                        manualKeys: [atlas, beacon]) == [beacon, atlas, dune])
    check("one seat per project, first mention winning",
          SessionBoardOrder.ranking([atlas, beacon, atlas]) == [atlas: 0, beacon: 1])

    // MARK: the first drag while the switch is on

    // WHAT IS ON SCREEN IS THE BASELINE, because the arrangement on disk is governing nothing while
    // the switch is on (`sessionsPage` holds it back). The board is seated [dune, cinder, atlas,
    // beacon] by state, the filter is hiding dune, and a remembered [atlas, beacon, cinder, dune] is
    // still on disk from before the switch was ever turned on. Dragging cinder past atlas must move
    // those two and nothing else.
    let liveBoard = [dune, cinder, atlas, beacon]
    let stale = [atlas, beacon, cinder, dune]
    // The baseline the gesture hands over while the switch is on: the board first, the remembered
    // keys behind it (`sessionsDragBaseline`).
    let onBaseline = liveBoard + stale
    check("a first drag under the switch is written from the board that is on screen",
          SessionBoardOrder.manualOrder(moving: cinder, onto: atlas,
                                        listedKeys: [cinder, atlas, beacon],
                                        boardKeys: liveBoard, manualKeys: onBaseline)
              == [dune, atlas, cinder, beacon])
    // THE CARD THE FILTER IS HIDING MUST NOT MOVE. Written from the remembered order instead, dune
    // went from the head of the board to its tail without being touched, mentioned or seen.
    check("…so a card the filter is hiding keeps its place instead of being flung to the end",
          SessionBoardOrder.manualOrder(moving: cinder, onto: atlas,
                                        listedKeys: [cinder, atlas, beacon],
                                        boardKeys: liveBoard, manualKeys: onBaseline)?.first == dune
              && SessionBoardOrder.manualOrder(moving: cinder, onto: atlas,
                                               listedKeys: [cinder, atlas, beacon],
                                               boardKeys: liveBoard,
                                               manualKeys: stale) == [atlas, cinder, beacon, dune])
    // The remembered keys are carried along rather than dropped: a project whose sessions have all
    // ended is on nobody's board, cannot jump anywhere, and is exactly what keying the arrangement
    // by directory is for - it queues behind the live board and finds its seat when it comes back.
    check("…while a project that has ended keeps a seat behind the board",
          SessionBoardOrder.manualOrder(moving: cinder, onto: atlas, listedKeys: [cinder, atlas],
                                        boardKeys: [cinder, atlas],
                                        manualKeys: [cinder, atlas] + [beacon, atlas, cinder])
              == [atlas, cinder, beacon])

    // MARK: what survives a restart

    let suite = "tally-sessionboard-\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suite) else {
        check("a scratch defaults suite is available to round-trip through", false)
        return
    }
    check("a board nobody has arranged reads back as unarranged",
          SessionBoardOrder.load(from: defaults).isEmpty)
    SessionBoardOrder.save([cinder, atlas], to: defaults)
    check("an arrangement survives the trip through the user's defaults",
          SessionBoardOrder.load(from: defaults) == [cinder, atlas])
    SessionBoardOrder.save([], to: defaults)
    check("…and clearing it reads back as the state sort again",
          SessionBoardOrder.load(from: defaults).isEmpty
              && !SessionBoardOrder.isManual(SessionBoardOrder.load(from: defaults)))
    defaults.set([atlas, "", atlas, beacon], forKey: SessionBoardOrder.defaultsKey)
    check("a value edited by hand still yields one seat per project and nothing blank",
          SessionBoardOrder.load(from: defaults) == [atlas, beacon])
    // Reading and writing are a file apart in SettingsStore (its init and a property observer),
    // which is the shape a silent rename drifts through: saved under one key, loaded from another,
    // and every arrangement forgotten on every launch.
    check("the arrangement is remembered under the key it has always been remembered under",
          SessionBoardOrder.defaultsKey == "sessionBoardOrder")
    UserDefaults.standard.removePersistentDomain(forName: suite)

    // MARK: the parts that only exist inside a view

    let boardSource = (try? String(contentsOfFile: "Tally/Views/SessionBoardView.swift",
                                   encoding: .utf8)) ?? ""
    let reorderSource = (try? String(contentsOfFile: "Tally/Views/SessionBoardReorder.swift",
                                     encoding: .utf8)) ?? ""
    let settingsSource = (try? String(contentsOfFile: "Tally/Stores/SettingsStore.swift",
                                      encoding: .utf8)) ?? ""
    let rosterSource = (try? String(contentsOfFile: "Tally/Stores/SessionRosterStore.swift",
                                    encoding: .utf8)) ?? ""
    // Where the roster is handed its reading of the switch, which is the one place the setting and
    // the store meet.
    let statusSource = (try? String(contentsOfFile: "Tally/MenuBar/StatusItemController.swift",
                                    encoding: .utf8)) ?? ""
    check("the five sources this suite reads are readable",
          !boardSource.isEmpty && !reorderSource.isEmpty && !settingsSource.isEmpty
              && !rosterSource.isEmpty && !statusSource.isEmpty)
    // THE SCAN MUST NOT MOVE THE CARD UNDER THE POINTER. The roster rescans twice a second - and
    // with the switch on it re-seats on every one of those scans - while the board draws the
    // membership the drag started on until the hand lets go. That freeze is what defers the live
    // sort to the drop: the grid may not move under a hand that is holding one of its cards.
    check("the board freezes while a card is in flight",
          boardSource.contains("let board = sessionLift?.frozen ?? roster.rows"))
    // A session ending moves no pointer and fires no gesture callback, so the scan is the only
    // thing that can end a drag over a card that no longer exists.
    check("…and a scan that loses the carried session puts it down",
          boardSource.contains("!rows.contains(where: { $0.id == lift.id })")
              && boardSource.contains("sessionLift = nil"))
    // SORTING BY STATUS IS A MODE, AND A MODE HAS TO BE READABLE IN BOTH OF ITS STATES: the control
    // is drawn whatever order the board is in, because "is this board still following the states?"
    // is a question asked exactly when it is.
    check("the control is a switch, drawn whatever order the board is in",
          boardSource.contains("            sessionsSortByStateToggle\n")
              && reorderSource.contains(".toggleStyle(.switch)"))
    // Turning it on answers at the flick rather than at the next tick; turning it off does nothing,
    // because the seats the live sort last left are where the board already is.
    check("…and turning it on takes the seats again from the states now",
          reorderSource.contains("settings.sessionBoardSortsByState = on")
              && reorderSource.contains("if on { SessionRosterStore.shared.resortByState() }")
              && rosterSource.contains("seating = nil"))
    // A READING RATHER THAN A COPY. Two answers to "which order is this board in" is two places for
    // it to be wrong, and the store is compiled into this harness with no settings around it.
    check("the roster reads the switch on every scan and keeps no copy of it",
          rosterSource.contains("var sortsByState: () -> Bool = { false }")
              && rosterSource.contains("sortsByState: sortsByState()")
              && statusSource.contains(
                  "sortsByState = { SettingsStore.shared.sessionBoardSortsByState }"))
    // ONE ORDER GOVERNS AT A TIME. While the switch is on the arrangement is held, not layered over
    // the state sort, which would be an order nobody chose.
    check("the page holds the arrangement back while the switch is on",
          boardSource.contains(
              "manualKeys: settings.sessionBoardSortsByState ? [] : settings.sessionBoardOrder"))
    // THE HAND TAKES THE BOARD BACK ON THE FIRST CARD IT MOVES, and the switch is written beside the
    // arrangement rather than at the drop: a cancelled drag has still displaced what it displaced,
    // and an arrangement under a switch that says "sorted by status" is the board with two owners.
    check("moving a card turns the switch off exactly where the arrangement is written",
          reorderSource.contains(
              "settings.sessionBoardSortsByState = false\n"
                  + "                withAnimation(CardMotion.spring) "
                  + "{ settings.sessionBoardOrder = next }"))
    // And the gesture asks for that baseline rather than reaching for the arrangement itself, which
    // is the whole of the fix: the board first, the remembered keys behind it, and only while the
    // switch is on.
    check("the drag is written from the board on screen while the switch is on",
          reorderSource.contains("manualKeys: sessionsDragBaseline(boardKeys)")
              && reorderSource.contains(
                  "settings.sessionBoardSortsByState ? boardKeys + settings.sessionBoardOrder")
              && reorderSource.contains("            : settings.sessionBoardOrder"))
    // NOTHING IS ERASED IN EITHER DIRECTION: the arrangement is what turning the switch off comes
    // back to, so an app that forgot it would owe the user a hand-built order they never asked to
    // rebuild. The old control's erase is gone, at the store and at the call site both.
    check("nothing about the switch forgets what the hand arranged",
          !settingsSource.contains("func sortSessionBoardByState")
              && !settingsSource.contains("sessionBoardOrder = []")
              && !reorderSource.contains("sortSessionBoardByState"))
    // NEVER CHOSEN IS READ OFF THE BOARD ITSELF: a machine carrying an arrangement was dragged by
    // hand while this was a button, and the first launch after the update must not sort over it.
    check("a board that was never switched starts on unless it has an arrangement to honour",
          settingsSource.contains("defaults.object(forKey: \"sessionBoardSortsByState\") as? Bool")
              && settingsSource.contains("?? arrangement.isEmpty")
              && settingsSource.contains(
                  "UserDefaults.standard.set(sessionBoardSortsByState, forKey: \"sessionBoardSortsByState\")"))
    // The seating is the store's alone: a second holder of it (the view, the settings) would be a
    // second answer to where a card sits, and the freeze is exactly one answer held over time.
    check("the roster holds its seating between scans, and reads the switch on every one",
          rosterSource.contains("private var seating: [String]?")
              && rosterSource.contains(
                  "Self.seat(liveSessionStates().map(Self.row), seating: self.seating,")
              && rosterSource.contains("sortsByState: sortsByState())"))
    check("the arrangement is saved and loaded through the one file that spells its key",
          settingsSource.contains("SessionBoardOrder.save(sessionBoardOrder, to: .standard)")
              && settingsSource.contains("let arrangement = SessionBoardOrder.load(from: defaults)")
              && settingsSource.contains("sessionBoardOrder = arrangement"))
    // On the grid, never on a card: a live reorder tears the moved card down, and SwiftUI CANCELS
    // a gesture whose view went away, which leaks the floating preview forever.
    check("the drag lives on the grid and lets go on the drop",
          reorderSource.contains(".highPriorityGesture(sessionsReorderGesture(")
              && reorderSource.contains(".onEnded { _ in sessionLift = nil }"))

    // MARK: the grip that says a card can be dragged at all

    let cardSource = (try? String(contentsOfFile: "Tally/Views/SessionCardView.swift",
                                  encoding: .utf8)) ?? ""
    let accountCardSource = (try? String(contentsOfFile: "Tally/Views/AccountCardView.swift",
                                         encoding: .utf8)) ?? ""
    check("the two card sources this suite compares are readable",
          !cardSource.isEmpty && !accountCardSource.isEmpty)
    // ONE AFFORDANCE ACROSS BOTH BOARDS. The account cards' grip is the pattern; a session card
    // spelling its own glyph, brightness or words would teach two gestures for one gesture.
    for shared in ["Image(systemName: \"line.3.horizontal\")",
                   ".opacity(isHovering || handleProminent ? 1 : 0.35)",
                   "L(\"Drag to reorder\")"] {
        check("the session card's grip states `\(shared)` exactly as the account card does",
              cardSource.contains(shared) && accountCardSource.contains(shared))
    }
    // Resident but dim rather than hover-only, and hover is asked only where a grip is drawn: the
    // account card's own comment says why (an affordance nobody finds, and an empty slot beside it).
    check("hover is tracked on the card, and only where the grip is",
          cardSource.contains("@State private var isHovering = false")
              && cardSource.contains(".onHover { if showsDragHandle { isHovering = $0 } }"))
    // The card the hand is holding is drawn by the floating copy, and a grip that faded out the
    // moment the pointer left the old seat would blink out mid-drag.
    check("the floating copy holds the grip at full brightness",
          reorderSource.contains("sessionCard(lift.row, handleProminent: true)")
              && cardSource.contains("handleProminent: handleProminent"))
    // WHAT A CLICK DOES IS STILL SPOKEN. The callout used to hand that sentence to an accessibility
    // hint on its way past (`TallyTooltip`), so taking the callout off the card took the sentence
    // with it and left a control whose only affordance a screen reader could not see. A hint rather
    // than `.help()`, which is an NSToolTip: the layer is what this board bans, not the meaning.
    // Asked of the CODE, comments stripped first: this file says the words `.help()` and "tooltip"
    // while explaining why it has neither, and an assertion that cannot tell prose from a modifier
    // would be red for the very sentence that documents it.
    let cardCode = cardSource.split(separator: "\n", omittingEmptySubsequences: false)
        .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
        .joined(separator: "\n")
    check("the card tells VoiceOver what a click does without opening a layer to say it",
          cardCode.contains(
              ".accessibilityHint(Text(L(\"Click to bring its terminal to the front\")))")
              && !cardCode.contains(".help(") && !cardCode.contains("tallyTooltip"))
    // A session that published no directory cannot be lifted at all (`orderKey`), so offering it a
    // grip would promise a gesture that does nothing. One answer, asked at the grab and at the draw.
    check("only a card there is something to arrange by carries a grip",
          cardSource.contains("showsDragHandle: SessionRosterStore.orderKey(row) != nil")
              && reorderSource.contains("let key = SessionRosterStore.orderKey(row)"))
}
