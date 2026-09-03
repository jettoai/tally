import SwiftUI

/// ONE CHECKOUT'S WORK THAT NO SESSION IS ANSWERING FOR, drawn as a card of its own on the board.
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
    /// Whether this is the heaviest project on the machine AND has no session card to carry the
    /// mark (`SessionBoardGhosts.marked`).
    var marked: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            headline
            Text(verbatim: sentence)
                .font(.caption2).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.tail)
            figures
            // WHAT THIS APP DID ABOUT ANY OF IT, on the card it is about rather than in a section of
            // its own further up the page. A kill nobody is told about is indistinguishable from a
            // crash, and the durable half of telling is the message written into the project's inbox
            // (`OrphanNotice`); this is the other half - what a person sees when they happen to have
            // the panel open, and the one answer the inbox cannot give: "is it about to do that
            // again".
            //
            // WHAT IS BEING WATCHED COMES FIRST, because that is the reading somebody can still act
            // on; what has already happened comes after it, newest first, and only for as long as
            // the store keeps it (`OrphanReclaimStore.keptRecords`).
            ForEach(watching) { watch in
                reclaimRow(icon: "eye", tint: TallyColor.warning, text: watchLine(watch))
            }
            ForEach(records) { record in
                reclaimRow(icon: Self.icon(record.outcome), tint: Self.tint(record.outcome),
                           text: recordLine(record))
            }
        }
        .padding(.horizontal, TallyMetrics.cardPaddingH)
        .padding(.vertical, TallyMetrics.cardPaddingV)
        .frame(maxWidth: .infinity, alignment: .leading)
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
            Text(L("unclaimed"))
                .font(.caption2).foregroundStyle(TallyColor.warning)
                .lineLimit(1).fixedSize()
            Spacer(minLength: 6)
            if marked { SessionCardView.flameMark }
        }
    }

    /// How much is running here and the whole of why this card exists, in one sentence.
    ///
    /// ONE CATALOGUE ENTRY WITH THE COUNT PUT INTO IT, and the counted word comes from the pair the
    /// session cards already spell their own process counts with (`SessionCardView
    /// .sessionFootprintSegments`): a translator sees the sentence whole, and the plural is decided
    /// where the bundle is rather than by a rule about English inside a format string.
    private var sentence: String {
        let counted = "\(project.strayProcesses) \(L(project.strayProcesses == 1 ? "proc" : "procs"))"
        return String(format: L("%@, no session is running them"), counted)
    }

    /// What those processes are costing, in the font every figure on this board is drawn in.
    ///
    /// NO SHAPES AND NO CEILINGS, unlike a session card's own readings (`SessionCardView
    /// .sessionFootprintTrends`): the trend rings are kept per SESSION, and a pool of leftovers has
    /// no history to draw. Two figures rather than three - the strays are sampled for CPU and memory
    /// and nothing else (`ProjectLoadAccounting.measure`).
    ///
    /// AND NO PORTS, WHICH IS A GAP RATHER THAN A CHOICE. `ProcessTree.portsText` reads them off a
    /// `ProcessFootprint`, and the strays never produce one: the descriptor tables are read per
    /// session tree, on one visible tick in three (`ProcessFootprintStore`), and nothing reads them
    /// for a pool. A dev server nobody is answering for is exactly the leftover whose port somebody
    /// wants, so this is the first thing to add here - it needs the pool sampled for ports the way a
    /// tree is, which is a reading this package did not take.
    private var figures: some View {
        HStack(spacing: 6) {
            Text(verbatim: project.cpuPercent.map { "\(Int($0.rounded()))% CPU" } ?? "")
            Text(verbatim: ProcessTree.memoryText(project.memoryBytes) ?? "")
            Spacer(minLength: 0)
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.tertiary)
        .lineLimit(1)
    }

    /// This project's own leftovers under consideration, and its own history: the store keeps one
    /// list for the whole machine, and each card takes the part that is about it.
    ///
    /// KEYED ON THE PROJECT ROOT, which both sides already spell the same way: the store is handed
    /// the strays by project (`ProcessFootprintStore.sample`) and files what it watches and what it
    /// did under that same root (`OrphanReclaimStore.watch`).
    private var watching: [OrphanReclaimStore.Watch] {
        OrphanReclaimStore.shared.watching.filter { $0.project == project.root }
    }

    private var records: [OrphanReclaimStore.Record] {
        OrphanReclaimStore.shared.records.filter { $0.project == project.root }
    }

    private func reclaimRow(icon: String, tint: Color, text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption2)
                .foregroundStyle(tint)
            Text(verbatim: text)
                .font(.caption2)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .font(.caption2.monospacedDigit())
    }

    /// One thing still running that nothing here has acted on. NO PROJECT NAME ON IT ANY MORE: the
    /// rows used to be a section about the whole machine and had to say which checkout each was in,
    /// and on this card the title one line up has already said it.
    private func watchLine(_ watch: OrphanReclaimStore.Watch) -> String {
        var line = watch.program
        if let percent = watch.cpuPercent { line += " · \(Int(percent.rounded()))%" }
        if let held = ProcessTree.memoryText(watch.memoryBytes) { line += " · \(held)" }
        return line
    }

    /// And one thing that happened, said as an outcome rather than as a status.
    private func recordLine(_ record: OrphanReclaimStore.Record) -> String {
        switch record.outcome {
        case .reclaimedByLease, .reclaimedBySustained:
            return "\(L("ended")) \(record.program) (\(record.processes))"
        case .reported:
            return "\(record.program) \(L("left alone"))"
        case .failed:
            return "\(record.program) \(L("would not end"))"
        }
    }

    private static func icon(_ outcome: OrphanNotice.Outcome) -> String {
        switch outcome {
        case .reclaimedByLease, .reclaimedBySustained: return "xmark.circle"
        case .reported: return "eye"
        case .failed: return "exclamationmark.triangle"
        }
    }

    /// A reclaim is done with and reads as history; anything still running is amber, which is the
    /// same colour the count of leftovers is drawn in for the same reason.
    private static func tint(_ outcome: OrphanNotice.Outcome) -> Color {
        switch outcome {
        case .reclaimedByLease, .reclaimedBySustained: return .secondary
        case .reported, .failed: return TallyColor.warning
        }
    }
}
