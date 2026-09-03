import SwiftUI

/// WHAT NOBODY IS ANSWERING FOR IN THIS CHECKOUT, in the two shapes the board states it in.
///
/// ONE READING, TWO SURFACES, and the reason it is one file rather than two blocks has not changed:
/// how much is running here that no session accounts for, what this app is watching, and what it has
/// already done about it. Drawn twice it would drift twice.
///
/// WHAT CHANGED IS WHERE IT GOES UNDER A SESSION CARD (Albert, 2026-09-03). It was a line along the
/// bottom of the project's last card - the amber word, the count and the figures - and a line is
/// what a card spends on a reading it has to state every tick. The figures on it are the same KIND
/// of figure the row above already holds (`SessionCardView.sessionFootprintTrends`: a share of the
/// cores and a quantity of memory), so they belong on that row, and what does not fit on a row -
/// the sentence, the watch list, what this app has already ended - belongs in the callout this
/// surface already hosts. So under a session card the reading is now `SessionLeftoversMark`: an
/// amber glyph and a count at the end of the trend row, with everything else one hover away.
///
/// AND IT IS STILL A WHOLE LINE ON THE PROJECT'S OWN CARD, which is what this view draws
/// (`SessionGhostCardView`). That card has no session on it, no trend row to sit at the end of, and
/// nothing else competing for its lines: the reading IS the card, so it is written out.
struct SessionUnclaimedFootnote: View {
    /// The project as the rollup states it: what its leftovers are spending, and how many of them
    /// there are (`ProjectLoad`).
    let project: ProjectLoad

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            // NOTHING IS SAID ABOUT LEFTOVERS THAT ARE NO LONGER THERE. A project keeps a footnote
            // for a while after this app has ended what was running in it, to say that it did
            // (`SessionBoardGhosts.unclaimed(in:remembering:)`); a sentence reading "0 procs, no
            // session is running them" and a row of zeroes would be two readings nobody took. What
            // is left is what happened.
            if project.strayProcesses > 0 {
                Text(verbatim: Self.sentence(project))
                    .font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.tail)
                HStack(spacing: 6) {
                    figure(Self.cpuText(project))
                    figure(Self.memoryText(project))
                    Spacer(minLength: 0)
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
            ForEach(Self.watching(in: project.root)) { watch in
                reclaimRow(icon: "eye", tint: TallyColor.warning, text: Self.watchLine(watch))
            }
            ForEach(Self.records(in: project.root)) { record in
                reclaimRow(icon: Self.icon(record.outcome), tint: Self.tint(record.outcome),
                           text: Self.recordLine(record))
            }
        }
    }

    /// One figure, in the font every figure on this board is drawn in and held at its own width: a
    /// truncated figure is a wrong figure, so what gives room up is the sentence above them.
    private func figure(_ text: String?) -> some View {
        Text(verbatim: text ?? "")
            .font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
            .lineLimit(1).fixedSize()
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
}

// MARK: - The reading itself

/// EVERY SPELLING OF THIS READING, STATED ONCE, because two surfaces draw it and a callout says it a
/// third time. Static rather than instance members for that reason alone: the mark at the end of a
/// trend row is not a `SessionUnclaimedFootnote` and must not have to become one to ask what a
/// checkout's leftovers are called.
///
/// `@MainActor` because two of these read the reclaim store, which is one.
@MainActor
extension SessionUnclaimedFootnote {
    /// How much is running here and the whole of why this reading exists, in one sentence.
    ///
    /// ONE CATALOGUE ENTRY WITH THE COUNT PUT INTO IT, and the counted word comes from the pair the
    /// session cards already spell their own process counts with (`SessionCardView
    /// .sessionFootprintSegments`): a translator sees the sentence whole, and the plural is decided
    /// where the bundle is rather than by a rule about English inside a format string.
    static func sentence(_ project: ProjectLoad) -> String {
        String(format: L("%@, no session is running them"), counted(project))
    }

    /// The count and the word for what is being counted, which the sentence above puts into itself.
    static func counted(_ project: ProjectLoad) -> String {
        "\(project.strayProcesses) \(L(project.strayProcesses == 1 ? "proc" : "procs"))"
    }

    /// THE STRAYS' OWN FIGURES, NEVER THE PROJECT'S TOTAL (`ProjectLoad.strayCpuPercent`). The
    /// total is the sessions' cores plus these, and a checkout running a session at 300% and one
    /// abandoned server at 20 would read 320% under "no session is running them" - a figure that is
    /// true of the project, false of this reading, and counted a second time on the very card this
    /// reading is attached to.
    static func cpuText(_ project: ProjectLoad) -> String? {
        cpuFigure(project).map { "\($0) CPU" }
    }

    /// The same reading with the word taken off it, for the callout - where `CPU` is already the
    /// label in the column beside it and the line read `CPU  214% CPU` with the word left on
    /// (seen on the first capture of it, 2026-09-03). The line-shaped form keeps the word, having no
    /// label to carry it.
    static func cpuFigure(_ project: ProjectLoad) -> String? {
        project.strayCpuPercent.map { "\(Int($0.rounded()))%" }
    }

    /// NO SHAPE AND NO CEILING, unlike a session card's own readings (`SessionCardView
    /// .sessionFootprintTrends`): the trend rings are kept per SESSION, and a pool of leftovers has
    /// no history to draw. Two figures rather than three - the strays are sampled for CPU and memory
    /// and nothing else (`ProjectLoadAccounting.measure`) - and neither of them names a culprit,
    /// because a pool has no leader to blame (`ProcessFootprint.memoryLeader` is a tree's field).
    ///
    /// AND NO PORTS, WHICH IS A GAP RATHER THAN A CHOICE. `ProcessTree.portsText` reads them off a
    /// `ProcessFootprint`, and the strays never produce one: the descriptor tables are read per
    /// session tree, on one visible tick in three (`ProcessFootprintStore`), and nothing reads them
    /// for a pool. A dev server nobody is answering for is exactly the leftover whose port somebody
    /// wants, so this is the first thing to add here - it needs the pool sampled for ports the way a
    /// tree is, which is a reading this package did not take.
    static func memoryText(_ project: ProjectLoad) -> String? {
        ProcessTree.memoryText(project.strayMemoryBytes)
    }

    /// This project's own leftovers under consideration, and its own history: the store keeps one
    /// list for the whole machine, and each reading takes the part that is about its project.
    ///
    /// KEYED ON THE PROJECT ROOT, which both sides already spell the same way: the store is handed
    /// the strays by project (`ProcessFootprintStore.sample`) and files what it watches and what it
    /// did under that same root (`OrphanReclaimStore.watch`).
    static func watching(in root: String) -> [OrphanReclaimStore.Watch] {
        OrphanReclaimStore.shared.watching.filter { $0.project == root }
    }

    static func records(in root: String) -> [OrphanReclaimStore.Record] {
        OrphanReclaimStore.shared.records.filter { $0.project == root }
    }

    /// One thing still running that nothing here has acted on. NO PROJECT NAME ON IT: the rows used
    /// to be a section about the whole machine and had to say which checkout each was in, and
    /// wherever this reading is drawn the card carrying it has already said so.
    static func watchLine(_ watch: OrphanReclaimStore.Watch) -> String {
        let spent = spent(watch)
        return spent.isEmpty ? watch.program : "\(watch.program) · \(spent)"
    }

    /// What one watched leftover is costing, with no name on it: the callout puts the name in the
    /// label column and this in the value column, and the row above joins the two into a line. One
    /// spelling, so the pointer's copy and the card's cannot drift.
    static func spent(_ watch: OrphanReclaimStore.Watch) -> String {
        var parts: [String] = []
        if let percent = watch.cpuPercent { parts.append("\(Int(percent.rounded()))%") }
        if let held = ProcessTree.memoryText(watch.memoryBytes) { parts.append(held) }
        return parts.joined(separator: " · ")
    }

    /// And one thing that happened, said as an outcome rather than as a status.
    static func recordLine(_ record: OrphanReclaimStore.Record) -> String {
        switch record.outcome {
        case .reclaimedByLease, .reclaimedBySustained:
            return "\(L("ended")) \(record.program) (\(record.processes))"
        case .reported:
            return "\(record.program) \(L("left alone"))"
        case .failed:
            return "\(record.program) \(L("would not end"))"
        }
    }

    /// The same outcome with the program taken out of it, for the callout's value column - where the
    /// program is already the label beside it and saying it twice would be the row repeating itself.
    static func outcome(_ record: OrphanReclaimStore.Record) -> String {
        switch record.outcome {
        case .reclaimedByLease, .reclaimedBySustained: "\(L("ended")) (\(record.processes))"
        case .reported: L("left alone")
        case .failed: L("would not end")
        }
    }

    static func icon(_ outcome: OrphanNotice.Outcome) -> String {
        switch outcome {
        case .reclaimedByLease, .reclaimedBySustained: return "xmark.circle"
        case .reported: return "eye"
        case .failed: return "exclamationmark.triangle"
        }
    }

    /// A reclaim is done with and reads as history; anything still running is amber, which is the
    /// same colour the word above it is drawn in for the same reason.
    static func tint(_ outcome: OrphanNotice.Outcome) -> Color {
        switch outcome {
        case .reclaimedByLease, .reclaimedBySustained: return .secondary
        case .reported, .failed: return TallyColor.warning
        }
    }

    /// THE WHOLE READING AS A CALLOUT, which is what the mark on a session card answers a hover
    /// with (`SessionLeftoversMark`) and what a listener is told in place of it.
    ///
    /// BLOCKS RATHER THAN A PARAGRAPH, because these are labelled figures and a column of them is
    /// read at a glance where three sentences have to be parsed one at a time (`TallyTooltipRow`
    /// carries the whole of that argument). The sentence that says what the reading IS becomes the
    /// first block's title, so the callout opens with the same words the project's own card leads
    /// with rather than with a bare column of numbers.
    ///
    /// THE ICONS THE ROWS WEAR DO NOT COME WITH THEM, and the section titles are what replaces
    /// them: a callout row is a label and a value, and an eye repeated down a column says less than
    /// one word over it. Nothing is lost that a reader acts on - which program, what it is spending,
    /// and what this app did about it are all still here.
    ///
    /// AND AN EMPTY SECTION IS NOT DRAWN AT ALL, rather than drawn empty: a machine where nothing
    /// is being watched gets no `Watching` heading over nothing.
    static func callout(_ project: ProjectLoad) -> TallyTooltipContent {
        var blocks = [TallyTooltipBlock(title: sentence(project),
                                        rows: [(L("CPU"), cpuFigure(project)),
                                               (L("Memory"), memoryText(project))]
                                            .compactMap { label, value in
                                                value.map { TallyTooltipRow(label, $0) }
                                            })]
        let watched = watching(in: project.root)
        if !watched.isEmpty {
            blocks.append(TallyTooltipBlock(title: L("Watching"),
                                            rows: watched.map {
                                                TallyTooltipRow($0.program, spent($0))
                                            }))
        }
        let done = records(in: project.root)
        if !done.isEmpty {
            blocks.append(TallyTooltipBlock(title: L("Handled"),
                                            rows: done.map {
                                                TallyTooltipRow($0.program, outcome($0))
                                            }))
        }
        return .blocks(blocks)
    }
}

// MARK: - The mark under a session card

/// THIS CHECKOUT'S LEFTOVERS AT THE END OF A SESSION CARD'S TREND ROW: an amber glyph, the count,
/// and everything else one hover away (`SessionUnclaimedFootnote.callout`).
///
/// A FOURTH GROUP ON A ROW OF THREE, which is why it is shaped like the three: this row is where
/// that card states what is running under it, and what no session is answering for is the same
/// question asked of the rest of the checkout. It is laid out INSIDE the row's candidate list
/// (`SessionCardView.sessionFootprintTrends`), so a narrow card gives ceilings and culprit names up
/// to fit it rather than truncating it - the same ladder the three readings already descend.
///
/// THE GLYPH IS THE APP'S OWN RECLAIM VOCABULARY, not a new one: an arrow turning back is what this
/// package does about these processes when a lease runs out (`OrphanReclaim`), and it is the one
/// mark on this card that is neither the eye of something being watched nor the cross of something
/// ended. Amber for the reason the word `leftovers` is amber wherever it is written: worth an eye,
/// not worth a hand.
///
/// AND IT ANSWERS A HOVER, WHICH ALMOST NOTHING ON THIS BOARD DOES. The ban is real and worth
/// restating rather than quietly lifting: the pointer WAITS on this board between jumps, so a layer
/// opening under a resting hand covers the cards beside it (2026-08-15). What earns the exception is
/// what earned it for the blocked card's reason (`SessionCardView.sessionStateWord`) - the reading
/// has nowhere else on the card to be said in full, and the target is small, at the end of one row,
/// and on at most one card per checkout. The figures themselves stay unhovered.
struct SessionLeftoversMark: View {
    /// The project as the rollup states it (`ProjectLoad`).
    let project: ProjectLoad
    /// Whether the machine's flame belongs to these leftovers rather than to the session above them
    /// (`SessionBoardGhosts.placement`). Drawn beside the count, never on the session's headline:
    /// the mark is about what is burning the cores, and on this card it is not the session.
    var flamed: Bool = false

    var body: some View {
        HStack(spacing: SessionCardView.trendSpacing) {
            Image(systemName: "arrow.counterclockwise")
            Text(verbatim: "\(project.strayProcesses)")
            if flamed { SessionCardView.flameMark }
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(TallyColor.warning)
        .lineLimit(1).fixedSize()
        // Forcible for a capture, which is how the callout gets looked at without synthesizing a
        // hover onto somebody's desktop (`TallyTooltip.previewForced`, `-TallyTooltipPreview
        // leftovers`). UNDER THE FIXTURES ONLY, which is what keeps that flag's one-target contract
        // true: a real machine can have several checkouts with leftovers and every mark would
        // publish into the single preference slot the preview reads. The demo board has exactly one
        // by construction (`DemoSessions.strayReadings`).
        .tallyTooltip(blocks: blocks,
                      forced: DemoUsage.isActive && TallyTooltip.previewForced(.leftovers))
    }

    private var blocks: [TallyTooltipBlock] {
        if case let .blocks(blocks) = SessionUnclaimedFootnote.callout(project) { return blocks }
        return []
    }
}
