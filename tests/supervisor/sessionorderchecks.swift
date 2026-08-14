import Foundation

// THE ORDER THE SESSION BOARD IS DRAWN IN, which is two rules over one sort:
//
//   1. THE SEATING (SessionRosterStore.seat): the state sort decides where the cards sit at the
//      first scan of a launch, and from then on the board holds those seats. A card whose session
//      changes state, or whose neighbour ends, does not move. This is what makes the board something
//      a hand can learn: it was re-sorting itself twice a second before 2026-08-14.
//   2. THE ARRANGEMENT (Tally/Core/SessionBoardOrder.swift, SessionRosterStore.arranged): written in
//      project directories, replacing that seating outright until it is cleared again.
//
// Pure throughout, both of them: string algebra plus one stable sort, so every case can be stated
// here without an app around it. The three things that are not pure - the board freezing while a
// card is in flight, the control that sorts by status, and the roster holding its seating between
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
    check("the four sources this suite reads are readable",
          !boardSource.isEmpty && !reorderSource.isEmpty && !settingsSource.isEmpty
              && !rosterSource.isEmpty)
    // THE SCAN MUST NOT MOVE THE CARD UNDER THE POINTER. The roster rescans twice a second; the
    // board draws the membership the drag started on until the hand lets go.
    check("the board freezes while a card is in flight",
          boardSource.contains("let board = sessionLift?.frozen ?? roster.rows"))
    // A session ending moves no pointer and fires no gesture callback, so the scan is the only
    // thing that can end a drag over a card that no longer exists.
    check("…and a scan that loses the carried session puts it down",
          boardSource.contains("!rows.contains(where: { $0.id == lift.id })")
              && boardSource.contains("sessionLift = nil"))
    // SORTING BY STATUS IS AN ACTION NOW, NOT A WAY BACK FROM A MODE. The board no longer re-sorts
    // itself, so the control has to be reachable whether or not anything was ever dragged - it used
    // to be drawn only while there was an arrangement to leave.
    check("the control is drawn whatever order the board is in",
          boardSource.contains("            sessionsSortByStateButton\n")
              && !boardSource.contains("isSessionBoardManual"))
    // BOTH HALVES, because either alone leaves the board somewhere nobody asked for: clearing the
    // arrangement without re-seating drops it back onto seats taken hours ago.
    check("…and it both forgets the arrangement and takes the seats again from the states now",
          reorderSource.contains("settings.sortSessionBoardByState()")
              && reorderSource.contains("SessionRosterStore.shared.resortByState()")
              && settingsSource.contains("func sortSessionBoardByState() { sessionBoardOrder = [] }")
              && rosterSource.contains("seating = nil"))
    // The seating is the store's alone: a second holder of it (the view, the settings) would be a
    // second answer to where a card sits, and the freeze is exactly one answer held over time.
    check("the roster holds its seating between scans, and nothing else touches it",
          rosterSource.contains("private var seating: [String]?")
              && rosterSource.contains(
                  "let (rows, seating) = Self.seat(liveSessionStates().map(Self.row), seating: self.seating)"))
    check("the arrangement is saved and loaded through the one file that spells its key",
          settingsSource.contains("SessionBoardOrder.save(sessionBoardOrder, to: .standard)")
              && settingsSource.contains("sessionBoardOrder = SessionBoardOrder.load(from: defaults)"))
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
    // A session that published no directory cannot be lifted at all (`orderKey`), so offering it a
    // grip would promise a gesture that does nothing. One answer, asked at the grab and at the draw.
    check("only a card there is something to arrange by carries a grip",
          cardSource.contains("showsDragHandle: SessionRosterStore.orderKey(row) != nil")
              && reorderSource.contains("let key = SessionRosterStore.orderKey(row)"))
}
