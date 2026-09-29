import SwiftUI

/// The list row's two stand-ins for its meters, split out of AccountListRowView for file size.
extension AccountListRowView {
    /// A renewal in progress takes the meters' place: beside the name it had no room at list width.
    /// Below the identity in priority, so the account name is never the part that truncates.
    var renewingTail: some View {
        HStack(spacing: 3) { ProgressView().controlSize(.mini); Text(L("Browser sign-in…")) }
            .foregroundStyle(.secondary).layoutPriority(-1).tallyTooltip(
                facts.markOwner, detail: L("Finish the sign-in in your browser; Tally will say when it lands."))
    }

    /// An account that has never loaded: the reason, then the retry, in place of the meters it has
    /// none of.
    var errorTail: some View {
        HStack(spacing: 6) {
            // One line at this width, so the callout is where the whole sentence lives, reason
            // included: the compact row folds every other word it cannot fit into one too.
            Text(usage.error ?? "")
                .foregroundStyle(TallyColor.warning)
                .lineLimit(1)
                .tallyTooltip(usage.error ?? "", detail: usage.errorDetail)
            Button(L("Retry")) {
                Task { await UsageStore.shared.refresh(userInitiated: true) }
            }
            .buttonStyle(.borderless)
            .font(.caption2)
        }
    }
}
