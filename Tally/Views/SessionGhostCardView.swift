import SwiftUI

/// ONE CHECKOUT'S WORK THAT NO SESSION IS ANSWERING FOR, drawn as a card of its own because that
/// checkout has no other card on this board.
///
/// A CARD ONLY WHERE THERE IS NOTHING TO WRITE UNDER. A project still running sessions says this
/// under the last of them, as a footnote (`SessionUnclaimedFootnote`, which draws the body of this
/// card too); what is left for a card of its own is the state this whole package exists for - the
/// last session closed and its dev server did not - where there is no session card to write under
/// and the reading would otherwise be nowhere (`SessionBoardGhosts.seating`).
///
/// THE READING THE CARDS COULD NOT PRODUCE. Every session card answers for its own tree, and a
/// machine can be doing a great deal in the same directories that no live session accounts for - a
/// dev server whose session was closed hours ago, a build started in a terminal, a fan-out that
/// outlived its turn. Read card by card that is a page where nothing is wrong and the total is
/// (`MachineLoadRollup` carries the incident that made it necessary).
///
/// IT USED TO BE A SECOND LAYER ABOVE THE BOARD, and that is what this replaces: a Projects section
/// stating one row per checkout, most of which the cards under it already said, with the one reading
/// they could not - the leftovers - as a field at the end of a row. The reading is worth a card; the
/// layer was not (Albert, 2026-09-03).
///
/// AND IT IS ALSO WHERE A RECLAIM IS REPORTED, which is why one can outlive the leftovers it was
/// drawn for: ending the last stray of a checkout is exactly what makes that checkout stop having
/// any, and a card that went with them would take "Tally ended your dev server" off the page in the
/// same tick it was written (`SessionBoardGhosts.unclaimed(in:remembering:)`). Such a card draws
/// its name and what happened, and none of the fields that would be zero.
///
/// NOT A SESSION, AND IT NEVER PRETENDS TO BE ONE. There is no terminal to jump to, so it is not a
/// button: no hover, no press, no pointer. It cannot be arranged either - the drag arranges PROJECTS
/// by the sessions sitting in them (`SessionBoardOrder`), and this card holds no session - so it
/// carries no grip and registers no frame for the reorder to hit-test (`sessionsGrid`). Drawn at the
/// same opacity as a card that cannot report itself, which is the board's existing word for "quieter
/// than the others, and every bit as true".
struct SessionGhostCardView: View {
    /// The project as the rollup states it: what it is called, what its leftovers are spending, and
    /// how many of them there are (`ProjectLoad`).
    let project: ProjectLoad
    /// Whether this card is the busiest one of the heaviest project on the machine, which an
    /// unclaimed card can be on its own leftovers (`SessionBoardGhosts.marked`).
    var marked: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            headline
            // THE SAME READING THIS BOARD WRITES UNDER A SESSION CARD, from the one view that draws
            // it (`SessionUnclaimedFootnote`). Here it does not have to name itself - the headline
            // one line up has already said the word - and it has the room for the sentence that
            // says what this card is for.
            SessionUnclaimedFootnote(project: project)
        }
        .padding(.horizontal, TallyMetrics.cardPaddingH)
        .padding(.vertical, TallyMetrics.cardPaddingV)
        // AS TALL AS WHATEVER IT IS SEATED BESIDE, with its own lines held against the top. A grid
        // row is as tall as the tallest card in it, and this one is three lines where a session
        // card is five: laid out at its own height it drew a card that stopped halfway down its
        // cell, with the row's ruled space showing under it (Albert, 2026-09-03). The cards it
        // shares a row with are the other checkouts nobody is working in any more, so the row is
        // the same shape whichever of them is the longest.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .tallyCard()
        .opacity(SessionCardView.quietCardOpacity)
        // One element rather than five, for the reason the session card is one: what a reader hears
        // is a card, and the rows inside it are its sentences.
        .accessibilityElement(children: .combine)
    }

    /// What the checkout is called, and what this card is: the same name the session cards of that
    /// project carry (`SessionRosterStore.SessionRow.title` names them the same way), with the one
    /// word that says nobody on this board is answering for what follows.
    ///
    /// THE MARK SITS AT THE TRAILING END AND IS DRAWN ONLY WHEN IT IS TRUE, which is where a session
    /// card wears it too (`SessionCardView.sessionCardHeadline`): in the place that card gives its
    /// grip, which this one has nothing to put in. Nothing is reserved for it, so the name keeps the
    /// leading edge whether or not this checkout is the heaviest on the machine.
    private var headline: some View {
        HStack(spacing: 6) {
            Text(verbatim: project.name)
                .font(.callout).lineLimit(1).truncationMode(.middle)
            // AMBER, WHICH IS THE ONE THING THE OLD ROW'S COLOUR HAD TO SAY. Down there the stray
            // COUNT was the only coloured field, being the reading somebody would act on; up here
            // the whole card is that reading, so the colour goes on the word that says so rather
            // than on a figure. Amber rather than red: it is a fact to notice, not a fault, and a
            // session legitimately leaves a dev server running all day.
            //
            // And only while it is TRUE: a card kept for its records alone has nothing unclaimed
            // running in it any more, and a word in the colour of "somebody should look at this"
            // would be asking for a look at something this app has already dealt with.
            if project.strayProcesses > 0 {
                Text(L("unclaimed"))
                    .font(.caption2).foregroundStyle(TallyColor.warning)
                    .lineLimit(1).fixedSize()
            }
            Spacer(minLength: 6)
            if marked { SessionCardView.flameMark }
        }
    }
}
