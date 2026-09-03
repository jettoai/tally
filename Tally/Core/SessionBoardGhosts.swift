import Foundation

/// WHAT THE MACHINE ROLLUP LOOKS LIKE ONCE IT IS DRAWN AS CARDS: which projects get a card of their
/// own, where those cards sit among the sessions', and which card wears the mark.
///
/// THE PAGE USED TO SAY THE SAME THINGS TWICE. Above the board sat a Projects section - one row per
/// checkout, with the heaviest one flamed and an amber count of the work no session accounts for -
/// and under every row was a card repeating most of it. Worse, one WORD meant two things on one
/// page: a row's `background` was work nobody is answering for, and a card's was the session's own
/// re-parented jobs (`ProcessTree.segments`). What the rollup alone could say - the flame and the
/// leftovers - is what moved onto the cards; the layer went (Albert, 2026-09-03).
///
/// PURE, so the assertion harness can state every case with no board around it: what is handed in
/// is the projects the cards are working in and the projects with leftovers, and what comes back is
/// the order a grid lays out.
enum SessionBoardGhosts {

    /// The projects that get a card of their own: the ones running work no session accounts for,
    /// and the ones this app has just finished doing something about.
    ///
    /// A PROJECT RUNNING SEVERAL SESSIONS NO LONGER PRODUCES A ROW, which the old section counted as
    /// one of its two reasons to exist. Its cards are on the page and each states its own figures;
    /// what nothing states is their TOTAL, and that is deliberately still missing rather than
    /// quietly restored as a second layer.
    ///
    /// AND A CARD OUTLIVES THE LEFTOVERS IT WAS DRAWN FOR, which is what `remembering` is: this card
    /// is where a reclaim is reported now that the section that used to report it is gone
    /// (`SessionGhostCardView` draws the watch rows and the records). A successful reclaim ends the
    /// last stray of that project, so a card admitted on strays alone disappears on the very tick
    /// its record is written and "Tally ended your dev server" is a sentence nobody can ever have
    /// read. The record is the reading, and it is kept for as long as the store keeps it
    /// (`OrphanReclaimStore.keptRecords`, a dozen, in memory only).
    ///
    /// Such a card has NO figures and no amber `leftovers` - there is nothing left running there
    /// any more - so it states the project and what happened, and nothing it cannot stand behind.
    ///
    /// AND THE ONE THIS APP COULD NOT NAME STILL GETS A CARD, under a word instead of a path.
    ///
    /// A KILL NOBODY IS TOLD ABOUT IS INDISTINGUISHABLE FROM A CRASH, and for one shape of kill that
    /// is exactly what this page had become. A reclaim whose tree the machine would not place is
    /// recorded with an EMPTY project, deliberately - the kill still has to happen and be reported
    /// (`OrphanReclaimStore.round`) - and the project inbox cannot take that one, having no
    /// repository to write into (`OrphanReclaimStore.deliver` returns on an empty project). The
    /// panel is therefore its only channel, and for a day this refused it too: an empty root was
    /// dropped here, so a tree this app really did send SIGTERM and SIGKILL to was reported nowhere
    /// at all (codex review of b226640).
    ///
    /// WHAT IT IS NOT ALLOWED TO BE IS A BLANK CARD. `URL(fileURLWithPath: "").lastPathComponent` is
    /// the empty string, so the card that shape produced had no name on it, and a card naming
    /// nothing is worse than the silence it replaced. It is named for what it is instead, and the
    /// naming happens HERE rather than in the view because this is where a card's name is decided
    /// for every other card too (`MachineLoadRollup.rows`).
    ///
    /// AND IT TAKES NO SESSION'S FOOTNOTE, which is what makes the card safe to draw at all: an
    /// empty root is a PREFIX of every path on this machine, so a rule matching on containment would
    /// file every session on the board under it. The match refuses it on its own side
    /// (`MachineLoadRollup.project(of:roots:)`), so nothing here has to remember to.
    ///
    /// - Parameters:
    ///   - remembering: the roots this app is watching or has acted in. A root with no row of its
    ///     own gets a card with no load, because a project whose work has all ended has no row.
    // TODO: project total line for multi-session projects, direction package follow-up.
    static func unclaimed(in load: MachineLoad, remembering roots: Set<String>) -> [ProjectLoad] {
        var cards = load.projects.filter { $0.strayProcesses > 0 }
        for root in roots where !cards.contains(where: { $0.root == root }) {
            cards.append(ProjectLoad(root: root,
                                     name: URL(fileURLWithPath: root).lastPathComponent,
                                     cpuPercent: nil, memoryBytes: 0, sessions: 0,
                                     strayProcesses: 0))
        }
        // The rollup's own order, by name, for the reason it sorts that way: a set of cards that
        // re-ordered itself as the machine breathed would be unreadable (`MachineLoad.projects`).
        // The unnameable one is not in that order because it is not in that alphabet: it goes last,
        // where a card nobody can look up by name is found without moving the ones that can.
        let named = cards.filter { !$0.root.isEmpty }
            .sorted { ($0.name, $0.root) < ($1.name, $1.root) }
        return named + cards.filter(\.root.isEmpty).map {
            var card = $0
            card.name = L("unknown project")
            return card
        }
    }

    /// How many of these cards are about work that is still RUNNING, which is what the board's amber
    /// count is and what decides whether the page has anything to count at all. Not the number of
    /// cards: one kept for its record alone has nothing unclaimed in it any more, and counting it
    /// would be calling for a look at something this app has already dealt with.
    static func running(_ cards: [ProjectLoad]) -> Int {
        cards.filter { $0.strayProcesses > 0 }.count
    }

    /// WHAT THE PAGE HAS TO DRAW, which is a different question from "is anybody running sessions".
    ///
    /// THE BOARD IS NOT THE ONLY THING ON THE BOARD ANY MORE. The page used to ask one question -
    /// are there session rows - and answer an empty one with a single quiet line; every other case
    /// was reached inside the branch that had rows. An unclaimed card holds no session, so the state
    /// this whole package exists for - the last session closed and its dev server did not - fell
    /// into the branch that draws the empty line, and the card, the counts and the controls with it.
    /// The reading was drawn only while a session was there to make it unnecessary.
    ///
    /// AND IT IS THE CARDS THAT ARE COUNTED HERE, NOT WHAT IS STILL RUNNING IN THEM. This was asked
    /// with the amber summary figure (`running`), which is zero for a card kept only for what this
    /// app has already done about it. Under Connected such a card is not listed either, so a machine
    /// whose whole reading was "Tally ended your dev server" answered `.nothing`: one quiet line,
    /// and the filter control gone with it - leaving nobody a way back to All to see the card that
    /// does exist (codex review of a54059c). The summary figure keeps its own question.
    ///
    /// - Parameter unclaimed: how many unclaimed CARDS this machine has, the ones kept for a record
    ///   alone included.
    static func board(sessions: Int, unclaimed: Int, seats: Int) -> BoardState {
        if seats > 0 { return .cards }
        return sessions == 0 && unclaimed == 0 ? .nothing : .nothingListed
    }

    /// The three things this page can be.
    enum BoardState: Equatable {
        /// No session and nothing left over anywhere: an ordinary answer, said in one line.
        case nothing
        /// Something for the summary to count, and nothing the filter lets through - a different
        /// sentence, because the wrong one reads as the board having lost what the counts still say.
        case nothingListed
        /// Cards, of either kind.
        case cards
    }

    /// One seat on the board: a session's card, or a project's unclaimed one.
    ///
    /// THE SESSION IS AN INDEX RATHER THAN A ROW, which is what keeps this file free of the board's
    /// own types: the caller holds the listed sessions and this says what order to lay them out in.
    enum Seat: Equatable {
        /// The session at this position in the list handed in.
        case session(Int)
        /// The unclaimed card for this project root.
        case unclaimed(String)
    }

    /// HOW THE BOARD IS LAID OUT: the seats in order, and which session card each project's
    /// leftovers are written along the bottom of.
    struct Seating: Equatable {
        /// The cards, in the order the grid lays them out.
        var seats: [Seat]
        /// The project whose leftovers are drawn as a footnote under the session card at this
        /// index. At most one project per card, and at most one card per project.
        var footnotes: [Int: String]
    }

    /// WHERE A CHECKOUT'S LEFTOVERS ARE SAID, given the projects the listed session cards are
    /// working in.
    ///
    /// A FOOTNOTE UNDER THE PROJECT'S LAST SESSION CARD, NOT A CARD OF ITS OWN BESIDE IT. Every
    /// unclaimed reading used to take a card, seated after the last session card of its project.
    /// Read on a live board that is two defects rather than a layout preference (Albert, on the
    /// board's first day, 2026-09-03): a three-line card in a grid row as tall as the session card
    /// beside it left a block of empty card under itself, and a card inserted mid-board pushed
    /// every card after it one seat along, so the two columns no longer stood project by project.
    /// The reading is a line about the checkout the card above is already working in, and that is
    /// exactly what a footnote is.
    ///
    /// THE LAST CARD OF THE PROJECT, after them all rather than after the first: a checkout running
    /// three sessions keeps its three cards together, and the leftovers are said once, at the end
    /// of them, rather than on whichever card happens to come first.
    ///
    /// A PROJECT WITH NO SESSION CARD LEFT STILL GETS A CARD, at the end of the board, in the order
    /// the rollup already put its rows in (by name). That is the state this whole package exists for
    /// - the session closed and its dev server did not - and there is nothing on the page for it to
    /// sit beside, so it is a card and it goes where a card with no neighbour can be found without
    /// disturbing the ones that have one.
    ///
    /// AND THE STATE SORT NO LONGER NEEDS A RULE OF ITS OWN. It used to send every unclaimed card to
    /// the end, on the ground that a card answering no state cannot be seated among cards sorted by
    /// state (`SessionRosterStore.seatingOnOpen`). The only cards that were ever seated among them
    /// are footnotes now - they travel with the card they are written on, whatever order that card
    /// is in - and the cards that remain already go last in both orders. One rule, both orders.
    ///
    /// A CARD IS MATCHED TO A PROJECT BY CONTAINMENT, NEVER BY TWO STRINGS BEING EQUAL, and that is
    /// the one rule the strays are already filed by (`MachineLoadRollup.project(of:roots:)`): the
    /// leftovers of `~/w/api` are the processes working ANYWHERE inside it, so a session working in
    /// `~/w/api/apps/web` is a session of that project and its card is what carries the footnote.
    /// Asked the same way on both sides, a page cannot file a stray under a project its own session
    /// card is not filed under - which is what an equality test does the moment a session is started
    /// one directory deeper (the reading drifts to the end of the board, where it reads as a project
    /// nobody on the page is working in).
    ///
    /// THE ROOT THIS APP COULD NOT NAME IS SEATED LIKE ANY OTHER CHECKOUT WITH NO SESSION ON IT,
    /// which is a reversal: it was refused here for a day, on the ground that it could only arrive
    /// as a card with no name. It arrives as a NAMED card now (`unclaimed(in:remembering:)`), and
    /// refusing it was refusing the only surface a reclaim in an unplaceable tree has left. Nothing
    /// special is needed to keep it off the session cards: the containment rule declines to match an
    /// empty root, so it owns no card and therefore takes a seat of its own, at the end.
    ///
    /// - Parameters:
    ///   - sessionDirectories: where each listed session card is working, in board order, at
    ///     whatever depth it published. Nothing for a session that published no directory at all -
    ///     such a card is arranged by nothing (`SessionRosterStore.orderKey`) and carries no
    ///     footnote.
    ///   - unclaimed: the roots that have an unclaimed reading, in the order they are to be drawn.
    ///   - listsUnclaimedCards: whether a project with no session card on the page may take a card
    ///     of its own. False under Connected, which lists the sessions that can report themselves
    ///     and an unclaimed card reports nothing by construction. THE FOOTNOTES ARE DRAWN EITHER
    ///     WAY: one is a fact about the checkout a listed card is working in, which is not a thing
    ///     the filter is narrowing.
    ///
    static func seating(sessionDirectories: [String?], unclaimed: [String],
                        listsUnclaimedCards: Bool = true) -> Seating {
        // The LAST card of each project, which is the one its leftovers are written under.
        var last: [String: Int] = [:]
        for (index, directory) in sessionDirectories.enumerated() {
            guard let directory,
                  let root = MachineLoadRollup.project(of: directory, roots: unclaimed)
            else { continue }
            last[root] = index
        }
        // One project resolves each directory (the longest root containing it), so no card can be
        // handed two footnotes and the map cannot lose one.
        var footnotes: [Int: String] = [:]
        for (root, index) in last { footnotes[index] = root }
        let seats = sessionDirectories.indices.map { Seat.session($0) }
        guard listsUnclaimedCards else { return Seating(seats: seats, footnotes: footnotes) }
        // Whatever no card on the page is working in, in the order it was handed over.
        return Seating(seats: seats + unclaimed.filter { last[$0] == nil }.map(Seat.unclaimed),
                       footnotes: footnotes)
    }

    /// One card's share of its project, which is all the mark below needs to know about it.
    struct CardLoad: Equatable {
        /// The card's key, as the board spells it: the supervisor pid, or the project root for an
        /// unclaimed card. The two cannot collide, which is what lets one list hold both.
        var key: String
        /// The project this card is working in, resolved.
        var root: String
        /// What this card's own share is burning, which is what separates two cards on one project:
        /// a session's own tree, or the project's strays alone (`ProjectLoad.strayCpuPercent`).
        var cpuPercent: Double?
        /// Whether this is the project's unclaimed card rather than a session's.
        var unclaimed: Bool = false
    }

    /// Which card on the board wears the machine's flame.
    enum Mark: Equatable {
        /// The session card with this key.
        case session(String)
        /// The unclaimed card of this project root.
        case unclaimed(String)
    }

    /// WHICH CARD WEARS THE FLAME, now that the row that used to wear it is gone.
    ///
    /// THE MARK IS STILL DECIDED ON THE PROJECT and is now DRAWN on a card, which is the whole of
    /// this rule: the heaviest checkout is still `MachineLoad.heaviest`, a reading about a directory
    /// rather than about a session (`MachineLoadRollup.markedAbovePercent` says why it is marked
    /// rather than sorted to the top), and what changed is only where the flame is put.
    ///
    /// ONE CARD WEARS IT. A mark on every card of a busy project points at nothing, so it goes to
    /// the one spending the most of its own - the card somebody opening this board is looking for.
    /// Ties settle on the key rather than on the order the cards arrive in: two sessions reading the
    /// same figure would otherwise trade the mark from tick to tick, which is the flicker the stable
    /// row order was written to stop (`MachineLoadRollup.rows`).
    ///
    /// AND THE UNCLAIMED CARD IS ONE OF THE CANDIDATES, on its own strays rather than on its
    /// project's total. It has to be, because the mark is decided on a checkout and the checkout's
    /// cost is the sessions' AND the leftovers': a project sitting at 205% because a session is
    /// spending 5 and an abandoned dev server is spending 200 handed its flame to the 5% card,
    /// which points the eye at the one thing on that board doing nothing wrong. Asked of both kinds
    /// in one comparison rather than of the sessions first, so the answer is the busiest card on
    /// the page and never the busiest session with a busier neighbour.
    ///
    /// - Returns: the card to mark, or nothing when no card handed in is working in that project -
    ///   under Connected, where the unclaimed cards are not listed, that is a checkout whose mark is
    ///   on a card the filter is holding back, and nothing on the page is flamed.
    static func marked(heaviest: String?, among cards: [CardLoad]) -> Mark? {
        guard let heaviest,
              let top = cards.filter({ $0.root == heaviest }).max(by: {
                  ($0.cpuPercent ?? 0) == ($1.cpuPercent ?? 0)
                      ? $0.key > $1.key : ($0.cpuPercent ?? 0) < ($1.cpuPercent ?? 0)
              })
        else { return nil }
        return top.unclaimed ? .unclaimed(top.key) : .session(top.key)
    }

    /// WHERE THE ONE FLAME IS DRAWN, over the whole page, in the two states the page can be in:
    /// resting, and with a card in the hand.
    ///
    /// IT EXISTS BECAUSE THE PAGE HAS THREE PLACES TO DRAW A FLAME AND ONLY ONE FLAME. A seated
    /// card wears it (`SessionCardView.sessionCardHeadline`, `SessionGhostCardView`), the floating
    /// copy's own headline wears it, and so do the leftovers that copy is stating - and each of
    /// those three used to answer the question for itself. Two of them read the mark LIVE and the
    /// third read a snapshot taken at the grab, so a sampler tick that moved the mark mid-carry put
    /// a flame in two places at once: one where the machine says it is now, and one where it was
    /// when the hand closed (codex review of fceaeec).
    ///
    /// SO THE CARRY FREEZES THE MARK FOR THE WHOLE PAGE, not only for the copy. That is what the
    /// carry already does with everything else the seating is a function of - the board's
    /// membership, the unclaimed readings, and which card each of them is written under
    /// (`SessionLift`) - and it is the only arrangement in which the page draws exactly one flame at
    /// every instant. Frozen for the copy alone, a mark that moved to a seated card left two lit
    /// (the copy's stale one and the seat's live one); frozen nowhere, the copy's leftovers went
    /// dark mid-carry, which is the defect this pair was first written for. The freeze lasts as long
    /// as the hand does, and the next pass after the drop is live again.
    ///
    /// THE CARRIED CARD'S SEAT IS EMPTY WHILE IT IS IN FLIGHT (`sessionsGrid` draws it at zero
    /// opacity), which is why a mark landing on it is reported to the copy and to no seat: reported
    /// to both, the count would be right and one of them would be invisible.
    struct FlamePlacement: Equatable {
        /// The floating copy's own headline: the mark is on the session in the hand.
        var carriedHeadline = false
        /// The leftovers that copy is stating: the mark is on the checkout's own strays.
        var carriedLeftovers = false
        /// The seated card that wears it, or nothing when the flame is in the hand or the machine
        /// has no heaviest checkout on this page.
        var seat: Mark? = nil

        /// How many flames the page draws. Never more than one, whatever the state - which is the
        /// property this type exists to make sayable in one place.
        var lit: Int {
            (carriedHeadline ? 1 : 0) + (carriedLeftovers ? 1 : 0) + (seat == nil ? 0 : 1)
        }
    }

    /// - Parameters:
    ///   - mark: the mark the page is reading. Live while nothing is being carried, and the one
    ///     frozen at the grab for as long as something is.
    ///   - carrying: the session in the hand, or nothing when the board is at rest.
    ///   - footnote: the checkout whose leftovers the carried card is stating, if any.
    static func placement(_ mark: Mark?, carrying: String?,
                          footnote root: String?) -> FlamePlacement {
        guard let carrying else { return FlamePlacement(seat: mark) }
        let headline = mark == .session(carrying)
        // A card carrying no leftovers - which is most of them - can never light that half, and a
        // mark on somebody else's leftovers is somebody else's.
        let leftovers = root.map { mark == .unclaimed($0) } ?? false
        return FlamePlacement(carriedHeadline: headline, carriedLeftovers: leftovers,
                              seat: headline || leftovers ? nil : mark)
    }
}
