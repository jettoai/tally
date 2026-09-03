import SwiftUI

/// WHAT NOBODY IS ANSWERING FOR IN THIS CHECKOUT, written under whichever card on the board is that
/// checkout's: the LAST session card of the project, or - when its sessions have all ended - the
/// project's own unclaimed card (`SessionBoardGhosts.seating`).
///
/// ONE VIEW FOR BOTH PLACES, which is the whole reason it is a file rather than two blocks. The
/// reading is the same reading in both: how much is running here that no session accounts for, what
/// this app is watching, and what it has already done about it. Drawn twice it would drift twice.
///
/// IT USED TO BE A CARD OF ITS OWN WHEREVER IT APPEARED, and on a live board that was two defects
/// rather than a preference (Albert, on the board's first day, 2026-09-03): a three-line card seated
/// in a grid row as tall as the session card beside it left a block of empty card under itself, and
/// a card inserted in the middle of the board pushed every card after it one seat along, so the two
/// columns stopped standing project beside project. A line about the checkout the card above is
/// working in is a footnote, and only a checkout with no card left needs one of its own.
///
/// NOT A BUTTON AND NOT A TARGET. It answers no click, no hover and no drag - under a session card
/// a press goes through to that session's terminal exactly as it does anywhere else on the card
/// (the card is one `Button`, and this adds nothing that could swallow the press), and on the
/// project's own card there is nothing to press at all (`SessionGhostCardView`).
struct SessionUnclaimedFootnote: View {
    /// The project as the rollup states it: what its leftovers are spending, and how many of them
    /// there are (`ProjectLoad`).
    let project: ProjectLoad
    /// Whether this footnote has to say WHAT it is. Under a session card it does: everything else on
    /// that card is about the session, and figures with nothing naming them would read as more of
    /// the session's own. On the project's own card the headline one line up has already said the
    /// word, so saying it again here would be the same card saying it twice.
    ///
    /// It also decides how much room this has. Under a session card the whole reading is one line -
    /// the count and the figures, at the width a compact card is laid out at - while the project's
    /// own card has the room for the sentence that says what the card is FOR, and gives it a line.
    var namesItself: Bool = false
    /// Whether the machine's flame belongs to these leftovers rather than to the session above them
    /// (`SessionBoardGhosts.marked`). Drawn at the end of the footnote's own line, never on the
    /// session's headline: the mark is about what is burning the cores, and on that card it is not
    /// the session. The project's own card wears it in its headline instead, where nothing else is.
    var marked: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            // NOTHING IS SAID ABOUT LEFTOVERS THAT ARE NO LONGER THERE. A project keeps a footnote
            // for a while after this app has ended what was running in it, to say that it did
            // (`SessionBoardGhosts.unclaimed(in:remembering:)`); a sentence reading "0 procs, no
            // session is running them" and a row of zeroes would be two readings nobody took. What
            // is left is what happened.
            if project.strayProcesses > 0 {
                if namesItself {
                    line
                } else {
                    Text(verbatim: sentence)
                        .font(.caption2).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.tail)
                    HStack(spacing: 6) {
                        figures
                        Spacer(minLength: 0)
                    }
                }
            }
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
    }

    /// THE WHOLE READING ON ONE LINE, which is what a footnote under a session card has room for:
    /// the amber word that says these figures are not that session's, the count, and what the count
    /// is spending.
    ///
    /// THE FIGURES ARE HELD AT THEIR OWN WIDTH AND THE COUNT GIVES ROOM UP, which is the rule this
    /// board already keeps one card over (`SessionCardView.sessionIdentityRow`): a truncated figure
    /// is a wrong figure, while a count that gives up its tail still says the word it is counting.
    private var line: some View {
        HStack(spacing: 6) {
            // AMBER, AND ON THE WORD RATHER THAN ON A FIGURE. It is the reading somebody would act
            // on, and amber rather than red because it is a fact to notice rather than a fault: a
            // session legitimately leaves a dev server running all day.
            Text(L("unclaimed"))
                .font(.caption2).foregroundStyle(TallyColor.warning)
                .lineLimit(1).fixedSize()
            Text(verbatim: counted)
                .font(.caption2).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.tail).layoutPriority(-1)
            figures
            Spacer(minLength: 0)
            if marked { SessionCardView.flameMark }
        }
    }

    /// How much is running here and the whole of why this reading exists, in one sentence. Drawn on
    /// the project's own card, which is where there is room for it.
    ///
    /// ONE CATALOGUE ENTRY WITH THE COUNT PUT INTO IT, and the counted word comes from the pair the
    /// session cards already spell their own process counts with (`SessionCardView
    /// .sessionFootprintSegments`): a translator sees the sentence whole, and the plural is decided
    /// where the bundle is rather than by a rule about English inside a format string.
    private var sentence: String {
        String(format: L("%@, no session is running them"), counted)
    }

    /// The count and the word for what is being counted, which the sentence above puts into itself
    /// and the one-line form states on its own.
    private var counted: String {
        "\(project.strayProcesses) \(L(project.strayProcesses == 1 ? "proc" : "procs"))"
    }

    /// What those processes are costing, in the font every figure on this board is drawn in.
    ///
    /// THE STRAYS' OWN FIGURES, NEVER THE PROJECT'S TOTAL (`ProjectLoad.strayCpuPercent`). The
    /// total is the sessions' cores plus these, and a checkout running a session at 300% and one
    /// abandoned server at 20 would read 320% under "no session is running them" - a figure that is
    /// true of the project, false of this reading, and counted a second time on the very card this
    /// footnote is written under.
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
    @ViewBuilder
    private var figures: some View {
        figure(project.strayCpuPercent.map { "\(Int($0.rounded()))% CPU" })
        figure(ProcessTree.memoryText(project.strayMemoryBytes))
    }

    /// One of them, in the font every figure on this board is drawn in and held at its own width: a
    /// truncated figure is a wrong figure, so what gives room up is the count beside them.
    private func figure(_ text: String?) -> some View {
        Text(verbatim: text ?? "")
            .font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
            .lineLimit(1).fixedSize()
    }

    /// This project's own leftovers under consideration, and its own history: the store keeps one
    /// list for the whole machine, and each footnote takes the part that is about its project.
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

    /// One thing still running that nothing here has acted on. NO PROJECT NAME ON IT: the rows used
    /// to be a section about the whole machine and had to say which checkout each was in, and
    /// wherever this footnote is drawn the card carrying it has already said so.
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
    /// same colour the word above it is drawn in for the same reason.
    private static func tint(_ outcome: OrphanNotice.Outcome) -> Color {
        switch outcome {
        case .reclaimedByLease, .reclaimedBySustained: return .secondary
        case .reported, .failed: return TallyColor.warning
        }
    }
}
