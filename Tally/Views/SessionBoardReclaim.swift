import SwiftUI

/// WHAT THIS APP DID ABOUT THE WORK NOBODY WAS ANSWERING FOR, drawn under the Projects rollup.
///
/// A KILL NOBODY IS TOLD ABOUT IS INDISTINGUISHABLE FROM A CRASH, and the durable half of telling
/// is the message written into the project's inbox (`OrphanNotice`). This is the other half: what a
/// person sees when they happen to have the panel open, which is also the surface that answers the
/// question the inbox cannot - "is it about to do that again".
///
/// TWO LINES AND NO INTERACTION, the rule the rows above already keep (`SessionBoardRollup`). What
/// is being watched comes first, because that is the reading somebody can still act on; what has
/// already happened comes after it, newest first, and only for as long as the store keeps it
/// (`OrphanReclaimStore.keptRecords`).
extension PopoverRootView {

    @ViewBuilder
    var sessionsReclaimNotes: some View {
        let store = OrphanReclaimStore.shared
        if !store.watching.isEmpty || !store.records.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                Text(L("Left running"))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(store.watching) { watch in
                    reclaimRow(icon: "eye", tint: TallyColor.warning,
                               text: watchLine(watch))
                }
                ForEach(store.records) { record in
                    reclaimRow(icon: icon(record.outcome), tint: tint(record.outcome),
                               text: recordLine(record))
                }
            }
            .padding(.vertical, 2)
        }
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
        .accessibilityElement(children: .combine)
    }

    /// One thing still running that nothing here has acted on. The figure comes last because the
    /// name is what a reader is scanning for.
    private func watchLine(_ watch: OrphanReclaimStore.Watch) -> String {
        var line = "\(URL(fileURLWithPath: watch.project).lastPathComponent) · \(watch.program)"
        if let percent = watch.cpuPercent { line += " · \(Int(percent.rounded()))%" }
        if let held = ProcessTree.memoryText(watch.memoryBytes) { line += " · \(held)" }
        return line
    }

    /// And one thing that happened, said as an outcome rather than as a status.
    private func recordLine(_ record: OrphanReclaimStore.Record) -> String {
        let project = URL(fileURLWithPath: record.project).lastPathComponent
        switch record.outcome {
        case .reclaimedByLease, .reclaimedBySustained:
            return "\(project) · \(L("ended")) \(record.program) (\(record.processes))"
        case .reported:
            return "\(project) · \(record.program) \(L("left alone"))"
        case .failed:
            return "\(project) · \(record.program) \(L("would not end"))"
        }
    }

    private func icon(_ outcome: OrphanNotice.Outcome) -> String {
        switch outcome {
        case .reclaimedByLease, .reclaimedBySustained: return "xmark.circle"
        case .reported: return "eye"
        case .failed: return "exclamationmark.triangle"
        }
    }

    /// A reclaim is done with and reads as history; anything still running is amber, which is the
    /// same colour the stray count above it uses for the same reason.
    private func tint(_ outcome: OrphanNotice.Outcome) -> Color {
        switch outcome {
        case .reclaimedByLease, .reclaimedBySustained: return .secondary
        case .reported, .failed: return TallyColor.warning
        }
    }
}
