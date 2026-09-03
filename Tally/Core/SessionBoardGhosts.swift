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

    /// The projects that get a card of their own: the ones running work no session accounts for.
    ///
    /// A PROJECT RUNNING SEVERAL SESSIONS NO LONGER PRODUCES A ROW, which the rollup's own draw test
    /// counted as one of its two reasons to exist (`MachineLoadRollup.isWorthDrawing`). Its cards
    /// are on the page and each states its own figures; what nothing states is their TOTAL, and that
    /// is deliberately still missing rather than quietly restored as a second layer.
    // TODO: project total line for multi-session projects, direction package follow-up.
    static func unclaimed(in load: MachineLoad) -> [ProjectLoad] {
        load.projects.filter { $0.strayProcesses > 0 }
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
        /// The card's key, as the board spells it: the supervisor pid.
        var key: String
        /// The project this session is working in, resolved.
        var root: String
        /// What this card's own tree is burning, which is what separates two cards on one project.
        var cpuPercent: Double?
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
    /// - Returns: the card to mark, or nothing when no listed card is working in that project - in
    ///   which case its unclaimed card wears the mark instead.
    static func marked(heaviest: String?, among cards: [CardLoad]) -> String? {
        guard let heaviest else { return nil }
        return cards.filter { $0.root == heaviest }.max {
            ($0.cpuPercent ?? 0) == ($1.cpuPercent ?? 0)
                ? $0.key > $1.key : ($0.cpuPercent ?? 0) < ($1.cpuPercent ?? 0)
        }?.key
    }
}
