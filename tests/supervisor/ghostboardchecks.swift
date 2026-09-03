import Foundation

// THE MACHINE ROLLUP DRAWN AS CARDS (Tally/Core/SessionBoardGhosts.swift, and the page that lays it
// out - Tally/Views/SessionBoardView.swift, SessionBoardReorder.swift, SessionGhostCardView.swift).
//
// The board used to carry a Projects section above the cards: one row per checkout, the heaviest one
// flamed, and an amber count of the work no session accounts for. Most of what a row said its own
// cards said again underneath, and one WORD said two different things on one page - a row's
// `background` was work nobody is answering for, while a card's is the session's own re-parented
// jobs. What only the rollup could say moved onto the cards; the layer went (Albert, 2026-09-03).
//
// WHAT IS ASSERTED HERE is the pure half - which projects get a card, where those cards sit, and
// which card wears the flame - plus the parts that exist only inside a view and would otherwise be
// stated nowhere: that the unclaimed card is not a button, is not draggable, and is not listed under
// a filter that means "sessions that can report themselves".
func runGhostBoardChecks() {
    let tally = "/Users/x/workspace/tally"
    let sibling = "/Users/x/workspace/tally-wt1"
    let api = "/Users/x/workspace/api"

    // MARK: which projects get a card of their own

    func project(_ root: String, sessions: Int, strays: Int, cpu: Double? = nil) -> ProjectLoad {
        ProjectLoad(root: root, name: URL(fileURLWithPath: root).lastPathComponent,
                    cpuPercent: cpu, memoryBytes: 0, sessions: sessions, strayProcesses: strays)
    }
    let load = MachineLoad(projects: [project(api, sessions: 0, strays: 3),
                                      project(tally, sessions: 2, strays: 0),
                                      project(sibling, sessions: 1, strays: 1)])
    check("a card is drawn for every project with work no session accounts for",
          SessionBoardGhosts.unclaimed(in: load, remembering: []).map(\.root) == [api, sibling])
    // A PROJECT RUNNING SEVERAL SESSIONS NO LONGER PRODUCES A ROW, which the old section drew for.
    // Its cards are on the page and each states its own figures; their TOTAL is what nothing states,
    // and it is deliberately still missing rather than restored as a second layer.
    check("…and a busy project with nothing left over gets none",
          !SessionBoardGhosts.unclaimed(in: load, remembering: []).contains { $0.root == tally })
    check("a machine with nothing left over anywhere draws no such card at all",
          SessionBoardGhosts.unclaimed(in: MachineLoad(projects: [project(tally, sessions: 1,
                                                                         strays: 0)]),
                                       remembering: []).isEmpty)
    // A SUCCESSFUL RECLAIM ENDS THE LAST STRAY OF ITS CHECKOUT, which is the very thing that would
    // take the card away in the tick the record of it is written - and this card is where a reclaim
    // is reported now that the section that used to report it is gone (`SessionGhostCardView`). So
    // "Tally ended your dev server" was a sentence nobody could ever have read.
    check("a project this app has just acted in keeps its card for as long as the record lasts",
          SessionBoardGhosts.unclaimed(in: load, remembering: [tally]).map(\.root)
              == [api, tally, sibling])
    check("…and that card states no leftovers, because it no longer has any",
          SessionBoardGhosts.unclaimed(in: load, remembering: [tally])
              .first { $0.root == tally }
              .map { $0.strayProcesses == 0 && $0.strayCpuPercent == nil
                  && $0.strayMemoryBytes == 0 } == true)
    check("…and a project already drawn for its leftovers is not drawn a second time",
          SessionBoardGhosts.unclaimed(in: load, remembering: [api, sibling]).map(\.root)
              == [api, sibling])
    check("a checkout nothing has happened in is remembered by nobody",
          SessionBoardGhosts.unclaimed(in: MachineLoad(projects: []), remembering: []).isEmpty)
    // THE AMBER FIGURE COUNTS WHAT IS RUNNING, NOT WHAT IS DRAWN. A card kept for its record alone
    // has nothing unclaimed in it any more, and counting it would call for a look at something this
    // app has already dealt with.
    check("the count beside the board is of the cards with something still running in them",
          SessionBoardGhosts.running(SessionBoardGhosts.unclaimed(in: load,
                                                                  remembering: [tally])) == 2
              && SessionBoardGhosts.running(SessionBoardGhosts.unclaimed(in: load,
                                                                         remembering: [])) == 2)
    check("…and is zero on a board whose cards are all history",
          SessionBoardGhosts.running(
              SessionBoardGhosts.unclaimed(in: MachineLoad(projects: []),
                                           remembering: [tally])) == 0)

    // MARK: which of the three things the page is

    // THE STATE THIS WHOLE PACKAGE EXISTS FOR is a board with no session on it: the last one closed
    // and its dev server did not. Asked about the sessions alone, that page is empty and says so -
    // taking the card, the counts and the controls with it, at the moment they are the reading.
    check("a board of nothing but unclaimed cards is a board rather than an empty page",
          SessionBoardGhosts.board(sessions: 0, unclaimed: 1, seats: 1) == .cards)
    check("nothing running anywhere is the one page that says nothing is running",
          SessionBoardGhosts.board(sessions: 0, unclaimed: 0, seats: 0) == .nothing)
    // "Nothing is running" and "the filter is holding everything back" are different sentences, and
    // saying the wrong one reads as the board having lost what the summary is still counting.
    check("…while anything the summary can count says the filter is holding it back",
          SessionBoardGhosts.board(sessions: 3, unclaimed: 0, seats: 0) == .nothingListed
              && SessionBoardGhosts.board(sessions: 0, unclaimed: 2, seats: 0) == .nothingListed)
    check("…and an ordinary board draws its cards",
          SessionBoardGhosts.board(sessions: 3, unclaimed: 1, seats: 4) == .cards)

    // MARK: where the leftovers are said

    // UNDER THE PROJECT'S LAST SESSION CARD, as a footnote rather than as a card of its own. Every
    // unclaimed reading used to take a seat in the grid, which on a live board was two defects: a
    // three-line card in a row as tall as the session card beside it, and every card after it
    // pushed one seat along so the columns stopped standing project beside project (Albert, on the
    // board's first day, 2026-09-03).
    check("a project's leftovers are written under the LAST session card of that project",
          SessionBoardGhosts.seating(sessionDirectories: [tally, sibling, tally],
                                     unclaimed: [tally])
              == .init(seats: [.session(0), .session(1), .session(2)], footnotes: [2: tally]))
    check("…and no card of its own is drawn for it",
          SessionBoardGhosts.seating(sessionDirectories: [tally], unclaimed: [tally]).seats
              == [.session(0)])
    // A CARD IS MATCHED BY CONTAINMENT, NEVER BY TWO STRINGS BEING EQUAL, which is the rule the
    // strays themselves are filed by: a session started one directory deeper is still a session of
    // that project, and an equality test would send its reading to the end of the board where it
    // reads as a checkout nobody on the page is working in.
    check("a session working inside the project carries that project's footnote",
          SessionBoardGhosts.seating(sessionDirectories: [tally + "/apps/web", sibling],
                                     unclaimed: [tally]).footnotes == [0: tally])
    check("…and two sessions at different depths of one project put it on the last of them",
          SessionBoardGhosts.seating(sessionDirectories: [tally + "/apps/web", sibling, tally],
                                     unclaimed: [tally]).footnotes == [2: tally])
    // AND CONTAINMENT IS ON PATH COMPONENTS RATHER THAN CHARACTERS, which the shared rule already
    // guarantees (`MachineLoadRollup.project`): `tally-wt1` starts with `tally` and is a different
    // project, so its card must not adopt the other one's leftovers.
    check("a sibling whose name merely starts the same way takes no footnote",
          SessionBoardGhosts.seating(sessionDirectories: [sibling], unclaimed: [tally])
              == .init(seats: [.session(0), .unclaimed(tally)], footnotes: [:]))
    // A worktree lives inside its repository, and both can have leftovers: the nearer root wins, so
    // each reading lands on the card actually working in it.
    check("a worktree's card takes the worktree's leftovers, not the repository's",
          SessionBoardGhosts.seating(sessionDirectories: [tally + "/.worktrees/feat", tally],
                                     unclaimed: [tally, tally + "/.worktrees/feat"])
              == .init(seats: [.session(0), .session(1)],
                       footnotes: [0: tally + "/.worktrees/feat", 1: tally]))
    // The state this card exists for: the session closed and its dev server did not. There is no
    // card to write under, so it takes one of its own, at the end of the board.
    check("a project with no session card left is the one that still gets a card",
          SessionBoardGhosts.seating(sessionDirectories: [tally], unclaimed: [api, sibling])
              == .init(seats: [.session(0), .unclaimed(api), .unclaimed(sibling)],
                       footnotes: [:]))
    // A session that published no directory is arranged by nothing and can carry no footnote.
    check("…as it does when the only card on the board says nothing about where it is",
          SessionBoardGhosts.seating(sessionDirectories: [nil], unclaimed: [tally])
              == .init(seats: [.session(0), .unclaimed(tally)], footnotes: [:]))
    // THE STATE SORT NO LONGER NEEDS A RULE OF ITS OWN. It used to send every unclaimed card to the
    // end, because a card answering no state cannot be seated among cards sorted by state; the only
    // cards that were ever seated among them are footnotes now, and they travel with the card they
    // are written on whatever order that card is in.
    check("the footnote follows its card into whatever order the board is in",
          SessionBoardGhosts.seating(sessionDirectories: [tally, sibling, tally],
                                     unclaimed: [tally]).footnotes == [2: tally]
              && SessionBoardGhosts.seating(sessionDirectories: [tally, tally, sibling],
                                            unclaimed: [tally]).footnotes == [1: tally])
    check("…and a project nobody is working in goes last in either of them",
          SessionBoardGhosts.seating(sessionDirectories: [tally, sibling],
                                     unclaimed: [tally, api]).seats
              == [.session(0), .session(1), .unclaimed(api)])
    check("a board of unclaimed cards and no sessions is just those cards",
          SessionBoardGhosts.seating(sessionDirectories: [], unclaimed: [api]).seats
              == [.unclaimed(api)])
    check("…and an ordinary board draws exactly its sessions",
          SessionBoardGhosts.seating(sessionDirectories: [tally, sibling], unclaimed: [])
              == .init(seats: [.session(0), .session(1)], footnotes: [:]))
    // UNDER CONNECTED THE BOARD LISTS SESSIONS THAT CAN REPORT THEMSELVES, and a checkout with no
    // card left reports nothing by construction. THE FOOTNOTES STAY: one is a fact about the
    // checkout a card the filter DID list is working in, which is not a thing the filter narrows.
    check("the filter holds back the cards of checkouts nobody is working in",
          SessionBoardGhosts.seating(sessionDirectories: [tally], unclaimed: [tally, api],
                                     listsUnclaimedCards: false)
              == .init(seats: [.session(0)], footnotes: [0: tally]))
    // A ROOT NOBODY COULD NAME IS NOT A PATH, and an empty one is a prefix of every path on the
    // machine: matched by containment it would win for any directory no real checkout claimed and
    // write one project's footnote under half the board (codex review of a54059c). The match
    // refuses it (`MachineLoadRollup.project(of:roots:)`), so it owns no session card.
    check("a root nobody could name takes no session's footnote",
          SessionBoardGhosts.seating(sessionDirectories: [tally, api], unclaimed: [""])
              == .init(seats: [.session(0), .session(1), .unclaimed("")], footnotes: [:]))
    // BUT IT DOES TAKE A CARD, which is the whole of what this page can still do for it. A reclaim
    // whose tree the machine would not place is recorded with an empty project on purpose - the
    // kill happens and has to be reported (`OrphanReclaimStore.round`) - and the project inbox
    // cannot take that one, having no repository to write into. Refusing it here as well left a
    // tree this app really did SIGTERM and SIGKILL reported nowhere at all (codex review of
    // b226640).
    check("a reclaim this app could not file under a project still gets a card of its own",
          SessionBoardGhosts.unclaimed(in: MachineLoad(projects: []), remembering: [""])
              .map(\.root) == [""])
    // AND IT IS NAMED FOR WHAT IT IS. `URL(fileURLWithPath: "").lastPathComponent` is the empty
    // string, so the card that shape produced carried no name at all, which is worse than the
    // silence it replaced.
    check("…under a word rather than the blank a path component would have given it",
          SessionBoardGhosts.unclaimed(in: MachineLoad(projects: []), remembering: [""])
              .first.map { !$0.name.isEmpty && $0.name == L("unknown project") } == true)
    check("…last on the board, behind every checkout that has a name to be looked up by",
          SessionBoardGhosts.unclaimed(in: load, remembering: [tally, ""]).map(\.root)
              == [api, tally, sibling, ""])
    // It is a card kept for a record, so it counts for what the page has to DRAW and not for the
    // amber figure, which is a call to look at something still running.
    check("…counted as a card the page must show and not as work anybody has to act on",
          SessionBoardGhosts.running(
              SessionBoardGhosts.unclaimed(in: MachineLoad(projects: []), remembering: [""])) == 0
              && SessionBoardGhosts.board(sessions: 0, unclaimed: 1, seats: 1) == .cards)

    // MARK: which card wears the flame

    let cards = [SessionBoardGhosts.CardLoad(key: "100", root: tally, cpuPercent: 40),
                 SessionBoardGhosts.CardLoad(key: "200", root: tally, cpuPercent: 260),
                 SessionBoardGhosts.CardLoad(key: "300", root: sibling, cpuPercent: 900)]
    // A mark on every card of a busy project points at nothing, so it goes to the card spending the
    // most of its own - which is the card somebody opening this board is looking for.
    check("the heaviest project's mark lands on its busiest card",
          SessionBoardGhosts.marked(heaviest: tally, among: cards) == .session("200"))
    check("…and on the only card of a project running one session",
          SessionBoardGhosts.marked(heaviest: sibling, among: cards) == .session("300"))
    // Below a whole core nothing is marked at all (`MachineLoadRollup.markedAbovePercent`), which
    // reaches here as no heaviest project.
    check("a quiet machine marks nobody",
          SessionBoardGhosts.marked(heaviest: nil, among: cards) == nil)
    // Under Connected the unclaimed cards are not listed at all, so a checkout whose only card is
    // one of those has its mark on a card the filter is holding back, and nothing is flamed.
    check("a heaviest project with no card handed in at all is flamed nowhere",
          SessionBoardGhosts.marked(heaviest: api, among: cards) == nil)
    // AND THE UNCLAIMED CARD IS IN THE SAME COMPARISON, ON ITS OWN LEFTOVERS. The mark is decided on
    // a CHECKOUT, and a checkout costs what its sessions and its leftovers cost together: a project
    // reading 205% because one session spends 5 and an abandoned dev server spends 200 handed its
    // flame to the 5% card, pointing the eye at the one thing on that board doing nothing wrong.
    check("the mark lands on the leftovers when the leftovers are what the checkout is burning",
          SessionBoardGhosts.marked(
              heaviest: tally,
              among: [.init(key: "100", root: tally, cpuPercent: 5),
                      .init(key: tally, root: tally, cpuPercent: 200, unclaimed: true)])
              == .unclaimed(tally))
    check("…and stays on the session card when the session is the busier of the two",
          SessionBoardGhosts.marked(
              heaviest: tally,
              among: [.init(key: "100", root: tally, cpuPercent: 300),
                      .init(key: tally, root: tally, cpuPercent: 200, unclaimed: true)])
              == .session("100"))
    // The state this card exists for: the session has ended and the work has not, so the only card
    // that project has is the one wearing the mark.
    check("…and a checkout whose sessions have all ended wears it on the only card it has",
          SessionBoardGhosts.marked(
              heaviest: api,
              among: cards + [.init(key: api, root: api, cpuPercent: 400, unclaimed: true)])
              == .unclaimed(api))
    // Two cards on one figure would otherwise trade the mark from tick to tick, which is the flicker
    // the board's stable order was written to stop. The smaller key wins, as it does one file over.
    check("two cards on the same figure settle the mark on the key rather than on the order",
          SessionBoardGhosts.marked(
              heaviest: tally,
              among: [.init(key: "900", root: tally, cpuPercent: 300),
                      .init(key: "100", root: tally, cpuPercent: 300)]) == .session("100")
              && SessionBoardGhosts.marked(
                  heaviest: tally,
                  among: [.init(key: "100", root: tally, cpuPercent: 300),
                          .init(key: "900", root: tally, cpuPercent: 300)]) == .session("100"))
    // A card whose tree has not been read twice yet has no rate, and it must not beat one that has.
    check("a card with no rate yet does not take the mark from a card with one",
          SessionBoardGhosts.marked(
              heaviest: tally,
              among: [.init(key: "100", root: tally, cpuPercent: nil),
                      .init(key: "200", root: tally, cpuPercent: 1)]) == .session("200"))

    // MARK: the parts that only exist inside a view

    let page = (try? String(contentsOfFile: "Tally/Views/SessionBoardView.swift",
                            encoding: .utf8)) ?? ""
    let grid = (try? String(contentsOfFile: "Tally/Views/SessionBoardReorder.swift",
                            encoding: .utf8)) ?? ""
    let ghost = (try? String(contentsOfFile: "Tally/Views/SessionGhostCardView.swift",
                             encoding: .utf8)) ?? ""
    let card = (try? String(contentsOfFile: "Tally/Views/SessionCardFootprint.swift",
                            encoding: .utf8)) ?? ""
    // The card's first line and the mark that rides on it (`sessionCardHeadline`, `flameMark`).
    let state = (try? String(contentsOfFile: "Tally/Views/SessionCardState.swift",
                             encoding: .utf8)) ?? ""
    // THE READING ITSELF, which is now one view drawn under two different cards.
    let footnote = (try? String(contentsOfFile: "Tally/Views/SessionUnclaimedFootnote.swift",
                                encoding: .utf8)) ?? ""
    let session = (try? String(contentsOfFile: "Tally/Views/SessionCardView.swift",
                               encoding: .utf8)) ?? ""
    check("the seven sources this suite reads are readable",
          !page.isEmpty && !grid.isEmpty && !ghost.isEmpty && !card.isEmpty && !state.isEmpty
              && !footnote.isEmpty && !session.isEmpty)
    // THE LAYER IS GONE, not merely unused: two files went with it, and a page that still drew
    // either section would be saying everything twice however good the cards are.
    check("the page draws no rollup section and no reclaim section above the cards",
          !page.contains("sessionsProjectRollup") && !page.contains("sessionsReclaimNotes")
              && !FileManager.default.fileExists(atPath: "Tally/Views/SessionBoardRollup.swift")
              && !FileManager.default.fileExists(atPath: "Tally/Views/SessionBoardReclaim.swift"))
    // The reclaim rows themselves are NOT gone: they moved onto the card of the project they are
    // about, which is the one surface that answers "is it about to do that again".
    check("…the reclaim rows now being drawn with the leftovers of the project they are about",
          footnote.contains(
              "OrphanReclaimStore.shared.watching.filter { $0.project == project.root }")
              && footnote.contains(
                  "OrphanReclaimStore.shared.records.filter { $0.project == project.root }")
              && footnote.contains("reclaimRow(icon: \"eye\", tint: TallyColor.warning"))
    // ONE VIEW FOR BOTH PLACES IT IS DRAWN, which is the whole reason it is a file: a reading
    // written twice drifts twice, and this one is written under a session card and on the card of a
    // checkout whose sessions have ended.
    check("the leftovers are drawn by one view, on the session card and on the unclaimed one",
          footnote.contains("struct SessionUnclaimedFootnote: View")
              && ghost.contains("SessionUnclaimedFootnote(project: project)")
              && session.contains("SessionUnclaimedFootnote(project: unclaimed,"
                                  + " namesItself: true,"))
    // AND THE FOOTNOTE NAMES ITSELF ONLY WHERE NOTHING ELSE DOES. Under a session card everything
    // else is about the session, so figures with no word on them would read as more of the
    // session's own; on the project's own card the headline one line up has already said it.
    check("the footnote says the amber word under a session card, and not on the card that has one",
          footnote.contains("if namesItself {")
              && footnote.contains("Text(L(\"leftovers\"))")
              && ghost.contains("SessionUnclaimedFootnote(project: project)\n"))
    // NOT A SESSION, AND IT NEVER PRETENDS TO BE ONE: no terminal to jump to, so no button, no
    // hover and no pointer; no session to arrange by, so no grip and no frame for the drag to
    // hit-test against. Each of these is a promise the card would otherwise make and not keep.
    // Asked of the CODE rather than of the file: both of these explain in prose that they are not
    // buttons and what a press on them therefore does, and an assertion that cannot tell a comment
    // from a modifier would be red for the very sentence that documents it.
    func code(_ source: String) -> String {
        source.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }
    check("the unclaimed card is not a button and answers no pointer",
          !code(ghost).contains("Button") && !code(ghost).contains("onHover")
              && !code(ghost).contains("onTapGesture") && !code(ghost).contains("tallyTooltip"))
    // NO FRAME, WHICH IS WHAT PUTS IT OUT OF THE DRAG'S REACH: the gesture looks a grabbed point up
    // in the frames the cards registered, and this card registers none (`sessionsGrid`).
    check("…and is not offered to the drag at all",
          !code(ghost).contains("dragHandle") && !code(ghost).contains("showsDragHandle")
              && !code(ghost).contains("cardFrame"))
    // THE FOOTNOTE'S CLAIM IS NARROWER, AND SAYING THE CARD'S WOULD BE FALSE. The drag lives on the
    // GRID rather than on a card (`sessionsGrid` hangs it on the `LazyVGrid`), so a hand that
    // starts inside a footnote is dragging the session card it is written on - which is correct,
    // and which an assertion reading "not offered to the drag at all" would have denied while only
    // ever looking at this leaf's own source (codex review of b226640). What is true of the leaf is
    // that it adds no target: no button, no hover, no grip, and no frame of its own for the
    // hit-test to find, so everything it is drawn inside keeps answering for it.
    check("the footnote registers no target of its own, so presses and drags belong to its card",
          !code(footnote).contains("Button") && !code(footnote).contains("onHover")
              && !code(footnote).contains("onTapGesture")
              && !code(footnote).contains("tallyTooltip")
              && !code(footnote).contains("dragHandle")
              && !code(footnote).contains("showsDragHandle")
              && !code(footnote).contains("cardFrame")
              && !code(footnote).contains("gesture"))
    // WHICH IS WHAT KEEPS THE CARD IT IS WRITTEN ON WHOLE: a session card is one `Button`, and a
    // footnote that took a press of its own would put a dead patch on the way to that terminal.
    // What makes the press land is WHERE the footnote is drawn - inside the button's label - so
    // that is what is asserted here, by position. The check that stood here read the card's
    // accessibility hint instead, which says what the CARD does and nothing at all about the
    // footnote's place in it (codex review of b226640).
    let labelEnd = session.range(of: "}\n        .buttonStyle(.plain)")
    let footnoteDrawn = session.range(of: "SessionUnclaimedFootnote(project: unclaimed,")
    check("the footnote is drawn inside the card's Button label, which is what a press lands on",
          (labelEnd.flatMap { end in footnoteDrawn.map { $0.upperBound < end.lowerBound } })
              == true)
    check("…and that button is still the one that says what a press does",
          session.contains(".accessibilityHint(Text(L(\"Click to bring its terminal"
                           + " to the front\")))"))
    // AS TALL AS WHATEVER IT IS SEATED BESIDE. A grid row is as tall as the tallest card in it, and
    // an unclaimed card is three lines where a session card is five: laid out at its own height it
    // stopped halfway down its cell (Albert, 2026-09-03). Its own lines stay against the top.
    check("the unclaimed card fills the height of the row it is seated in",
          ghost.contains(".frame(maxWidth: .infinity, maxHeight: .infinity,"
                         + " alignment: .topLeading)"))
    // AND SO DOES THE SESSION CARD, for the same reason one card over: the footnote makes some
    // cards a line taller than the rest, and a card laid out at its own height beside one of those
    // stopped short with the row's space showing under it (codex review of b226640).
    check("…and so does a session card, so a footnote cannot leave its neighbour short",
          session.contains(".frame(maxWidth: .infinity, maxHeight: .infinity,"
                           + " alignment: .topLeading)"))
    // Drawn at the board's existing word for "quieter than the others and every bit as true", from
    // the one constant the session card already spells it with.
    check("…drawn at the same opacity a card that cannot report itself is",
          ghost.contains(".opacity(SessionCardView.quietCardOpacity)")
              && ((try? String(contentsOfFile: "Tally/Views/SessionCardView.swift",
                               encoding: .utf8)) ?? "")
                  .contains("static let quietCardOpacity: Double = 0.55"))
    // ONLY THE SESSION CARDS REGISTER A FRAME, which is what keeps the drag from ever hit-testing
    // one of these: the gesture looks a grabbed id up in the frames it was handed.
    check("the grid registers a frame for session cards and for nothing else",
          grid.contains("case let .session(row, footnote):")
              && grid.contains(".cardFrame(id: row.id,")
              && grid.contains("case let .unclaimed(project):")
              && grid.contains("SessionGhostCardView(project: project,"))
    // AND THE FOOTNOTE TRAVELS WITH THE CARD IT IS WRITTEN ON, resolved from the seating the page
    // took in the same pass rather than looked up again per cell.
    check("each card is handed the footnote the seating put on it",
          grid.contains("footnote: seating.footnotes[index]")
              && grid.contains("sessionCard(row, marked: marked == .session(row.id),"
                               + " unclaimed: footnote,"))
    // THE SEATING IS NEVER LEFT WAITING ON A FIELD THAT HAS NOT BEEN PUBLISHED YET. The sampler's
    // map is the canonical answer (it is `realpath` of the row's directory, taken by the pass that
    // produced these roots), and the row's own directory is what a card falls back to, so a board
    // drawn before the first tick still seats every card beside its own leftovers rather than
    // sending the lot to the end.
    check("a card is seated from the sampler's resolved answer, or from the row itself",
          page.contains("ProcessFootprintStore.shared.sessionProjects[$0.id] ?? $0.directory"))
    // UNDER CONNECTED THE BOARD LISTS SESSIONS THAT CAN REPORT THEMSELVES, and an unclaimed card
    // reports nothing by construction - the whole of what it says is that nobody is answering.
    check("the unclaimed cards are listed under All sessions and not under Connected",
          page.contains("listsUnclaimedCards: tabState.sessionFilter == .all)"))
    // …while the COUNT above them is the whole machine's, exactly as the four counts beside it are:
    // narrowing the list below must not change what the summary says. Counted over what is RUNNING
    // unclaimed rather than over the cards, which outlast it by a record apiece.
    check("…while the count of them is taken over the whole machine, filter or no filter",
          page.contains("let running = SessionBoardGhosts.running(everyUnclaimed)")
              && page.contains("sessionsSummary(roster, unclaimed: running)")
              && page.contains("if unclaimed > 0 {")
              && page.contains(
                  "summaryCount(unclaimed, L(\"leftovers\"), colour: TallyColor.warning)"))
    // THE PAGE ASKS ABOUT BOTH KINDS OF CARD BEFORE IT CALLS ITSELF EMPTY. It used to ask only
    // whether there were session rows, so the state these cards exist for - the last session closed
    // and the dev server still running - reached the branch that draws one quiet line, and the card,
    // the counts and the controls went with it (`SessionBoardGhosts.board`).
    check("the page decides what it is out of the sessions AND the unclaimed cards",
          page.contains("SessionBoardGhosts.board(sessions: board.count,")
              && page.contains("case .nothing:") && page.contains("if state == .cards {")
              && !page.contains("if board.isEmpty {"))
    // AND IT COUNTS THE CARDS RATHER THAN WHAT IS STILL RUNNING IN THEM. Asked with the summary's
    // own figure, a machine whose whole reading was a finished reclaim answered "nothing is
    // running": one quiet line, with the filter control gone and no way back to All to see the card
    // that does exist (codex review of a54059c). The summary keeps its own question.
    check("…counted over the cards, the ones kept for a record alone included",
          page.contains("unclaimed: everyUnclaimed.count, seats: seats.count)")
              && page.contains("let running = SessionBoardGhosts.running(everyUnclaimed)"))
    // ONE SPELLING OF THE SET, because two surfaces take it: the page seats it and the drag freezes
    // it, and two readings would freeze a drag against a set the page never drew.
    check("both the page and the drag read the unclaimed cards from one place",
          page.contains("var sessionUnclaimedCards: [ProjectLoad]")
              && page.contains("let everyUnclaimed = sessionUnclaimedCards")
              && page.contains("sessionsGrid(seating, listed: listed, unclaimed: seated,"))
    // AND WHAT THE DRAG FREEZES IS THE ARRAY THE GRID WAS LAID OUT FROM, handed down rather than
    // read again at the grab. It used to ask the page's property inside `onChanged`, which reads
    // the sampler live: the grab lands a frame or more after the body that drew the board, so a
    // stray ending in between froze the drag against a set the page had never drawn (codex review
    // of a54059c). The store is not reachable from the gesture at all any more.
    check("the drag carries the very list the grid drew, not a fresh reading of the store",
          grid.contains("func sessionsReorderGesture(listed: [SessionRosterStore.SessionRow],")
              && grid.contains("unclaimed: [ProjectLoad],\n"
                               + "                                footnotes: [String: ProjectLoad])"
                               + " -> some Gesture {")
              && grid.contains("location: value.location, frozen: board,\n"
                               + "                        unclaimed: unclaimed,"
                               + " footnote: footnotes[row.id])")
              && !grid.contains("unclaimed: sessionUnclaimedCards)")
              && grid.contains("sessionsReorderGesture(listed: listed, board: board,\n"
                               + "                                                    unclaimed:"
                               + " unclaimed, footnotes: footnotes))"))
    // AND THE SET IS HELD STILL WHILE A CARD IS IN FLIGHT, exactly as the roster is: the strays are
    // sampled every two seconds, and one appearing or ending mid-carry would insert or remove a card
    // in the grid under the pointer - moving every card after it and re-hit-testing the drag against
    // seats nobody was aiming at.
    check("the drag freezes the unclaimed cards along with the board it started on",
          grid.contains("let unclaimed: [ProjectLoad]")
              && page.contains("let seated = sessionLift?.unclaimed ?? everyUnclaimed"))
    // AND THE FLOATING COPY IS A COPY. It was built with no footnote at all, so a card carrying one
    // lost a line the instant it left its seat - it shrank and jumped under the pointer - and where
    // the mark was on those leftovers rather than on the session, the flame went out for the whole
    // carry (codex review of b226640). Taken from the pass that drew the grid, not recomputed.
    check("the copy in the hand carries the footnote the grab found on that card",
          grid.contains("let footnote: ProjectLoad?")
              && grid.contains("let footnotes = sessionCardFootnotes(cards)")
              && grid.contains("unclaimed: unclaimed, footnote: footnotes[row.id])")
              && grid.contains("unclaimed: lift.footnote,"))
    check("…and the flame with it, when it is the leftovers that are wearing it",
          grid.contains("unclaimedMarked: lift.footnote"))
    // The reclaim rows are kept by a store the page reads, so what a card is kept FOR is stated
    // where the cards are decided rather than left to the view that draws them.
    check("a card is kept for what this app is watching and what it has done",
          page.contains("remembering: Set(reclaim.watching.map(\\.project)"
                        + " + reclaim.records.map(\\.project))"))
    // ONE WORD, ONE MEANING. The card's own field says what it is counting now, and the page no
    // longer uses the bare word anywhere - which is what stopped it meaning two things at once.
    check("a session's own re-parented jobs are called background jobs on the card",
          card.contains("backgroundUnit: L(\"background jobs\")"))
    for source in [page, grid, ghost, card] {
        check("…and the bare word is on no surface of this page",
              !source.contains("L(\"background\")"))
    }
    // MARK: where the machine's flame is drawn

    // DRAWN ONLY WHEN IT IS TRUE, AND NOTHING HELD OPEN FOR IT WHEN IT IS NOT. It began as a
    // reserved slot in front of the title, which is how the rollup row it came off did it, and on a
    // grid of cards that is the wrong trade: the empty slot showed up as a gap between the state dot
    // and the project name on every card on the board (Albert, on the first live capture,
    // 2026-09-03). Both halves are pinned, because either alone comes back as the same defect.
    check("the flame is one shared glyph, drawn only on the card that wears it",
          state.contains("static var flameMark: some View")
              && state.contains("if marked { Self.flameMark }")
              && ghost.contains("if marked { SessionCardView.flameMark }"))
    check("…and nothing is reserved for it, in either card, at any width",
          !state.contains("flameSlot") && !ghost.contains("flameSlot")
              && !state.contains(": .clear)"))
    /// The headline alone, cut out of the card: this file draws several rows, and "the title comes
    /// before the Spacer" asked of the whole of it would be green for any of them.
    let headline = (state.components(separatedBy: "var sessionCardHeadline: some View {")
        .dropFirst().first ?? "").components(separatedBy: "\n    }").first ?? ""
    check("the harness really cut out the headline", headline.contains("stateDot"))
    // AT THE TRAILING END, PAST THE SPACER, IN FRONT OF THE GRIP: the place on this row where things
    // already come and go, so the title keeps the leading edge whatever else the row is carrying.
    func before(_ first: String, _ second: String, in text: String) -> Bool {
        guard let a = text.range(of: first), let b = text.range(of: second) else { return false }
        return a.lowerBound < b.lowerBound
    }
    check("the title leads the headline and the mark comes after the spacer",
          before("Text(row.title)", "Spacer(minLength: 6)", in: headline)
              && before("Spacer(minLength: 6)", "if marked { Self.flameMark }", in: headline))
    check("…immediately in front of the grip, which is the other thing that comes and goes there",
          before("if marked { Self.flameMark }", "if showsDragHandle { dragHandle }",
                 in: headline))
    // The unclaimed card has no grip, so the mark sits in that same place with nothing after it -
    // and the name still leads, exactly as it does one card over.
    let ghostHead = (ghost.components(separatedBy: "private var headline: some View {")
        .dropFirst().first ?? "").components(separatedBy: "\n    }").first ?? ""
    check("the harness really cut out the unclaimed card's headline",
          ghostHead.contains("Text(verbatim: project.name)"))
    check("…which leads with the name and wears the mark at its trailing end",
          before("Text(verbatim: project.name)", "Spacer(minLength: 6)", in: ghostHead)
              && before("Spacer(minLength: 6)", "if marked { SessionCardView.flameMark }",
                        in: ghostHead))
    // AND THE GRID ASKS WHICH KIND OF CARD THE ONE ANSWER LANDED ON, rather than marking the
    // sessions first and handing the leftovers whatever was left over: one comparison, both kinds
    // of card in it (`SessionBoardGhosts.marked`).
    check("each card asks the one answer whether it is the card",
          grid.contains("marked: marked == .session(row.id)")
              && grid.contains("marked: marked == .unclaimed(project.root)")
              && !grid.contains("orphanedMark")
              && grid.contains("marked: sessionMarkedCard == .session(lift.id)"))
    check("…and the leftovers are handed in on what they alone are spending",
          page.contains("cpuPercent: $0.strayCpuPercent, unclaimed: true"))
    // AND WHERE THE LEFTOVERS ARE A FOOTNOTE, THE FLAME IS DRAWN ON THAT LINE. The mark says which
    // card is burning the machine's cores, and on a card whose project is heaviest on its LEFTOVERS
    // the session is not the thing burning them: a flame on that headline would point the eye at
    // the one session on the board doing nothing wrong (`SessionBoardGhosts.marked` was written for
    // exactly this shape, and the footnote is where the answer now lands).
    check("the footnote wears the mark at the end of its own line",
          footnote.contains("if marked { SessionCardView.flameMark }")
              && before("Spacer(minLength: 0)", "if marked { SessionCardView.flameMark }",
                        in: footnote))
    check("…asked of the project rather than of the session sitting above it",
          grid.contains("unclaimedMarked: footnote.map { marked == .unclaimed($0.root) }")
              && session.contains("marked: unclaimedMarked)"))
    // And a session card whose project is heaviest on the leftovers is handed no mark of its own:
    // one comparison answers `.unclaimed`, so the card's own test is false by construction.
    check("…so the session's headline stays unmarked while its footnote is flamed",
          SessionBoardGhosts.marked(
              heaviest: tally,
              among: [.init(key: "100", root: tally, cpuPercent: 5),
                      .init(key: tally, root: tally, cpuPercent: 200, unclaimed: true)])
              != .session("100"))

    // MARK: what the card draws about the leftovers

    /// The card's body alone, cut out the way the headline above is: this file draws several rows,
    /// and a question asked of the whole of it would be answered by any of them.
    let ghostBody = (ghost.components(separatedBy: "    var body: some View {")
        .dropFirst().first ?? "").components(separatedBy: "\n    }").first ?? ""
    check("the harness really cut out the card's body", ghostBody.contains("headline"))
    /// And the footnote's own body, cut out the same way: it draws a line and two kinds of row, and
    /// a question asked of the whole file would be answered by any of them.
    let footnoteBody = (footnote.components(separatedBy: "    var body: some View {")
        .dropFirst().first ?? "").components(separatedBy: "\n    }").first ?? ""
    check("the harness really cut out the footnote's body",
          footnoteBody.contains("reclaimRow(icon: \"eye\""))
    // THE STRAYS' OWN FIGURES, NEVER THE PROJECT'S TOTAL (`ProjectLoad.strayCpuPercent`): the total
    // is the sessions' cores plus these, so a checkout running a session at 300% and one abandoned
    // server at 20 drew 320% under "no session is running them" - true of the project, false of this
    // card, and counted a second time on the session card sitting immediately before it.
    check("the reading states what the leftovers are spending and nothing the sessions are",
          footnote.contains("project.strayCpuPercent.map")
              && footnote.contains("ProcessTree.memoryText(project.strayMemoryBytes)")
              && !footnote.contains("project.cpuPercent")
              && !footnote.contains("project.memoryBytes")
              && !ghost.contains("project.cpuPercent") && !ghost.contains("project.memoryBytes"))
    // AND A READING KEPT ONLY FOR ITS RECORD SAYS NOTHING ABOUT LEFTOVERS THAT ARE NO LONGER THERE:
    // no amber word calling for a look at something already dealt with, and no row of zeroes nobody
    // read - under a session card as well as on the card of a checkout whose sessions have ended.
    check("…and states neither the amber word nor a figure once nothing is left running",
          ghostHead.contains("if project.strayProcesses > 0 {")
              && footnoteBody.contains("if project.strayProcesses > 0 {"))
    // WHAT IS LEFT IN THAT STATE IS THE RECLAIM ROWS, which is what keeps the reading on the page at
    // all once the last stray of a checkout has been ended: the rows are outside that test.
    check("…while what this app did about it is drawn whether or not anything is still running",
          before("if project.strayProcesses > 0 {", "ForEach(watching) { watch in",
                 in: footnoteBody)
              && footnoteBody.contains("ForEach(records) { record in"))

    // Every word these cards added, in all four translations: the app ships five languages, and a
    // string that reaches somebody in English on a Japanese machine is a missing translation nobody
    // notices until they see it.
    let strings = ((try? Data(contentsOf: URL(fileURLWithPath:
        "Tally/Resources/Localizable.xcstrings")))
        .flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any])?["strings"]
        as? [String: Any] ?? [:]
    check("the string catalogue is readable from this suite", !strings.isEmpty)
    for key in ["leftovers", "background jobs", "%@, no session is running them"] {
        let localizations = (strings[key] as? [String: Any])?["localizations"] as? [String: Any]
            ?? [:]
        check("\"\(key)\" is translated into every language Tally ships",
              AppLocaleSupported.allSatisfy { localizations[$0] != nil })
    }
    // THE SENTENCE TAKES THE COUNT AND THE COUNTED WORD COMES FROM THE PAIR THE CARDS ALREADY USE,
    // so a translator sees the sentence whole and the plural is still decided where the bundle is.
    check("…the sentence carrying the one placeholder the count is put into",
          "%@, no session is running them".components(separatedBy: "%@").count == 2
              && footnote.contains("L(project.strayProcesses == 1 ? \"proc\" : \"procs\")"))
    // AND NO NEW WORD WAS COINED FOR THE FOOTNOTE. Under a session card the whole reading is one
    // line, so it states the count rather than the sentence - out of the same catalogue entry the
    // sentence puts into itself, which is what keeps one spelling of "3 procs" on this board.
    check("…and the one-line form states that same count rather than a string of its own",
          footnote.contains("String(format: L(\"%@, no session is running them\"), counted)")
              && footnote.contains("Text(verbatim: counted)"))
    // The word the old section's amber was spent on is the word this reading's amber is spent on:
    // the reading somebody would act on, rather than a figure beside it. On both surfaces - the
    // card's headline, and the footnote under a session card, where nothing else names it.
    for source in [ghost, footnote] {
        check("the leftovers say so in the colour the stray count used to be drawn in",
              source.contains("Text(L(\"leftovers\"))")
                  && source.contains(".font(.caption2).foregroundStyle(TallyColor.warning)"))
    }
    // AND THE WORD IT SHIPPED WITH FOR A DAY IS GONE FROM EVERY SURFACE somebody reads, the summary
    // count included. `unclaimed` is a word about a CLAIM nobody on this page ever makes: what
    // these processes are is what a session left behind (Albert, 2026-09-03). The spelling survives
    // in this package's own type and case names on purpose - renaming those would be churn in every
    // file that draws one, and none of them reaches anybody reading the board - so what is asserted
    // is the catalogue lookups rather than the identifiers.
    for source in [page, grid, ghost, footnote, session] {
        check("…and no surface of this page still looks the retired word up",
              !source.contains("L(\"unclaimed\")"))
    }
    check("…the count beside the board saying the same word its cards do",
          page.contains("summaryCount(unclaimed, L(\"leftovers\"), colour: TallyColor.warning)")
              && ((strings["unclaimed"] as? [String: Any]) == nil))
}
