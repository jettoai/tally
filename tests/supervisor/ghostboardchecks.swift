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
          SessionBoardGhosts.unclaimed(in: load).map(\.root) == [api, sibling])
    // A PROJECT RUNNING SEVERAL SESSIONS NO LONGER PRODUCES A ROW, which the old section drew for.
    // Its cards are on the page and each states its own figures; their TOTAL is what nothing states,
    // and it is deliberately still missing rather than restored as a second layer.
    check("…and a busy project with nothing left over gets none",
          !SessionBoardGhosts.unclaimed(in: load).contains { $0.root == tally })
    check("a machine with nothing left over anywhere draws no such card at all",
          SessionBoardGhosts.unclaimed(in: MachineLoad(projects: [project(tally, sessions: 1,
                                                                         strays: 0)])).isEmpty)

    // MARK: where those cards sit

    // BESIDE THE WORK THEY ARE ABOUT: after the LAST card of their project, so a checkout running
    // three sessions keeps its three cards together and its leftovers come after all of them.
    check("an unclaimed card follows the last session card of its own project",
          SessionBoardGhosts.seats(sessionDirectories: [tally, sibling, tally],
                                   unclaimed: [tally], sortsByState: false)
              == [.session(0), .session(1), .session(2), .unclaimed(tally)])
    check("…and sits directly after it when that project has one session",
          SessionBoardGhosts.seats(sessionDirectories: [tally, sibling],
                                   unclaimed: [tally], sortsByState: false)
              == [.session(0), .unclaimed(tally), .session(1)])
    // A CARD IS MATCHED BY CONTAINMENT, NEVER BY TWO STRINGS BEING EQUAL, which is the rule the
    // strays themselves are filed by: a session started one directory deeper is still a session of
    // that project, and an equality test drops its ghost at the far end of the board where it reads
    // as a checkout nobody on the page is working in.
    check("a session working inside the project still has its unclaimed card beside it",
          SessionBoardGhosts.seats(sessionDirectories: [tally + "/apps/web", sibling],
                                   unclaimed: [tally], sortsByState: false)
              == [.session(0), .unclaimed(tally), .session(1)])
    check("…and two sessions at different depths of one project keep it after the last of them",
          SessionBoardGhosts.seats(sessionDirectories: [tally + "/apps/web", sibling, tally],
                                   unclaimed: [tally], sortsByState: false)
              == [.session(0), .session(1), .session(2), .unclaimed(tally)])
    // AND CONTAINMENT IS ON PATH COMPONENTS RATHER THAN CHARACTERS, which the shared rule already
    // guarantees (`MachineLoadRollup.project`): `tally-wt1` starts with `tally` and is a different
    // project, so its card must not adopt the other one's leftovers.
    check("a sibling whose name merely starts the same way does not take that card",
          SessionBoardGhosts.seats(sessionDirectories: [sibling], unclaimed: [tally],
                                   sortsByState: false)
              == [.session(0), .unclaimed(tally)])
    // A worktree lives inside its repository, and both can have leftovers: the nearer root wins, so
    // each card sits beside the session actually working in it.
    check("a worktree's card takes the worktree's leftovers, not the repository's",
          SessionBoardGhosts.seats(sessionDirectories: [tally + "/.worktrees/feat", tally],
                                   unclaimed: [tally, tally + "/.worktrees/feat"],
                                   sortsByState: false)
              == [.session(0), .unclaimed(tally + "/.worktrees/feat"), .session(1),
                  .unclaimed(tally)])
    // The state this card exists for: the session closed and its dev server did not. There is
    // nothing on the page for it to sit beside, so it goes at the end.
    check("a project with no session card left goes to the end of the board",
          SessionBoardGhosts.seats(sessionDirectories: [tally], unclaimed: [api, sibling],
                                   sortsByState: false)
              == [.session(0), .unclaimed(api), .unclaimed(sibling)])
    // A session that published no directory is arranged by nothing and cannot carry a card after it.
    check("…as it does when the only card on the board says nothing about where it is",
          SessionBoardGhosts.seats(sessionDirectories: [nil], unclaimed: [tally], sortsByState: false)
              == [.session(0), .unclaimed(tally)])
    // THE STATE SORT MEANS "IN THE ORDER I HAVE TO ACT ON THEM", and an unclaimed card is in none of
    // those states: not blocked, not working, not idle. Seating it among them would put a card that
    // answers no state into a board sorted by state.
    check("with the state sort on, every unclaimed card goes last",
          SessionBoardGhosts.seats(sessionDirectories: [tally, sibling], unclaimed: [tally, api],
                                   sortsByState: true)
              == [.session(0), .session(1), .unclaimed(tally), .unclaimed(api)])
    check("a board of unclaimed cards and no sessions is just those cards",
          SessionBoardGhosts.seats(sessionDirectories: [], unclaimed: [api], sortsByState: false)
              == [.unclaimed(api)])
    check("…and an ordinary board draws exactly its sessions",
          SessionBoardGhosts.seats(sessionDirectories: [tally, sibling], unclaimed: [],
                                   sortsByState: false) == [.session(0), .session(1)])

    // MARK: which card wears the flame

    let cards = [SessionBoardGhosts.CardLoad(key: "100", root: tally, cpuPercent: 40),
                 SessionBoardGhosts.CardLoad(key: "200", root: tally, cpuPercent: 260),
                 SessionBoardGhosts.CardLoad(key: "300", root: sibling, cpuPercent: 900)]
    // A mark on every card of a busy project points at nothing, so it goes to the card spending the
    // most of its own - which is the card somebody opening this board is looking for.
    check("the heaviest project's mark lands on its busiest card",
          SessionBoardGhosts.marked(heaviest: tally, among: cards) == "200")
    check("…and on the only card of a project running one session",
          SessionBoardGhosts.marked(heaviest: sibling, among: cards) == "300")
    // Below a whole core nothing is marked at all (`MachineLoadRollup.markedAbovePercent`), which
    // reaches here as no heaviest project.
    check("a quiet machine marks nobody",
          SessionBoardGhosts.marked(heaviest: nil, among: cards) == nil)
    // AND THE MARK FALLS TO THE UNCLAIMED CARD when no session card answers to that project, which
    // is the whole reason this returns an optional rather than a card: the checkout burning the
    // machine can be the one whose session has ended.
    check("a heaviest project with no card on the page hands its mark to nobody here",
          SessionBoardGhosts.marked(heaviest: api, among: cards) == nil)
    // Two cards on one figure would otherwise trade the mark from tick to tick, which is the flicker
    // the board's stable order was written to stop. The smaller key wins, as it does one file over.
    check("two cards on the same figure settle the mark on the key rather than on the order",
          SessionBoardGhosts.marked(
              heaviest: tally,
              among: [.init(key: "900", root: tally, cpuPercent: 300),
                      .init(key: "100", root: tally, cpuPercent: 300)]) == "100"
              && SessionBoardGhosts.marked(
                  heaviest: tally,
                  among: [.init(key: "100", root: tally, cpuPercent: 300),
                          .init(key: "900", root: tally, cpuPercent: 300)]) == "100")
    // A card whose tree has not been read twice yet has no rate, and it must not beat one that has.
    check("a card with no rate yet does not take the mark from a card with one",
          SessionBoardGhosts.marked(
              heaviest: tally,
              among: [.init(key: "100", root: tally, cpuPercent: nil),
                      .init(key: "200", root: tally, cpuPercent: 1)]) == "200")

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
    check("the five sources this suite reads are readable",
          !page.isEmpty && !grid.isEmpty && !ghost.isEmpty && !card.isEmpty && !state.isEmpty)
    // THE LAYER IS GONE, not merely unused: two files went with it, and a page that still drew
    // either section would be saying everything twice however good the cards are.
    check("the page draws no rollup section and no reclaim section above the cards",
          !page.contains("sessionsProjectRollup") && !page.contains("sessionsReclaimNotes")
              && !FileManager.default.fileExists(atPath: "Tally/Views/SessionBoardRollup.swift")
              && !FileManager.default.fileExists(atPath: "Tally/Views/SessionBoardReclaim.swift"))
    // The reclaim rows themselves are NOT gone: they moved onto the card of the project they are
    // about, which is the one surface that answers "is it about to do that again".
    check("…the reclaim rows now being drawn on the card of the project they are about",
          ghost.contains("OrphanReclaimStore.shared.watching.filter { $0.project == project.root }")
              && ghost.contains(
                  "OrphanReclaimStore.shared.records.filter { $0.project == project.root }")
              && ghost.contains("reclaimRow(icon: \"eye\", tint: TallyColor.warning"))
    // NOT A SESSION, AND IT NEVER PRETENDS TO BE ONE: no terminal to jump to, so no button, no
    // hover and no pointer; no session to arrange by, so no grip and no frame for the drag to
    // hit-test against. Each of these is a promise the card would otherwise make and not keep.
    check("the unclaimed card is not a button and answers no pointer",
          !ghost.contains("Button") && !ghost.contains("onHover")
              && !ghost.contains("onTapGesture") && !ghost.contains("tallyTooltip"))
    check("…and is not offered to the drag at all",
          !ghost.contains("dragHandle") && !ghost.contains("showsDragHandle")
              && !ghost.contains("cardFrame"))
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
          grid.contains("case let .session(row):") && grid.contains(".cardFrame(id: row.id,")
              && grid.contains("case let .unclaimed(project):")
              && grid.contains("SessionGhostCardView(project: project,"))
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
          page.contains("let unclaimed = tabState.sessionFilter == .all ? everyUnclaimed : []"))
    // …while the COUNT above them is the whole machine's, exactly as the four counts beside it are:
    // narrowing the list below must not change what the summary says.
    check("…while the count of them is taken over the whole machine, filter or no filter",
          page.contains("sessionsSummary(roster, unclaimed: everyUnclaimed.count)")
              && page.contains("if unclaimed > 0 {")
              && page.contains(
                  "summaryCount(unclaimed, L(\"unclaimed\"), colour: TallyColor.warning)"))
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

    // Every word these cards added, in all four translations: the app ships five languages, and a
    // string that reaches somebody in English on a Japanese machine is a missing translation nobody
    // notices until they see it.
    let strings = ((try? Data(contentsOf: URL(fileURLWithPath:
        "Tally/Resources/Localizable.xcstrings")))
        .flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any])?["strings"]
        as? [String: Any] ?? [:]
    check("the string catalogue is readable from this suite", !strings.isEmpty)
    for key in ["unclaimed", "background jobs", "%@, no session is running them"] {
        let localizations = (strings[key] as? [String: Any])?["localizations"] as? [String: Any]
            ?? [:]
        check("\"\(key)\" is translated into every language Tally ships",
              AppLocaleSupported.allSatisfy { localizations[$0] != nil })
    }
    // THE SENTENCE TAKES THE COUNT AND THE COUNTED WORD COMES FROM THE PAIR THE CARDS ALREADY USE,
    // so a translator sees the sentence whole and the plural is still decided where the bundle is.
    check("…the sentence carrying the one placeholder the count is put into",
          "%@, no session is running them".components(separatedBy: "%@").count == 2
              && ghost.contains("L(project.strayProcesses == 1 ? \"proc\" : \"procs\")"))
    // The word the old section's amber was spent on is the word this card's amber is spent on: the
    // reading somebody would act on, rather than a figure beside it.
    check("the unclaimed card says so in the colour the stray count used to be drawn in",
          ghost.contains("Text(L(\"unclaimed\"))")
              && ghost.contains(".font(.caption2).foregroundStyle(TallyColor.warning)"))
}
