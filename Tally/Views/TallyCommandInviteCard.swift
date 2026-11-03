import SwiftUI

/// The panel's invitation to put `tally` on the PATH: one dismissible card under the accounts. "Set
/// Up" opens the small install window; the cross is the only other way it goes away for good.
struct TallyCommandInviteCard: View {
    let onSetUp: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(verbatim: ">_")
                .font(.system(size: 14, weight: .bold, design: .monospaced))
                .foregroundStyle(Color(nsColor: .systemBlue))
                .frame(width: 22, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                Text(L("Start Claude on the account with room")).font(.system(size: 14, weight: .semibold))
                HintText.withCode(L("Type `tally claude` instead of `claude` and Tally picks the account."), size: 12.5)
                    .font(.system(size: 12.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button(L("Set Up"), action: onSetUp)
                .buttonStyle(.borderedProminent).controlSize(.regular)
            Button(action: onDismiss) {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L("Dismiss"))
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .modifier(CommandCardStyle())
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
    }
}
