import SwiftUI

/// WHETHER THE CARDS BELOW ADD UP, drawn as a few quiet rows above them.
///
/// THE ONE THING ON THIS PAGE THAT IS NOT ABOUT A SESSION. Every card answers for its own tree, and
/// a machine can be doing a great deal in the same checkouts that no live session accounts for -
/// which read card by card is a page where nothing is wrong and the total is (`MachineLoadRollup`
/// carries the incident that made this necessary).
///
/// DRAWN ONLY WHEN IT SAYS SOMETHING THE CARDS CANNOT, which is most of the point: on the ordinary
/// board - one session per checkout, nothing left over - this section is a summary of the cards
/// underneath it and would spend the top of the page restating the page
/// (`MachineLoadRollup.isWorthDrawing`).
///
/// NOTHING HERE ANSWERS A HOVER, A CLICK OR A DISCLOSURE, which is the rule the cards below already
/// keep (`SessionBoardView`): what a row has to say is on the row. A rollup that hid its leftovers
/// behind a twisty would be hiding the reading it exists for.
///
/// AND THE ROWS DO NOT MOVE. The order is by name and never by load, the figures sit in columns as
/// wide as their widest reading, and the heaviest project is MARKED rather than lifted - a list that
/// re-seats itself under a reading eye is the defect this board has already been reported for once
/// at the level of a single figure (`SessionCardFootprint.column`, Albert 2026-08-15).
extension PopoverRootView {

    @ViewBuilder
    var sessionsProjectRollup: some View {
        let load = ProcessFootprintStore.shared.machineLoad
        if MachineLoadRollup.isWorthDrawing(load) {
            VStack(alignment: .leading, spacing: 3) {
                Text(L("Projects"))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(load.projects) { project in
                    projectRollupRow(project, marked: load.heaviest == project.root)
                }
            }
            .padding(.vertical, 2)
        }
    }

    /// One project: what it is called, what it is spending, what it is holding, and how much of that
    /// belongs to nobody on this board.
    ///
    /// THE STRAY COUNT IS THE LAST FIELD AND THE ONLY COLOURED ONE. It is the reading somebody would
    /// act on - work in this checkout that no card explains - and everything else on the row is
    /// context for it. Amber rather than red: it is a fact to notice, not a fault, and a session
    /// legitimately leaves a dev server running all day.
    private func projectRollupRow(_ project: ProjectLoad, marked: Bool) -> some View {
        HStack(spacing: 6) {
            // The mark sits BEFORE the name and holds its width whether or not it is drawn, so a
            // project that becomes the heaviest does not shunt the whole row sideways.
            Image(systemName: "flame.fill")
                .font(.caption2)
                .foregroundStyle(marked ? TallyColor.warning : .clear)
                .accessibilityHidden(!marked)
            Text(verbatim: project.name)
                .font(.caption2)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            if project.sessions != 1 {
                // ONE SESSION IS THE ORDINARY CASE AND SAYS NOTHING; the two readings worth a word
                // are a checkout running several at once (whose total no single card states) and a
                // checkout running NONE, where everything on the row is somebody's leftovers.
                // Never the singular: this branch is only taken by a count that is not one.
                Text(verbatim: "\(project.sessions) \(L("sessions"))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            SessionCardView.column(Self.widestRollupPercent) {
                Text(verbatim: project.cpuPercent.map { "\(Int($0.rounded()))%" } ?? "")
            }
            SessionCardView.column(Self.widestRollupMemory) {
                Text(verbatim: ProcessTree.memoryText(project.memoryBytes) ?? "")
            }
            SessionCardView.column(Self.widestRollupStrays) {
                Text(verbatim: project.strayProcesses > 0
                        ? "\(project.strayProcesses) \(L("background"))" : "")
                    .foregroundStyle(project.strayProcesses > 0 ? TallyColor.warning : .secondary)
            }
        }
        .font(.caption2.monospacedDigit())
        .lineLimit(1)
        .accessibilityElement(children: .combine)
    }

    /// The widest reading each column is sized to, as a hidden copy of the string rather than as a
    /// number of points - the rule the card's own figures are laid out by
    /// (`SessionCardView.column`). Four digits of CPU is sixteen fully committed cores, which is
    /// this machine; a figure past it widens its column rather than being clipped.
    static let widestRollupPercent = "0000%"
    static let widestRollupMemory = "00.0 GB"
    /// The one of the three that cannot be a constant: the word is translated, and a column sized
    /// to the English one would clip on the other four languages this app ships in.
    static var widestRollupStrays: String { "00 \(L("background"))" }
}
