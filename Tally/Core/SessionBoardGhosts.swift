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
    /// A PROJECT RUNNING SEVERAL SESSIONS NO LONGER PRODUCES A ROW, which the rollup's own draw test
    /// counted as one of its two reasons to exist (`MachineLoadRollup.isWorthDrawing`). Its cards
    /// are on the page and each states its own figures; what nothing states is their TOTAL, and that
    /// is deliberately still missing rather than quietly restored as a second layer.
    ///
    /// AND A CARD OUTLIVES THE LEFTOVERS IT WAS DRAWN FOR, which is what `remembering` is: this card
    /// is where a reclaim is reported now that the section that used to report it is gone
    /// (`SessionGhostCardView` draws the watch rows and the records). A successful reclaim ends the
    /// last stray of that project, so a card admitted on strays alone disappears on the very tick
    /// its record is written and "Tally ended your dev server" is a sentence nobody can ever have
    /// read. The record is the reading, and it is kept for as long as the store keeps it
    /// (`OrphanReclaimStore.keptRecords`, a dozen, in memory only).
    ///
    /// Such a card has NO figures and no amber word - there is nothing unclaimed running there any
    /// more - so it states the project and what happened, and nothing it cannot stand behind.
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
        return cards.sorted { ($0.name, $0.root) < ($1.name, $1.root) }
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

    /// WHERE THE UNCLAIMED CARDS SIT, given the projects the listed session cards are working in.
    ///
    /// BESIDE THE WORK IT IS ABOUT, which is the whole reason this is not simply an appendix: a
    /// checkout's leftovers are read against the sessions in that same checkout, and a card at the
    /// far end of the grid asks the reader to hold a project name in their head while they scroll.
    /// So it follows the LAST card of its project - after them all, rather than after the first, so
    /// a project running three sessions keeps its three cards together.
    ///
    /// A PROJECT WITH NO SESSION LEFT GOES AT THE END, in the order the rollup already put its rows
    /// in (by name), because there is nothing on the page for it to sit beside. That is also the
    /// state this card exists for - the session closed and its dev server did not - so it is the
    /// one a reader most often arrives looking for, and the end of the board is where a card with
    /// no neighbour can be found without disturbing the ones that have one.
    ///
    /// AND WITH THE STATE SORT ON THEY ALL GO LAST. That switch means "the cards are in the order I
    /// have to act on them" (`SessionRosterStore.seatingOnOpen`), and an unclaimed card is in none of
    /// those states: it is not blocked, not working and not idle, so seating it among them would put
    /// a card that answers no state into a board sorted by state.
    ///
    /// A CARD IS MATCHED TO A PROJECT BY CONTAINMENT, NEVER BY TWO STRINGS BEING EQUAL, and that is
    /// the one rule the strays are already filed by (`MachineLoadRollup.project(of:roots:)`): the
    /// leftovers of `~/w/api` are the processes working ANYWHERE inside it, so a session working in
    /// `~/w/api/apps/web` is a session of that project and its card is what the unclaimed one
    /// belongs beside. Asked the same way on both sides, a page cannot file a stray under a project
    /// its own session card is not filed under - which is what an equality test does the moment a
    /// session is started one directory deeper (it drifts to the end of the board, where it reads as
    /// a project nobody on the page is working in).
    ///
    /// - Parameters:
    ///   - sessionDirectories: where each listed session card is working, in board order, at
    ///     whatever depth it published. Nothing for a session that published no directory at all -
    ///     such a card is arranged by nothing (`SessionRosterStore.orderKey`) and no unclaimed card
    ///     follows it.
    ///   - unclaimed: the roots that have an unclaimed card, in the order they are to be drawn.
    ///   - sortsByState: whether the board is being seated by what the sessions are doing.
    static func seats(sessionDirectories: [String?], unclaimed: [String],
                      sortsByState: Bool) -> [Seat] {
        guard !sortsByState else {
            return sessionDirectories.indices.map { Seat.session($0) }
                + unclaimed.map(Seat.unclaimed)
        }
        // Which unclaimed project each card belongs to, and the LAST card of each - so a checkout
        // running several sessions keeps them together and its leftovers come after all of them.
        var owner: [Int: String] = [:]
        var last: [String: Int] = [:]
        for (index, directory) in sessionDirectories.enumerated() {
            guard let directory,
                  let root = MachineLoadRollup.project(of: directory, roots: unclaimed)
            else { continue }
            owner[index] = root
            last[root] = index
        }
        var seats: [Seat] = []
        for index in sessionDirectories.indices {
            seats.append(.session(index))
            if let root = owner[index], last[root] == index { seats.append(.unclaimed(root)) }
        }
        // Whatever no card on the page is working in, in the order it was handed over.
        return seats + unclaimed.filter { last[$0] == nil }.map(Seat.unclaimed)
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
}
